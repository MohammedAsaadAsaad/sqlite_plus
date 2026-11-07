import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'protocol.dart';

part 'storage.dart';
part 'producer.dart';
part 'receiver.dart';

String _quote(String value) => '"${value.replaceAll('"', '""')}"';
BigInt _int(Object? value) {
  if (value is! BigInt) {
    throw const SyncStateException('Integer metadata expected');
  }
  return value;
}

Map<String, dynamic> _json(String text) =>
    (jsonDecode(text) as Map).cast<String, dynamic>();
final _max = (BigInt.one << 63) - BigInt.one;
final _syncZone = Object();

/// Explicit synchronization on an exclusively owned application connection.
/// Source writes may use Changes while transport awaits; raw SQL must not
/// interleave local database callbacks or open/register operations.
final class SqlitePlusSync {
  SqlitePlusSync._(this.changes, this.transport, this.scope);
  final SqlitePlusChanges changes;
  final SyncTransport transport;
  final String scope;
  MutableSqliteDatabase get database => changes.database;
  late final ChangeConsumer _consumer;
  static final _queues = Expando<Future<void>>();

  static Future<SqlitePlusSync> open(
      {required SqlitePlusChanges changes,
      required SyncTransport transport,
      required String scope,
      String? replicaId}) async {
    if (scope.isEmpty || scope.length > 512 || scope.contains('\u0000')) {
      throw ArgumentError('A stable server namespace is required');
    }
    if (replicaId != null &&
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(replicaId)) {
      throw ArgumentError('replicaId: 1..128 ASCII letters/digits/_/-');
    }
    final sync = SqlitePlusSync._(changes, transport, scope);
    await sync._run(() async {
      if (sync.database.inTransaction) {
        throw StateError('Open outside a transaction');
      }
      final head = await changes.head();
      await sync._openStorage(head, replicaId);
      final state = await changes.transaction((tx) => sync._state(tx));
      sync._consumer = await changes.consumer(
          name: '_spsync_outbound',
          startAt: ChangeCheckpoint(state.feed, state.initial),
          resumeExisting: true);
    });
    return sync;
  }

