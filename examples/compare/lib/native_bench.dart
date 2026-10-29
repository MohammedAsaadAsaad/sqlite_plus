import 'dart:io';

import 'package:sqflite/sqflite.dart';

import 'bench_model.dart';

class NativeBenchEngine implements BenchEngine {
  NativeBenchEngine(Directory directory, {this.storage = BenchStorage.file})
    : location = storage == BenchStorage.file
          ? '${directory.path}/bench-native.db'
          : null;

  @override
  String get id => 'native';

  @override
  String get label => 'native';

  @override
  final BenchStorage storage;

  @override
  final String? location;

  @override
  Future<BenchSample> run(
    BenchOp op,
    int count,
    void Function(int done, int total) onProgress,
  ) async {
    requireBenchCount(count);
    final database = await _open();
    try {
      return await _measure(database, op, count, onProgress);
    } finally {
      await database.close();
    }
  }

  Future<Database> _open() async {
    if (storage == BenchStorage.memory) {
      return openDatabase(
        inMemoryDatabasePath,
        version: 1,
        singleInstance: false,
      );
    }
    final path = location;
    if (path == null) {
      throw StateError('File bench needs a path');
    }
    await deleteDatabase(path);
    return openDatabase(path, version: 1);
  }

  Future<BenchSample> _measure(
    Database database,
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
    final storedBytes = await _storedBytes(database);
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
      exportMicros: 0,
      storedBytes: storedBytes,
      storage: storage,
    );
  }

  Future<int> _storedBytes(Database database) async {
    if (storage == BenchStorage.memory) {
      final pages = await database.rawQuery('PRAGMA page_count');
      final size = await database.rawQuery('PRAGMA page_size');
      return benchInt(pages.single.values.single) *
          benchInt(size.single.values.single);
    }
    final path = location;
    if (path == null) return 0;
    var total = 0;
    for (final suffix in const ['', '-wal', '-shm', '-journal']) {
      final file = File('$path$suffix');
      if (await file.exists()) total += await file.length();
    }
    return total;
  }
}

Future<(int, int)> _checksum(Database database) async {
  final rows = await database.rawQuery(benchChecksum);
  final row = rows.single;
  return (benchInt(row.values.first), benchInt(row.values.last));
}

Future<int> _operation(
  Database database,
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
      mutate: true,
    ),
    BenchOp.bulkUpdate => _once(database, benchUpdateAll, count, onProgress),
    BenchOp.search => _each(
      database,
      count,
      benchSearch,
      onProgress,
      mutate: false,
    ),
    BenchOp.point => _each(
      database,
      count,
      benchPoint,
      onProgress,
      mutate: false,
    ),
    BenchOp.vacuum => _vacuum(database, count, onProgress),
    BenchOp.separateDelete => _each(
      database,
      count,
      benchDeleteOne,
      onProgress,
      mutate: true,
    ),
    BenchOp.deleteAll => _once(database, benchDeleteAll, count, onProgress),
  };
}

Future<int> _insertAll(
  DatabaseExecutor database,
  int count, {
  required bool transaction,
  required void Function(int done, int total)? onProgress,
}) async {
  Future<void> body(DatabaseExecutor executor) async {
    for (var id = 1; id <= count; id++) {
      await executor.rawInsert(benchInsert, benchRow(id));
      if (onProgress != null && (id == count || id % 20 == 0)) {
        onProgress(id, count);
      }
    }
  }

  if (transaction && database is Database) {
    await database.transaction(body);
  } else {
    await body(database);
  }
  return count;
}

Future<int> _each(
  Database database,
  int count,
  String sql,
  void Function(int done, int total) onProgress, {
  required bool mutate,
}) async {
  var hits = 0;
  for (var id = 1; id <= count; id++) {
    final parameter = mutate || sql == benchPoint ? id : 'n$id';
    if (mutate) {
      hits += sql.startsWith('DELETE')
          ? await database.rawDelete(sql, [parameter])
          : await database.rawUpdate(sql, [parameter]);
    } else {
      final rows = await database.rawQuery(sql, [parameter]);
      if (rows.isNotEmpty) hits += 1;
    }
    if (id == count || id % 20 == 0) onProgress(id, count);
  }
  return hits;
}

Future<int> _once(
  Database database,
  String sql,
  int count,
  void Function(int done, int total) onProgress,
) async {
  final changes = sql.startsWith('DELETE')
      ? await database.rawDelete(sql)
      : await database.rawUpdate(sql);
  onProgress(count, count);
  return changes;
}

Future<int> _vacuum(
  Database database,
  int count,
  void Function(int done, int total) onProgress,
) async {
  await database.execute(benchVacuum);
  onProgress(count, count);
  return 1;
}
