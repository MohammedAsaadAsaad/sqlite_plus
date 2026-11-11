import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

/// Exactly 1,000 distinct bindings to the same SQL, with per-call timing.
Future<void> main(List<String> args) async {
  final variant = args.single;
  if (variant != 'ordinary' && variant != 'prepared') {
    throw ArgumentError('Use ordinary or prepared');
  }
  final db = await openInMemory();
  const sql = 'SELECT id,name,price FROM products WHERE id=? AND price>=0';
  try {
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT,price INTEGER)');
    await db.execute('INSERT INTO products VALUES ${[
      for (var i = 1; i <= 1000; i++) "($i,'Product $i',${i * 10})"
    ].join(',')}');
    // Both variants start with the same materialized database image.
    db.exportImage();
    final preparation = Stopwatch()..start();
    final statement = variant == 'prepared' ? await db.prepare(sql) : null;
    preparation.stop();
    final samples = <int>[];
    var checksum = BigInt.zero;
    final loop = Stopwatch()..start();
    for (var id = 1; id <= 1000; id++) {
      final call = Stopwatch()..start();
      final result = statement == null
          ? await db.query(sql, [id])
          : await statement.query([id]);
      call.stop();
      samples.add(call.elapsedMicroseconds);
      final row = result.rows.single;
      if (row[0] != BigInt.from(id) ||
          row[1] != 'Product $id' ||
          row[2] != BigInt.from(id * 10)) {
        throw StateError('Incorrect result for binding $id');
      }
      checksum += row[2] as BigInt;
    }
    loop.stop();
    final execution = samples.fold<int>(0, (a, b) => a + b);
    print(jsonEncode({
      'variant': variant,
      'sql': sql,
      'operations': 1000,
      'bindings': '1..1000, each once',
      'execution_us': execution,
      'average_us': execution / 1000,
      'loop_us': loop.elapsedMicroseconds,
      'preparation_us': statement == null ? 0 : preparation.elapsedMicroseconds,
      'select_parse_count': statement?.selectParseCount,
      'checksum': checksum.toString(),
      'image_bytes': db.exportImage().length,
      'per_execution_us': samples,
      'dart': Platform.version,
    }));
    await statement?.close();
  } finally {
    await db.close();
  }
}
