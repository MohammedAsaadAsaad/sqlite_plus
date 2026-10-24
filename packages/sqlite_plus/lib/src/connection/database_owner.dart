import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../pager/rollback_journal_pager.dart';
import '../pager/wal_pager.dart';
import '../sql/database.dart';
import '../sql/mutable_database.dart';
import '../sql/tokenizer.dart';
import '../storage/durable_file_storage_backend.dart';

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

  static Future<DatabaseOwner> open(String path,
      {required bool directoryEntriesDurable, bool wal = false}) async {
    if (!directoryEntriesDurable) {
      throw UnsupportedError('Durably provision database and sidecar first');
    }
    final canonical = await File(path).resolveSymbolicLinks();
    final ready = ReceivePort();
    final admin = Capability();
    final isolate =
        await Isolate.spawn(_runOwner, [canonical, wal, admin, ready.sendPort]);
    try {
      final response =
          await ready.first.timeout(const Duration(seconds: 30)) as List;
      if (response[0] != 'ready') throw StateError(response[1] as String);
      final port = response[1] as SendPort;
      return DatabaseOwner._(
          isolate, port, admin, DatabaseClient.connect(port));
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      rethrow;
    } finally {
      ready.close();
    }
  }

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
  Future<Object?> _request(String operation, List<Object?> arguments,
      {Capability? admin}) async {
    if (_closed) throw StateError('Client closed');
    final reply = ReceivePort();
    try {
      _owner.send([_identity, operation, arguments, reply.sendPort, admin]);
      final result =
          await reply.first.timeout(const Duration(seconds: 30)) as List;
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
      try {
        final identity = raw[0] as Capability;
        final operation = raw[1] as String;
        final values = raw[2] as List;
        if (operation == 'shutdown') {
          if (raw[4] != admin) throw StateError('Owner authority required');
          await active.close();
          database = null;
          await guard!.close();
          guard = null;
          reply.send(['ok', null]);
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
            [result.columns, result.rows]
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
            ]
          ]);
        } else if (operation == 'checkpoint') {
          if (active.inTransaction || walPager == null) {
            throw StateError(
                'Checkpoint requires WAL mode without an active transaction');
          }
          await walPager.checkpoint();
          reply.send(['ok', null]);
        } else {
          throw ArgumentError('Unknown owner operation');
        }
      } catch (error) {
        reply.send([
          'error',
          error is SqlException ? 'sql' : 'state',
          error is SqlException ? error.message : error.toString()
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
