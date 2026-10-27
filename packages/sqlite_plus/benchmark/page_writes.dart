import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

/// Samples for this revision only. There is no pre-change AOT binary, so the
/// numbers are not a before/after delta.
Future<void> main() async {
  final batch10000 = await _batch(10000, samples: 3);
  final batch100000 = await _batch(100000, samples: 1);
  final single200 = await _singleRows(200);
  final payload = {
    'workload':
        'This revision only: one batch INSERT of 10000 rows (three fresh databases) and one batch INSERT of 100000 rows (one fresh database) into a rowid table, plus 200 single-row inserts. No pre-change binary was measured, so this file is not a before/after delta.',
    'sdk': Platform.version,
    'os': Platform.operatingSystem,
    'runtime': 'AOT executable',
    'microseconds': {
      'batch_insert_10000': batch10000.insert,
      'count_after_10000': batch10000.count,
      'batch_insert_100000': batch100000.insert,
      'count_after_100000': batch100000.count,
      'single_row_inserts_200': single200,
    },
    'peak_process_rss_bytes': ProcessInfo.maxRss,
    'limitations':
        'One Linux x64 AOT process. Each sample includes parsing and the image write. RSS is the whole process. 100000 single-row inserts were not run because each insert rewrites the tree. No earlier sample exists, so no speedup is claimed. This is not an M9 scale, platform, or native-SQLite comparison.',
  };
  stdout.writeln(jsonEncode(payload));
}

final class _Batch {
  _Batch(this.insert, this.count);
  final List<int> insert;
  final List<int> count;
}

Future<_Batch> _batch(int rows, {required int samples}) async {
  final values = List.filled(rows, "('x')").join(',');
  final sql = 'INSERT INTO t(v) VALUES $values';
  if (sql.length > 1000000) {
    throw StateError('INSERT exceeds the 1 MiB SQL limit');
  }
  final inserts = <int>[];
  final counts = <int>[];
  for (var sample = 0; sample < samples; sample++) {
    final db = await MutableSqliteDatabase.create();
    try {
      await db.execute('CREATE TABLE t(v TEXT)');
      final insert = Stopwatch()..start();
      await db.execute(sql);
      insert.stop();
      final count = Stopwatch()..start();
      final result = await db.query('SELECT count(*) FROM t');
      count.stop();
      if (result.rows.single.single != BigInt.from(rows)) {
        throw StateError('row count differs');
      }
      inserts.add(insert.elapsedMicroseconds);
      counts.add(count.elapsedMicroseconds);
    } finally {
      await db.close();
    }
  }
  return _Batch(inserts, counts);
}

Future<int> _singleRows(int rows) async {
  final db = await MutableSqliteDatabase.create();
  try {
    await db.execute('CREATE TABLE t(v TEXT)');
    final watch = Stopwatch()..start();
    for (var i = 0; i < rows; i++) {
      await db.execute("INSERT INTO t(v) VALUES ('x')");
    }
    watch.stop();
    final result = await db.query('SELECT count(*) FROM t');
    if (result.rows.single.single != BigInt.from(rows)) {
      throw StateError('row count differs');
    }
    return watch.elapsedMicroseconds;
  } finally {
    await db.close();
  }
}
