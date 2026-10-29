import 'dart:io';
import 'dart:isolate';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';

import 'bench_model.dart';

class SqlitePlusBenchEngine implements BenchEngine {
  SqlitePlusBenchEngine({this.storage = BenchStorage.memory, this.filePath});

  @override
  final BenchStorage storage;

  final String? filePath;

  @override
  String get id => 'sqlite_plus';

  @override
  String get label => 'sqlite_plus';

  @override
  String? get location => storage == BenchStorage.file ? filePath : null;

  @override
  Future<BenchSample> run(
    BenchOp op,
    int count,
    void Function(int done, int total) onProgress,
  ) async {
    requireBenchCount(count);
    if (storage == BenchStorage.memory) {
      final database = await MutableSqliteDatabase.create();
      try {
        return await _measure(
          _MemorySession(database),
          op,
          count,
          onProgress,
          storage: storage,
          after: () async {
            final exported = Stopwatch()..start();
            final storedBytes = database.exportImage().length;
            exported.stop();
            return (exported.elapsedMicroseconds, storedBytes);
          },
        );
      } catch (error) {
        if (database.inTransaction) {
          try {
            await database.execute('ROLLBACK');
          } catch (_) {}
        }
        rethrow;
      } finally {
        await database.close();
      }
    }
    final path = filePath;
    if (path == null) {
      throw StateError('File bench needs a path');
    }
    await _provision(path);
    // The bench isolate owns this file for one run. Opening the pager here
    // avoids DatabaseOwner's loopback socket, which Android release builds
    // reject. directoryEntryIsDurable is the caller attestation after flush.
    // It is not a power-loss result.
    final database = await _openFile(path);
    try {
      return await _measure(
        _MemorySession(database),
        op,
        count,
        onProgress,
        storage: storage,
        after: () async => (0, await _fileBytes(path)),
      );
    } catch (error) {
      if (database.inTransaction) {
        try {
          await database.execute('ROLLBACK');
        } catch (_) {}
      }
      rethrow;
    } finally {
      await database.close();
    }
  }
}

Future<MutableSqliteDatabase> _openFile(String path) async {
  final main = await DurableFileStorageBackend.openExclusive(
    path,
    directoryEntryIsDurable: true,
  );
  DurableFileStorageBackend? journal;
  ImagePager? pager;
  try {
    journal = await DurableFileStorageBackend.openExisting(
      '$path-journal',
      directoryEntryIsDurable: true,
    );
    pager = await RollbackJournalPager.open(main, journal);
    return await MutableSqliteDatabase.fromImagePager(pager);
  } catch (error) {
    if (pager != null) {
      await pager.close();
    } else {
      await journal?.close();
      await main.close();
    }
    rethrow;
  }
}

Future<void> sqlitePlusBenchEntry(Map<String, Object?> message) async {
  final send = message['send']! as SendPort;
  try {
    final storageIndex =
        message['storage'] as int? ?? BenchStorage.memory.index;
    final sample =
        await SqlitePlusBenchEngine(
          storage: BenchStorage.values[storageIndex],
          filePath: message['path'] as String?,
        ).run(
          BenchOp.values[message['op']! as int],
          message['count']! as int,
          (done, total) =>
              send.send({'kind': 'progress', 'done': done, 'total': total}),
        );
    send.send(sample.toMessage());
  } catch (error) {
    send.send({'kind': 'error', 'message': '$error'});
  }
}

Future<void> _provision(String path) async {
  for (final suffix in const ['', '-wal', '-shm', '-journal']) {
    final file = File('$path$suffix');
    if (await file.exists()) await file.delete();
  }
  final created = await MutableSqliteDatabase.create();
  try {
    await File(path).writeAsBytes(created.exportImage(), flush: true);
  } finally {
    await created.close();
  }
  await File('$path-journal').writeAsBytes(const <int>[], flush: true);
}

Future<int> _fileBytes(String path) async {
  var total = 0;
  for (final suffix in const ['', '-wal', '-shm', '-journal']) {
    final file = File('$path$suffix');
    if (await file.exists()) total += await file.length();
  }
  return total;
}

abstract class _PlusSession {
  Future<MutationResult> execute(String sql, [List<Object?> parameters]);
  Future<QueryResult> query(String sql, [List<Object?> parameters]);
}

class _MemorySession implements _PlusSession {
  _MemorySession(this._database);

  final MutableSqliteDatabase _database;

