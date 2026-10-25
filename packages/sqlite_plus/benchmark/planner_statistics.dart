import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';

final class _CountingStorage implements StorageBackend {
  _CountingStorage(this.inner);
  final StorageBackend inner;
  var reads = 0;
  @override
  Future<int> read(int offset, Uint8List target) {
    reads++;
    return inner.read(offset, target);
  }

  @override
  Future<void> write(int offset, Uint8List bytes) => inner.write(offset, bytes);
  @override
  Future<void> truncate(int length) => inner.truncate(length);
  @override
  Future<int> length() => inner.length();
  @override
  Future<void> sync() => inner.sync();
  @override
  Future<void> close() => inner.close();
}

Future<void> main() async {
  final db = await MutableSqliteDatabase.create(pageSize: 512);
  await db.execute(
      'CREATE TABLE items(id INTEGER PRIMARY KEY,a INT,b INT,c INT,payload TEXT)');
  await db.execute('INSERT INTO items WITH RECURSIVE n(x) AS('
      'VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<10000) '
      "SELECT x,x%2,x,x%5,'payload-'||x FROM n");
  await db.execute('CREATE INDEX broad ON items(a,c)');
  await db.execute('CREATE INDEX selective ON items(b)');
  final before = db.exportImage();
  final analyzeWatch = Stopwatch()..start();
  await db.execute('ANALYZE');
  analyzeWatch.stop();
  final after = db.exportImage();
  await db.close();
  const sql = 'SELECT payload FROM items WHERE a=1 AND c=4 AND b=9999';
  final timings = <String, List<int>>{};
  final plans = <String, String?>{};
  final reads = <String, List<int>>{};
  final opens = <String, int>{};
  for (final variant
      in {'before_analyze': before, 'after_analyze': after}.entries) {
    final storage = _CountingStorage(MemoryStorageBackend());
    await storage.write(0, variant.value);
    final watch = Stopwatch()..start();
    final reader = await SqliteDatabase.openReadOnly(storage);
    watch.stop();
    opens[variant.key] = watch.elapsedMicroseconds;
    plans[variant.key] = reader.explain(sql).indexName;
    for (var i = 0; i < 3; i++) {
      await reader.query(sql);
    }
    timings[variant.key] = [];
    reads[variant.key] = [];
    for (var sample = 0; sample < 5; sample++) {
      storage.reads = 0;
      final watch = Stopwatch()..start();
      for (var iteration = 0; iteration < 30; iteration++) {
        final result = await reader.query(sql);
        if (result.rows.length != 1 ||
            result.rows.single.single != 'payload-9999') {
          throw StateError('Incorrect benchmark result');
        }
      }
      watch.stop();
      timings[variant.key]!.add(watch.elapsedMicroseconds);
      reads[variant.key]!.add(storage.reads);
    }
    await reader.close();
  }
  if (plans['before_analyze'] != 'broad' ||
      plans['after_analyze'] != 'selective') {
    throw StateError('Unexpected benchmark plans: $plans');
  }
  print(jsonEncode({
    'workload':
        '30 equality queries over 10000-row memory images; five samples; three warmups per variant',
    'sdk': Platform.version,
    'os': Platform.operatingSystem,
    'runtime': 'AOT executable',
    'rows': 10000,
    'database_bytes_before': before.length,
    'database_bytes_after': after.length,
    'analyze_microseconds': analyzeWatch.elapsedMicroseconds,
    'open_microseconds': opens,
    'selected_indexes': plans,
    'query_microseconds': timings,
    'storage_read_calls': reads,
    'peak_process_rss_bytes': ProcessInfo.maxRss,
    'limitations':
        'One Linux x64 in-memory selectivity workload; whole-process RSS and warm caches. No native-engine or M9 scale/platform matrix claim.'
  }));
}
