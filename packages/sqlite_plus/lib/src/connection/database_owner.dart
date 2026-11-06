import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../app/app_commands.dart';
import '../pager/rollback_journal_pager.dart';
import '../pager/wal_pager.dart';
import '../sql/database.dart';
import '../sql/mutable_database.dart';
import '../sql/tokenizer.dart';
import '../storage/durable_file_storage_backend.dart';

/// Called once, before the version check.
typedef OnDatabaseConfigure = Future<void> Function(DatabaseOwner database);

/// Called when the stored version is 0.
typedef OnDatabaseCreate = Future<void> Function(
    DatabaseOwner database, int version);

/// Called when the stored version and the requested version differ.
typedef OnDatabaseVersionChange = Future<void> Function(
    DatabaseOwner database, int oldVersion, int newVersion);

/// Called after the version check on every open.
typedef OnDatabaseOpen = Future<void> Function(DatabaseOwner database);

/// Opens a database file on its own isolate.
///
/// A missing database file is written as an empty image, and a missing
/// `-journal` is written empty, unless [wal] is true. An existing database
/// file is not replaced. [directoryEntriesDurable] defaults to true. Passing
/// false writes nothing and throws. That flag is the caller attestation that
/// the directory entries are durable. It is not a power-loss result. [wal]
/// still requires the `-wal` sidecar and does not create it.
///
/// [version] runs [onCreate] when the stored version is 0, [onUpgrade] when
/// it is older, and [onDowngrade] when it is newer. The schema change and the
/// new version commit together. Integers in rows and insert ids are [BigInt].
Future<DatabaseOwner> openDatabase(
  String path, {
  bool directoryEntriesDurable = true,
  bool wal = false,
  int? version,
  OnDatabaseConfigure? onConfigure,
  OnDatabaseCreate? onCreate,
  OnDatabaseVersionChange? onUpgrade,
  OnDatabaseVersionChange? onDowngrade,
  OnDatabaseOpen? onOpen,
}) async {
  if (version != null && version < 1) {
    throw ArgumentError.value(version, 'version', 'version starts at 1');
  }
  if (version != null && onCreate == null) {
    throw ArgumentError('onCreate is required when version is set');
  }
  if (!directoryEntriesDurable) {
    throw UnsupportedError('Durably provision database and sidecar first');
  }
  if (!wal) await _provisionRollback(path);
  final owner =
      await DatabaseOwner.open(path, directoryEntriesDurable: true, wal: wal);
  try {
    if (onConfigure != null) await onConfigure(owner);
    if (version != null) {
      await owner.transaction((txn) async {
        final current = await owner._app.readUserVersion();
        if (current == 0) {
          await onCreate!(owner, version);
        } else if (current < version) {
          if (onUpgrade == null) {
            throw StateError(
                'Database version $current is older than $version');
          }
          await onUpgrade(owner, current, version);
        } else if (current > version) {
          if (onDowngrade == null) {
            throw StateError(
                'Database version $current is newer than $version');
          }
          await onDowngrade(owner, current, version);
        }
        if (current != version) {
          await txn.execute('PRAGMA user_version = $version');
        }
      });
    }
    if (onOpen != null) await onOpen(owner);
    return owner;
  } catch (_) {
    await owner.close();
    rethrow;
  }
}

/// Writes an empty database image and an empty `-journal` when either is
/// missing. An existing database file is not replaced or deleted.
Future<void> _provisionRollback(String path) async {
  final database = File(path);
  final journal = File('$path-journal');
  if (!await database.exists()) {
    await database.parent.create(recursive: true);
    final created = await MutableSqliteDatabase.create();
    try {
      await database.writeAsBytes(created.exportImage(), flush: true);
    } finally {
      await created.close();
    }
  }
  if (!await journal.exists()) {
    await journal.parent.create(recursive: true);
    await journal.writeAsBytes(const <int>[], flush: true);
  }
}

/// A single connection/handle owner. Share [sendPort] with other isolates and
/// connect through DatabaseClient; never open additional file handles directly.
///
/// Existing file entries must already be durable. All participating clients use
/// the same canonical path (hard-link aliases are unsupported). A loopback port
/// lease also prevents separate owner isolates in this process from bypassing
/// POSIX's process-scoped file locks. Hash/port collisions fail closed as busy.
/// No SQL/data is served over the socket; RPC uses Dart SendPorts only.
final class DatabaseOwner {
  DatabaseOwner._(this._isolate, this.sendPort, this._admin, this.client);
  final Isolate _isolate;
  final SendPort sendPort;
  final Capability _admin;
  final DatabaseClient client;
  bool _closed = false;

  /// Whether [close] has not run.
  bool get isOpen => !_closed;
  AppCommands? _commands;

  AppCommands get _app => _commands ??= AppCommands(
        query: (sql, parameters) => client.query(sql, parameters),
        execute: (sql, parameters) => client.execute(sql, parameters),
        inTransaction: () => client.inTransaction,
        isOpen: () => !_closed,
      );

