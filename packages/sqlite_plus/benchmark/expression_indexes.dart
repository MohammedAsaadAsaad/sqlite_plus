import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main() async {
  final mutable = await MutableSqliteDatabase.create(pageSize: 512);
  await mutable.execute(
      'CREATE TABLE items(id INTEGER PRIMARY KEY,k INT,payload TEXT,active INT)');
  final build = Stopwatch()..start();
  await mutable.execute(
      "INSERT INTO items WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT x,-x,'Item-'||x,x%2 FROM n");
  build.stop();
  await mutable.execute(
      'CREATE INDEX lower_key ON items(lower(payload)) WHERE active=1');
  await mutable.execute('CREATE INDEX magnitude ON items(abs(k)) WHERE k<0');
  final bytes = mutable.exportImage();
  await mutable.close();
  final storage = MemoryStorageBackend();
  await storage.write(0, bytes);
  final db = await SqliteDatabase.openReadOnly(storage);
  final timings = <String, List<int>>{};
  for (final entry in <String, (String, List<Object?>, int)>{
    'partial_expression': (
      "SELECT id FROM items WHERE lower(payload)=? AND active=1",
      ['item-9999'],
      1
    ),
    'expression_scan': (
      "SELECT id FROM items WHERE +lower(payload)=? AND active=1",
      ['item-9999'],
      1
    ),
    'expression_range': (
      'SELECT id FROM items WHERE abs(k)>=? AND abs(k)<10000 AND k<0',
      [9990],
      10
    ),
    'range_scan': (
      'SELECT id FROM items WHERE +abs(k)>=? AND +abs(k)<10000 AND k<0',
      [9990],
      10
    ),
  }.entries) {
    for (var i = 0; i < 3; i++) {
      await db.query(entry.value.$1, entry.value.$2);
    }
    timings[entry.key] = [];
    for (var sample = 0; sample < 5; sample++) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < 30; i++) {
        final result = await db.query(entry.value.$1, entry.value.$2);
        if (result.rows.length != entry.value.$3 ||
            result.rows.any((row) =>
                (row.single as BigInt) <
                BigInt.from(entry.value.$3 == 1 ? 9999 : 9990))) {
          throw StateError('Incorrect benchmark result');
        }
      }
      watch.stop();
      timings[entry.key]!.add(watch.elapsedMicroseconds);
    }
  }
  print(jsonEncode({
    'workload':
        '30 expression/partial-index equality and expression-range queries over a 10000-row memory image; five samples; three warmups per variant',
    'sdk': Platform.version,
    'os': Platform.operatingSystem,
    'runtime': 'AOT executable',
    'rows': 10000,
    'database_bytes': bytes.length,
    'bulk_insert_microseconds': build.elapsedMicroseconds,
    'query_microseconds': timings,
    'peak_process_rss_bytes': ProcessInfo.maxRss,
    'limitations':
        'One Linux x64 in-memory workload. Whole-process RSS. No cross-platform or M9 scale-matrix claim.'
  }));
  await db.close();
}
