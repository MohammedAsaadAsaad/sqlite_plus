import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main() async {
  final mutable = await MutableSqliteDatabase.create(pageSize: 512);
  await mutable
      .execute('CREATE TABLE items(id INTEGER PRIMARY KEY,k INT,payload TEXT)');
  final build = Stopwatch()..start();
  await mutable.execute(
      "INSERT INTO items WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10000) SELECT x,x,'payload-'||x FROM n");
  build.stop();
  await mutable.execute('CREATE INDEX items_k ON items(k)');
  final bytes = mutable.exportImage();
  await mutable.close();
  final storage = MemoryStorageBackend();
  await storage.write(0, bytes);
  final db = await SqliteDatabase.openReadOnly(storage);
  final timings = <String, List<int>>{};
  for (final entry in {
    'secondary_index': 'SELECT id FROM items WHERE k=?',
    'scan': 'SELECT id FROM items WHERE +k=?'
  }.entries) {
    for (var i = 0; i < 3; i++) {
      await db.query(entry.value, [9999]);
    }
    timings[entry.key] = [];
    for (var sample = 0; sample < 5; sample++) {
      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        final result = await db.query(entry.value, [9999]);
        if (result.rows.length != 1 ||
            result.rows.single.single != BigInt.from(9999)) {
          throw StateError('Incorrect benchmark result');
        }
      }
      watch.stop();
      timings[entry.key]!.add(watch.elapsedMicroseconds);
    }
  }
  print(jsonEncode({
    'workload':
        '100 equality queries over a 10000-row memory image; five samples; three warmups per variant',
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