  static Future<DatabaseOwner> open(String path,
      {required bool directoryEntriesDurable, bool wal = false}) async {
    if (!directoryEntriesDurable) {
      throw UnsupportedError('Durably provision database and sidecar first');
    }
    final canonical = await File(path).resolveSymbolicLinks();
    final ready = ReceivePort();
    final exited = ReceivePort();
    final admin = Capability();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
          _runOwner, [canonical, wal, admin, ready.sendPort]);
      isolate.addOnExitListener(exited.sendPort);
      final response =
          await ready.first.timeout(const Duration(seconds: 30)) as List;
      if (response[0] != 'ready') {
        // The owner reports the error before its finally closes the files.
        // Killing it there leaves Windows holding the directory.
        await _releaseFailedOwner(isolate, exited);
        isolate = null;
        throw StateError(response[1] as String);
      }
      isolate.removeOnExitListener(exited.sendPort);
      final port = response[1] as SendPort;
      final opened = isolate;
      isolate = null;
      return DatabaseOwner._(opened, port, admin, DatabaseClient.connect(port));
    } catch (_) {
      if (isolate != null) await _releaseFailedOwner(isolate, exited);
      rethrow;
    } finally {
      ready.close();
      exited.close();
    }
  }

  static Future<void> _releaseFailedOwner(
      Isolate isolate, ReceivePort exited) async {
    try {
      await exited.first.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      isolate.kill(priority: Isolate.immediate);
    }
  }

  /// Runs a statement that changes rows. This is [DatabaseClient.execute].
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      client.execute(sql, parameters);

  /// Runs one statement and returns the rows as maps.
  ///
  /// Integer cells are [BigInt]. This is the SQL form of [query].
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      _app.rawQuery(sql, arguments);

  /// Runs one insert and returns its row id.
  Future<BigInt> rawInsert(String sql, [List<Object?>? arguments]) =>
      _app.rawInsert(sql, arguments);

  /// Runs one update and returns the changed-row count.
  Future<int> rawUpdate(String sql, [List<Object?>? arguments]) =>
      _app.rawUpdate(sql, arguments);

  /// Runs one delete and returns the changed-row count.
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) =>
      _app.rawDelete(sql, arguments);

  /// Inserts [values] and returns the new row id.
  Future<BigInt> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      _app.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  /// Reads [table]. [where] is SQL, and its values belong in [whereArgs].
  ///
  /// Integer cells are [BigInt].
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) =>
      _app.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);

  /// Updates the rows selected by [where] and returns the changed-row count.
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      _app.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);

  /// Deletes the rows selected by [where] and returns the changed-row count.
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      _app.delete(table, where: where, whereArgs: whereArgs);

  /// Runs [action] in a transaction. A nested call uses a savepoint.
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action) =>
      _app.transaction(action);

  /// Collects statements and runs them in [Batch.commit].
  Batch batch() => _app.batch();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      final control = DatabaseClient.connect(sendPort);
      try {
        await control._request('shutdown', const [], admin: _admin);
      } finally {
        control.close();
      }
    } finally {
      client.close();
      _isolate.kill(priority: Isolate.immediate);
    }
  }
}

/// A logical client. Concurrent operations are serialized by the owner. An
/// explicit transaction belongs to the client that began it; other clients
/// receive StateError until commit/rollback. Lost clients can be recovered by
/// closing the owner, which rolls back uncommitted state.
final class DatabaseClient {
  DatabaseClient.connect(this._owner);
  final SendPort _owner;
  final Capability _identity = Capability();
  bool _closed = false;
  bool _inTransaction = false;

  /// Whether this client owns an open transaction.
  ///
  /// The value comes from the last completed request on this client.
  bool get inTransaction => _inTransaction;

  Future<Object?> _request(String operation, List<Object?> arguments,
      {Capability? admin}) async {
    if (_closed) throw StateError('Client closed');
    final reply = ReceivePort();
    try {
      _owner.send([_identity, operation, arguments, reply.sendPort, admin]);
      final result =
          await reply.first.timeout(const Duration(seconds: 30)) as List;
      final flag = result[0] == 'error' ? 3 : 2;
      if (result.length > flag && result[flag] is bool) {
        _inTransaction = result[flag] as bool;
      }
      if (result[0] == 'error') {
        if (result[1] == 'sql') throw SqlException(result[2] as String);
        throw StateError(result[2] as String);
      }
      return result[1];
    } finally {
      reply.close();
    }
  }

  Future<QueryResult> query(String sql,
      [List<Object?> parameters = const []]) async {
    final result = await _request('query', [sql, parameters]) as List;
    return QueryResult(
        List<String>.from(result[0] as List),
        (result[1] as List)
            .map((row) => List<Object?>.from(row as List))
            .toList());
  }

  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    final result = await _request('execute', [sql, parameters]) as List;
    return MutationResult(
        result[0] as int,
        result[1] as BigInt?,
        result[2] == null
            ? null
            : QueryResult(
                List<String>.from((result[2] as List)[0] as List),
                ((result[2] as List)[1] as List)
                    .map((row) => List<Object?>.from(row as List))
                    .toList()));
  }

  Future<void> checkpoint() async {
    await _request('checkpoint', const []);
  }

  void close() {
    _closed = true;
  }
}

