import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main(List<String> args) async {
  final mode = args[0], count = int.parse(args[1]);
  if (!['read', 'insert', 'update', 'guarded'].contains(mode)) {
    throw ArgumentError('mode');
  }
  final db = await openInMemory();
  try {
    await db.execute(
        'CREATE TABLE items(id INTEGER PRIMARY KEY,n INTEGER NOT NULL)');
    if (mode != 'insert') {
      await db.execute('INSERT INTO items VALUES ${[
        for (var i = 1; i <= count; i++) '($i,$i)'
      ].join(',')}');
    }
    db.exportImage();
    final clock = Stopwatch()..start();
    if (mode == 'read') {
      for (var i = 0; i < 10000; i++) {
        final key = i % count + 1;
        if ((await db.query('SELECT n FROM items WHERE id=?', [key]))
                .rows
                .single
                .single !=
            BigInt.from(key)) {
          throw StateError('Read');
        }
      }
    } else {
      await db.execute('BEGIN');
      for (var i = 1; i <= count; i++) {
        if (mode == 'insert') {
          await db.execute('INSERT INTO items(id,n) VALUES(?,?)', [i, i]);
        } else {
          if (mode == 'guarded') {
            await db
                .execute('UPDATE items SET n=n+1 WHERE id=? AND n=?', [i, i]);
          } else {
            await db.execute('UPDATE items SET n=n+1 WHERE id=?', [i]);
          }
        }
      }
      await db.execute('COMMIT');
    }
    clock.stop();
    final rows = (await db.query('SELECT id,n FROM items ORDER BY id')).rows;
    for (var i = 0; i < count; i++) {
      if (rows[i][0] != BigInt.from(i + 1) ||
          rows[i][1] !=
              BigInt.from(
                  i + 1 + (mode == 'update' || mode == 'guarded' ? 1 : 0))) {
        throw StateError('Final rows');
      }
    }
    final image = db.exportImage();
    final logical = jsonEncode(
        rows.map((r) => r.map((v) => v.toString()).toList()).toList());
    print(jsonEncode({
      'mode': mode,
      'rows': count,
      'operations': mode == 'read' ? 10000 : count,
      'duration_us': clock.elapsedMicroseconds,
      'image_bytes': image.length,
      'logical_sha256': sha256.convert(utf8.encode(logical)).toString(),
      'image_sha256': sha256.convert(image).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await db.close();
  }
}