  @override
  Future<MutationResult> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    return _database.execute(sql, parameters);
  }

  @override
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    return _database.query(sql, parameters);
  }
}

Future<BenchSample> _measure(
  _PlusSession database,
  BenchOp op,
  int count,
  void Function(int done, int total) onProgress, {
  required BenchStorage storage,
  required Future<(int, int)> Function() after,
}) async {
  final prepare = Stopwatch()..start();
  await database.execute(benchCreateTable);
  if (benchNeedsSeed(op)) {
    await _insertAll(database, count, transaction: true, onProgress: null);
  }
  if (benchBuildsNameIndex(op)) {
    await database.execute(benchNameIndex);
  }
  prepare.stop();
  onProgress(0, count);
  final before = ProcessSample.now();
  final measured = Stopwatch()..start();
  final hits = await _operation(database, op, count, onProgress);
  measured.stop();
  final afterSample = ProcessSample.now();
  final totals = await _checksum(database);
  final exported = await after();
  return BenchSample(
    engineId: 'sqlite_plus',
    engineLabel: 'sqlite_plus',
    op: op,
    count: count,
    elapsedMicros: measured.elapsedMicroseconds,
    cpuMicros: afterSample.cpuMicrosSince(before),
    rssBefore: before.rssBytes,
    rssAfter: afterSample.rssBytes,
    rows: totals.$1,
    checksum: totals.$2,
    hits: hits,
    prepareMicros: prepare.elapsedMicroseconds,
    exportMicros: exported.$1,
    storedBytes: exported.$2,
    storage: storage,
  );
}

Future<(int, int)> _checksum(_PlusSession database) async {
  final result = await database.query(benchChecksum);
  final row = result.rows.single;
  return (benchInt(row[0]), benchInt(row[1]));
}

Future<int> _operation(
  _PlusSession database,
  BenchOp op,
  int count,
  void Function(int done, int total) onProgress,
) {
  return switch (op) {
    BenchOp.separateInsert => _insertAll(
      database,
      count,
      transaction: false,
      onProgress: onProgress,
    ),
    BenchOp.transactionInsert => _insertAll(
      database,
      count,
      transaction: true,
      onProgress: onProgress,
    ),
    BenchOp.separateUpdate => _each(
      database,
      count,
      benchUpdateOne,
      onProgress,
      readChanges: true,
    ),
    BenchOp.bulkUpdate => _once(database, benchUpdateAll, count, onProgress),
    BenchOp.search => _each(
      database,
      count,
      benchSearch,
      onProgress,
      readChanges: false,
    ),
    BenchOp.point => _each(
      database,
      count,
      benchPoint,
      onProgress,
      readChanges: false,
    ),
    BenchOp.vacuum => _vacuum(database, count, onProgress),
    BenchOp.separateDelete => _each(
      database,
      count,
      benchDeleteOne,
      onProgress,
      readChanges: true,
    ),
    BenchOp.deleteAll => _once(database, benchDeleteAll, count, onProgress),
  };
}

Future<int> _insertAll(
  _PlusSession database,
  int count, {
  required bool transaction,
  required void Function(int done, int total)? onProgress,
}) async {
  if (transaction) await database.execute('BEGIN');
  for (var id = 1; id <= count; id++) {
    await database.execute(benchInsert, benchRow(id));
    if (onProgress != null && (id == count || id % 20 == 0)) {
      onProgress(id, count);
    }
  }
  if (transaction) await database.execute('COMMIT');
  return count;
}

Future<int> _each(
  _PlusSession database,
  int count,
  String sql,
  void Function(int done, int total) onProgress, {
  required bool readChanges,
}) async {
  var hits = 0;
  for (var id = 1; id <= count; id++) {
    final parameter = readChanges || sql == benchPoint ? id : 'n$id';
    if (readChanges) {
      final result = await database.execute(sql, [parameter]);
      hits += result.changes;
    } else {
      final result = await database.query(sql, [parameter]);
      if (result.rows.isNotEmpty) hits += 1;
    }
    if (id == count || id % 20 == 0) onProgress(id, count);
  }
  return hits;
}

Future<int> _once(
  _PlusSession database,
  String sql,
  int count,
  void Function(int done, int total) onProgress,
) async {
  final result = await database.execute(sql);
  onProgress(count, count);
  return result.changes;
}

Future<int> _vacuum(
  _PlusSession database,
  int count,
  void Function(int done, int total) onProgress,
) async {
  await database.execute(benchVacuum);
  onProgress(count, count);
  return 1;
}