int _leasePort(String path) {
  var hash = 2166136261;
  for (final byte in utf8.encode(path)) {
    hash = ((hash ^ byte) * 16777619) % 0x100000000;
  }
  return 20000 + hash % 40000;
}

Future<void> _runOwner(List<Object?> args) async {
  final path = args[0] as String;
  final walMode = args[1] as bool;
  final admin = args[2] as Capability;
  final startup = args[3] as SendPort;
  final requests = ReceivePort();
  ServerSocket? guard;
  DurableFileStorageBackend? main;
  DurableFileStorageBackend? sidecar;
  MutableSqliteDatabase? database;
  WalPager? walPager;
  var announced = false;
  try {
    guard = await ServerSocket.bind(
        InternetAddress.loopbackIPv4, _leasePort(path),
        shared: false);
    guard.listen((socket) => socket.destroy());
    // Closing any same-process descriptor can drop a POSIX lock; only this
    // isolate opens a handle to main, after acquiring the cross-isolate guard.
    main = await DurableFileStorageBackend.openExclusive(path,
        directoryEntryIsDurable: true);
    if (walMode && await File('$path-shm').exists()) {
      throw UnsupportedError(
          'Existing wal-index must be removed by safe provisioning before exclusive WAL ownership');
    }
    if (!walMode &&
        await File('$path-wal').exists() &&
        await File('$path-wal').length() != 0) {
      throw UnsupportedError('Pending WAL exists; open in WAL mode');
    }
    if (walMode && await File('$path-journal').exists()) {
      final bytes = await File('$path-journal').open();
      try {
        final header = await bytes.read(28);
        if (header.any((value) => value != 0)) {
          throw UnsupportedError('Unresolved rollback journal');
        }
      } finally {
        await bytes.close();
      }
    }
    final sidecarPath = '$path${walMode ? '-wal' : '-journal'}';
    if (await FileSystemEntity.identical(path, sidecarPath)) {
      throw ArgumentError('Sidecar aliases main');
    }
    sidecar = await DurableFileStorageBackend.openExisting(sidecarPath,
        directoryEntryIsDurable: true);
    if (walMode) {
      walPager = await WalPager.open(main, sidecar,
          exclusiveOwnership: true, walIndexAbsent: true);
      database = await MutableSqliteDatabase.fromImagePager(walPager);
    } else {
      database = await MutableSqliteDatabase.fromImagePager(
          await RollbackJournalPager.open(main, sidecar));
    }
    final active = database;
    Capability? transactionOwner;
    startup.send(['ready', requests.sendPort]);
    announced = true;
    await for (final raw in requests) {
      if (raw is! List || raw.length != 5 || raw[3] is! SendPort) continue;
      final reply = raw[3] as SendPort;
      Capability? identity;
      try {
        identity = raw[0] as Capability;
        final operation = raw[1] as String;
        final values = raw[2] as List;
        if (operation == 'shutdown') {
          if (raw[4] != admin) throw StateError('Owner authority required');
          await active.close();
          database = null;
          await guard!.close();
          guard = null;
          reply.send(['ok', null, false]);
          break;
        }
        if (transactionOwner != null && transactionOwner != identity) {
          throw StateError('Transaction belongs to another client');
        }
        if (operation == 'query') {
          final result = await active.query(
              values[0] as String, List<Object?>.from(values[1] as List));
          reply.send([
            'ok',
            [result.columns, result.rows],
            identical(transactionOwner, identity)
          ]);
        } else if (operation == 'execute') {
          final result = await active.execute(
              values[0] as String, List<Object?>.from(values[1] as List));
          transactionOwner = active.inTransaction ? identity : null;
          reply.send([
            'ok',
            [
              result.changes,
              result.lastInsertRowid,
              result.returning == null
                  ? null
                  : [result.returning!.columns, result.returning!.rows]
            ],
            identical(transactionOwner, identity)
          ]);
        } else if (operation == 'checkpoint') {
          if (active.inTransaction || walPager == null) {
            throw StateError(
                'Checkpoint requires WAL mode without an active transaction');
          }
          await walPager.checkpoint();
          reply.send(['ok', null, identical(transactionOwner, identity)]);
        } else {
          throw ArgumentError('Unknown owner operation');
        }
      } catch (error) {
        if (!active.inTransaction) transactionOwner = null;
        reply.send([
          'error',
          error is SqlException ? 'sql' : 'state',
          error is SqlException ? error.message : error.toString(),
          identity != null && identical(transactionOwner, identity)
        ]);
      }
    }
  } catch (error) {
    if (!announced) startup.send(['error', error.toString()]);
  } finally {
    try {
      if (database != null) {
        await database.close();
      } else {
        await main?.close();
        await sidecar?.close();
      }
    } finally {
      await guard?.close();
      requests.close();
    }
  }
}
