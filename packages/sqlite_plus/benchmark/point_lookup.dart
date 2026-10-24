import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main() async {
  final storage = MemoryStorageBackend();
  await storage.write(0, File('test/fixtures/write.db').readAsBytesSync());
  final db = await SqliteDatabase.openReadOnly(storage);
  const iterations = 100;
  const samples = 5;
  final queries = {
    'rowid_lookup': 'SELECT id FROM notes WHERE id=?',
    'equivalent_scan': 'SELECT id FROM notes WHERE +id=?',
  };
  final timings = <String, List<int>>{};
  try {
    for (final entry in queries.entries) {
      for (var warmup = 0; warmup < 3; warmup++) {
        await db.query(entry.value, [1999]);
      }
      final elapsed = <int>[];
      for (var sample = 0; sample < samples; sample++) {
        final watch = Stopwatch()..start();
        for (var i = 0; i < iterations; i++) {
          final result = await db.query(entry.value, [1999]);
          if (result.rows.length != 1 ||
              result.rows.single.single != BigInt.from(1999)) {
            throw StateError('Benchmark query differs');
          }
        }
        watch.stop();
        elapsed.add(watch.elapsedMicroseconds);
      }
      timings[entry.key] = elapsed;
    }
    print(jsonEncode({
      'workload':
          '100 repeated point SELECTs over the same 2000-row memory-backed fixture; five samples; three warmups per variant',
      'fixture_sha256':
          File('test/fixtures/write.sha256').readAsStringSync().trim(),
      'sdk': Platform.version,
      'os': Platform.operatingSystem,
      'runtime': 'AOT executable',
      'iterations_per_sample': iterations,
      'microseconds': timings,
      'peak_process_rss_bytes': ProcessInfo.maxRss,
      'limitations':
          'One small memory-backed workload. Includes parsing/materialization. RSS is whole process. No M9 scale/platform or native SQL benchmark claim.',
    }));
  } finally {
    await db.close();
  }
}
