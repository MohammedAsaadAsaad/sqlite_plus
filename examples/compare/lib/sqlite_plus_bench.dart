import 'dart:isolate';

import 'package:sqlite_plus/sqlite_plus.dart';

import 'bench_model.dart';

class SqlitePlusBenchEngine implements BenchEngine {
  @override
  String get id => 'sqlite_plus';

  @override
  String get label => 'sqlite_plus';

  @override
  String? get location => null;

  @override
  Future<BenchSample> run(
    BenchOp op,
    int count,
    void Function(int done, int total) onProgress,
  ) async {
    requireBenchCount(count);
    final database = await MutableSqliteDatabase.create();
    try {
      return await _measure(database, op, count, onProgress);
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

  Future<BenchSample> _measure(
    MutableSqliteDatabase database,
    BenchOp op,
    int count,
    void Function(int done, int total) onProgress,
  ) async {
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
    final after = ProcessSample.now();
    final totals = await _checksum(database);
    final exported = Stopwatch()..start();
    final storedBytes = database.exportImage().length;
    exported.stop();
    return BenchSample(
      engineId: id,
      engineLabel: label,
      op: op,
      count: count,
      elapsedMicros: measured.elapsedMicroseconds,
      cpuMicros: after.cpuMicrosSince(before),
      rssBefore: before.rssBytes,
      rssAfter: after.rssBytes,
      rows: totals.$1,
      checksum: totals.$2,
      hits: hits,
      prepareMicros: prepare.elapsedMicroseconds,
      exportMicros: exported.elapsedMicroseconds,
      storedBytes: storedBytes,
    );
  }
}

Future<void> sqlitePlusBenchEntry(Map<String, Object?> message) async {
  final send = message['send']! as SendPort;
  try {
    final sample = await SqlitePlusBenchEngine().run(
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

Future<(int, int)> _checksum(MutableSqliteDatabase database) async {
  final result = await database.query(benchChecksum);
  final row = result.rows.single;
  return (benchInt(row[0]), benchInt(row[1]));
}

Future<int> _operation(
  MutableSqliteDatabase database,
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
  MutableSqliteDatabase database,
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
  MutableSqliteDatabase database,
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
  MutableSqliteDatabase database,
  String sql,
  int count,
  void Function(int done, int total) onProgress,
) async {
  final result = await database.execute(sql);
  onProgress(count, count);
  return result.changes;
}

Future<int> _vacuum(
  MutableSqliteDatabase database,
  int count,
  void Function(int done, int total) onProgress,
) async {
  await database.execute(benchVacuum);
  onProgress(count, count);
  return 1;
}
