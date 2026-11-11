import 'dart:convert';
import 'package:sqlite_plus/sqlite_plus.dart';

/// Amplifies the unchanged ordinary hot UPDATE path beyond millisecond samples.
Future<void> main() async {
  final db = await openInMemory();
  try {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,n INTEGER NOT NULL)');
    await db.execute('INSERT INTO items VALUES ${[
      for (var i = 1; i <= 1000; i++) '($i,$i)'
    ].join(',')}');
    db.exportImage();
    await db.execute('BEGIN');
    final clock = Stopwatch()..start();
    for (var pass = 0; pass < 100; pass++) {
      for (var i = 1; i <= 1000; i++) {
        await db.execute('UPDATE items SET n=n+1 WHERE id=?', [i]);
      }
    }
    clock.stop();
    await db.execute('COMMIT');
    final rows = (await db.query('SELECT id,n FROM items ORDER BY id')).rows;
    for (var i = 0; i < 1000; i++) {
      if (rows[i][1] != BigInt.from(i + 101)) throw StateError('Update $i');
    }
    print(jsonEncode({
      'operations': 100000,
      'duration_us': clock.elapsedMicroseconds,
      'checksum': rows
          .fold<BigInt>(BigInt.zero, (a, r) => a + (r[1] as BigInt))
          .toString(),
      'image_bytes': db.exportImage().length
    }));
  } finally {
    await db.close();
  }
}