  Future<T> _run<T>(Future<T> Function() action) {
    if (Zone.current[_syncZone] == database) {
      return Future.error(StateError('Reentrant Sync calls are unsupported'));
    }
    final previous = _queues[database] ?? Future<void>.value();
    final next = previous
        .then((_) => runZoned(action, zoneValues: {_syncZone: database}));
    _queues[database] =
        next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  /// Registers future changes. Existing rows require explicit bounded bootstrap.
  Future<void> register(
          {required String table,
          List<String>? primaryKey,
          required List<String> columns,
          bool seedExisting = false,
          int maxSeedRows = 1000}) =>
      _run(() async {
        if (table.isEmpty ||
            table.toLowerCase().startsWith('_spsync_') ||
            columns.isEmpty ||
            columns.toSet().length != columns.length ||
            maxSeedRows < 1 ||
            maxSeedRows > 100000) {
          throw ArgumentError('Invalid table/columns/seed budget');
        }
        final info =
            await database.query('PRAGMA table_info(${_quote(table)})');
        final declared = info.rows
            .where((row) => _int(row[5]) > BigInt.zero)
            .toList()
          ..sort((a, b) => _int(a[5]).compareTo(_int(b[5])));
        final keys = List<String>.of(
            primaryKey ?? declared.map((row) => row[1] as String));
        final fields = <String>{...keys, ...columns}.toList();
        if (keys.isEmpty ||
            keys.toSet().length != keys.length ||
            keys.length != declared.length ||
            !keys.every(declared.map((r) => r[1]).contains) ||
            !fields.every(info.rows.map((r) => r[1]).contains) ||
            fields.any((name) => name.toLowerCase().startsWith('_spc_'))) {
          throw ArgumentError(
              'Complete declared keys and existing columns required');
        }
        final existing = await changes.transaction((tx) async {
          await _state(tx);
          return (await _configs(tx)).where((c) => c.name == table).firstOrNull;
        });
        if (existing != null) {
          if (jsonEncode(existing.keys) != jsonEncode(keys) ||
              jsonEncode(existing.columns) != jsonEncode(fields)) {
            throw const SyncStateException(
                'Registration differs; no automatic migration');
          }
          return;
        }
        final rows = await database.query(
            'SELECT ${fields.map(_quote).join(',')} FROM ${_quote(table)} LIMIT ${maxSeedRows + 1}');
        if (rows.rows.isNotEmpty && !seedExisting) {
          throw const SyncStateException(
              'Existing rows require seedExisting: true');
        }
        if (rows.rows.length > maxSeedRows) {
          throw const SyncStateException('Seed budget exceeded');
        }
        final sources = await changes.sources();
        final tracked = sources.where((s) => s.table == table).firstOrNull;
        if (tracked == null) {
          await changes.track(table: table, primaryKey: keys, columns: fields);
        } else if (jsonEncode(tracked.primaryKey) != jsonEncode(keys) ||
            !fields.every(tracked.columns.contains)) {
          throw const SyncStateException(
              'Changes registration must cover the sync keys/columns');
        }
        await changes.transaction((tx) async {
          final state = await _state(tx);
          if ((await _configs(tx)).any((c) => c.name == table)) {
            throw const SyncStateException('Concurrent registration');
          }
          final definition = await tx.query(
              "SELECT sql FROM sqlite_schema WHERE type='table' AND name=?",
              [table]);
          await tx.execute(
              'INSERT INTO _spsync_tables(name,keys_json,columns_json,schema_sql) VALUES(?,?,?,?)',
              [
                table,
                jsonEncode(keys),
                jsonEncode(fields),
                definition.rows.single.single
              ]);
          final configs = await _configs(tx);
          final config = configs.singleWhere((c) => c.name == table);
          final seed = await tx.query(
              'SELECT ${fields.map(_quote).join(',')} FROM ${_quote(table)} LIMIT ${maxSeedRows + 1}');
          if (seed.rows.length > maxSeedRows ||
              seed.rows.isNotEmpty && !seedExisting) {
            throw const SyncStateException(
                'Source changed during registration; retry explicitly');
          }
          if (seed.rows.isNotEmpty) {
            if (await _outbox(tx) != null) {
              throw const SyncStateException(
                  'Drain the existing outbox before seeding');
            }
            final mutations = <SyncMutation>[];
            for (final row in seed.rows) {
              final values = {
                for (var i = 0; i < fields.length; i++) fields[i]: row[i]
              };
              final key = {for (final key in keys) key: values[key]};
              config.key(key);
              mutations.add(SyncMutation(
                  table: table, key: key, baseVersion: null, values: values));
            }
            await _enqueue(tx, state, mutations);
          }
        });
      });

  /// One bounded push followed by one pull page. Network failures propagate;
  /// frozen outbox/cursor state remains available for retry.
  Future<SyncResult> runOnce(
          {int maxMutations = 1000,
          int maxPullRecords = 1000,
          int maxTransactions = 100,
          int maxEvents = 10000}) =>
      _run(() async {
        if (maxMutations < 1 ||
            maxMutations > 100000 ||
            maxPullRecords < 1 ||
            maxPullRecords > 100000) {
          throw ArgumentError('Mutation/record budgets must be 1..100000');
        }
        final blocked = await changes.transaction((tx) async {
          await _state(tx);
          return await _conflict(tx) != null;
        });
        if (blocked) return const SyncResult(conflicts: 1);
        final operation =
            await _prepare(maxMutations, maxTransactions, maxEvents);
        var pushed = 0;
        if (operation != null) {
          final reply = await transport.push(operation);
          final accepted = await _pushReply(operation, reply);
          if (!accepted) return const SyncResult(conflicts: 1);
          pushed = operation.mutations.length;
        }
        final cursor =
            await changes.transaction((tx) async => (await _state(tx)).cursor);
        final request =
            SyncPullRequest(scope: scope, after: cursor, limit: maxPullRecords);
        final page = await transport.pull(request);
        final applied = await _pullPage(request, page);
        return SyncResult(
            pushed: pushed,
            pulled: applied < 0 ? 0 : applied,
            conflicts: applied < 0 ? 1 : 0,
            hasMore: page.hasMore);
      });

  Future<List<SyncConflict>> conflicts() =>
      _run(() => changes.transaction((tx) async {
            final state = await _state(tx);
            final row = await _conflict(tx);
            if (row == null) return const <SyncConflict>[];
            final payload = _json(row[2] as String);
            return [
              SyncConflict(
                  id: '${state.replica}:${state.feed}:conflict:${row[0]}',
                  direction: row[1] as String,
                  remote: [
                    for (final value in payload['records'] as List)
                      SyncRecord.fromJson(
                          (value as Map).cast<String, dynamic>())
                  ])
            ];
          }));

  Future<void> resolveConflict(String id, SyncResolution resolution) =>
      _run(() => _resolve(id, resolution));
}
