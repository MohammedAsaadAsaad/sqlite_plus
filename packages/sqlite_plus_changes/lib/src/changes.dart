import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:sqlite_plus/sqlite_plus.dart';

part 'models.dart';
part 'writer.dart';
part 'tracking.dart';
part 'consumers.dart';

const _tableNames = {
  '_spc_state',
  '_spc_sources',
  '_spc_events',
  '_spc_batches',
  '_spc_consumers'
};
final _zoneKey = Object();
final _maximum = (BigInt.one << 63) - BigInt.one;
String _quote(String name) => '"${name.replaceAll('"', '""')}"';
String _literal(String value) => "'${value.replaceAll("'", "''")}'";
BigInt _integer(Object? value) {
  if (value is! BigInt) {
    throw const ChangeLogCorrupt('Expected integer metadata');
  }
  return value;
}

/// Owns operations on an application-owned connection. External operations must
/// not interleave its calls. No engine hooks are installed. Main-schema only.
final class SqlitePlusChanges {
  SqlitePlusChanges._(this.database);
  final MutableSqliteDatabase database;
  static final _queues = Expando<Future<void>>();
  static final _handles = Expando<SqlitePlusChanges>();
  static final _signals = Expando<StreamController<ChangeNotification>>();

  /// Optional connection-wide async hints; no SQL/polling or durable consumer.
  Stream<ChangeNotification> get commits =>
      (_signals[database] ??= StreamController<ChangeNotification>.broadcast())
          .stream;

  void _notify(ChangeCheckpoint checkpoint, {bool reset = false}) {
    final signals = _signals[database];
    if (signals != null && signals.hasListener) {
      signals.add(ChangeNotification(checkpoint, reset: reset));
    }
  }

  static Future<SqlitePlusChanges> open(
      {required MutableSqliteDatabase database,
      bool allowSchemaRepair = false}) async {
    final feed = _handles[database] ?? SqlitePlusChanges._(database);
    await feed._run(() async {
      final schema = await database
          .query("SELECT name FROM sqlite_schema WHERE type='table'");
      final owned = schema.rows
          .map((r) => r.single)
          .whereType<String>()
          .where((name) => name.startsWith('_spc_'))
          .toSet();
      if (owned.isEmpty) {
        await feed._atomic(() async {
          await database.execute(
              'CREATE TABLE _spc_state(id INTEGER PRIMARY KEY,format INTEGER NOT NULL,feed_id TEXT NOT NULL,next_batch INTEGER NOT NULL,pruned_through INTEGER NOT NULL,active_batch INTEGER)');
          await database.execute(
              'CREATE TABLE _spc_sources(id INTEGER PRIMARY KEY,name TEXT NOT NULL,keys_json TEXT NOT NULL,columns_json TEXT NOT NULL,schema_sql TEXT NOT NULL,triggers_json TEXT NOT NULL,enabled INTEGER NOT NULL)');
          await database.execute(
              'CREATE TABLE _spc_events(id INTEGER PRIMARY KEY,batch_id INTEGER NOT NULL,source_id INTEGER NOT NULL,kind TEXT NOT NULL,old_key TEXT,new_key TEXT,columns_json TEXT NOT NULL)');
          await database.execute(
              'CREATE INDEX _spc_events_batch ON _spc_events(batch_id)');
          await database.execute(
              'CREATE TABLE _spc_batches(id INTEGER PRIMARY KEY,event_count INTEGER NOT NULL)');
          await database.execute('INSERT INTO _spc_batches VALUES(0,0)');
          await database.execute(
              'CREATE INDEX _spc_batches_count ON _spc_batches(event_count)');
          await database.execute(
              'CREATE TABLE _spc_consumers(id INTEGER PRIMARY KEY,name TEXT NOT NULL,acked_batch INTEGER NOT NULL,delivered_batch INTEGER NOT NULL,feed_id TEXT NOT NULL)');
          final random = Random.secure();
          final id = List.generate(16,
                  (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
              .join();
          await database
              .execute('INSERT INTO _spc_state VALUES(1,1,?,1,0,NULL)', [id]);
        });
      } else if (owned.length != _tableNames.length ||
          !owned.containsAll(_tableNames)) {
        throw const ChangeLogCorrupt(
            'Missing or unexpected reserved tables; no automatic repair');
      }
      await feed._state();
      if (!allowSchemaRepair) await feed._verifySources();
      _handles[database] = feed;
    });
    return feed;
  }

  Future<T> _run<T>(Future<T> Function() action) {
    if (Zone.current[_zoneKey] == database) {
      return Future.error(StateError(
          'Use the ChangeWriter inside a changes operation, not reentrant feed calls'));
    }
    final previous = _queues[database] ?? Future<void>.value();
    final next = previous.then((_) {
      if (database.inTransaction) {
        throw StateError(
            'Changes requires exclusive use outside caller transactions');
      }
      return runZoned(action, zoneValues: {_zoneKey: database});
    });
    _queues[database] =
        next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  /// Serialize application connection setup/schema/readonly work with capture.
  /// Source writes remain guarded outside a producer transaction. Callbacks
  /// must finish every raw transaction; no capture suspension is installed.
  Future<T> exclusive<T>(Future<T> Function(MutableSqliteDatabase db) action,
          {bool notifyReset = false}) =>
      _run(() async {
        try {
          final value = await action(database);
          if (database.inTransaction) {
            throw StateError('Exclusive callback left a transaction open');
          }
          if (notifyReset && (_signals[database]?.hasListener ?? false)) {
            final state = await _state();
            _notify(state.at(state.head), reset: true);
          }
          return value;
        } catch (error, stack) {
          if (database.inTransaction) {
            try {
              await database.execute('ROLLBACK');
            } catch (_) {}
          }
          Error.throwWithStackTrace(error, stack);
        }
      });

  Future<T> _atomic<T>(Future<T> Function() action) async {
    await database.execute('BEGIN');
    try {
      final result = await action();
      if (!database.inTransaction) {
        throw StateError('Changes transaction ended unexpectedly');
      }
      await database.execute('COMMIT');
      return result;
    } catch (error, stack) {
      if (database.inTransaction) {
        try {
          await database.execute('ROLLBACK');
        } catch (_) {/* Preserve the original failure. */}
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<_State> _state() async {
    final rows = await database.query(
        'SELECT id,format,feed_id,next_batch,pruned_through,active_batch FROM _spc_state');
    if (rows.rows.length != 1) {
      throw const ChangeLogCorrupt('Invalid state row count');
    }
    final row = rows.rows.single;
    if (row[0] != BigInt.one ||
        row[1] != BigInt.one ||
        row[2] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(row[2] as String) ||
        row[5] != null) {
      throw const ChangeLogCorrupt(
          'Unsupported format, active scope or malformed feed identity');
    }
    final anchor =
        await database.query('SELECT event_count FROM _spc_batches WHERE id=0');
    if (anchor.rows.length != 1 || anchor.rows.single.single != BigInt.zero) {
      throw const ChangeLogCorrupt('Missing transaction anchor');
    }
    final indexes = await database
        .query("SELECT name,sql FROM sqlite_schema WHERE type='index'");
    final definitions = {for (final item in indexes.rows) item[0]: item[1]};
    if (definitions['_spc_events_batch'] !=
            'CREATE INDEX _spc_events_batch ON _spc_events(batch_id)' ||
        definitions['_spc_batches_count'] !=
            'CREATE INDEX _spc_batches_count ON _spc_batches(event_count)') {
      throw const ChangeLogCorrupt('Missing or altered log indexes');
    }
    final next = _integer(row[3]), floor = _integer(row[4]);
    if (next < BigInt.one ||
        next > _maximum ||
        floor.isNegative ||
        floor >= next) {
      throw const ChangeLogCorrupt('Invalid retained range');
    }
    return _State(row[2] as String, next, floor);
  }

  /// Publishes all captured events and the source writes in one database commit.
  /// A callback must use its writer for DML; recursive_triggers must be ON.
  Future<T> transaction<T>(Future<T> Function(ChangeWriter tx) action,
          {int maxEvents = 1000000}) =>
      _run(() async {
        if (maxEvents < 1 || maxEvents > 1000000) {
          throw ArgumentError('maxEvents must be 1..1000000');
        }
        final state = await _state();
        await _verifySources();
        await _requireRecursiveTriggers();
        if (state.next == _maximum) {
          throw StateError('Changes sequence exhausted');
        }
        ChangeCheckpoint? published;
        final value = await _atomic(() async {
          await database.execute(
              'UPDATE _spc_state SET active_batch=? WHERE id=1', [state.next]);
          final writer = ChangeWriter._(this, state);
          late T result;
          try {
            result = await action(writer);
            await writer._finish();
          } catch (_) {
            await writer._stop();
            rethrow;
          }
          final count = _integer((await database.query(
                  'SELECT count(*) FROM _spc_events WHERE batch_id=?',
                  [state.next]))
              .rows
              .single
              .single);
          if (count > BigInt.from(maxEvents)) {
            throw ChangeBatchTooLarge(state.next, count, maxEvents);
          }
          if (count > BigInt.zero) {
            published = state.at(state.next);
            await database.execute(
                'INSERT INTO _spc_batches VALUES(?,?)', [state.next, count]);
            await database.execute(
                'UPDATE _spc_state SET next_batch=? WHERE id=1',
                [state.next + BigInt.one]);
          }
          await database
              .execute('UPDATE _spc_state SET active_batch=NULL WHERE id=1');
          return result;
        });
        if (published != null) _notify(published!);
        return value;
      });

  /// Call explicitly after restoring or forking an image. Existing consumers
  /// must resnapshot and reset; raw file copies cannot be detected automatically.
  Future<void> rotateGeneration() => _run(() async {
        await _verifySources();
        final state = await _state();
        final random = Random.secure();
        final id = List.generate(16,
                (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
            .join();
        await _atomic(() => database
            .execute('UPDATE _spc_state SET feed_id=? WHERE id=1', [id]));
        _notify(ChangeCheckpoint(id, state.head), reset: true);
      });

  Future<ChangeCheckpoint> head() => _run(() async {
        await _verifySources();
        final state = await _state();
        return state.at(state.head);
      });
}
