import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';

Future<void> main(List<String> args) async {
  final count = args.isEmpty ? 1000 : int.parse(args.single);
  final db = await openInMemory();
  SqliteBranch? branch;
  try {
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,price INTEGER NOT NULL,stock INTEGER NOT NULL)');
    await db.execute('BEGIN');
    for (var i = 0; i < count; i++) {
      await db.execute('INSERT INTO products VALUES(?,?,?)', [i, 500, 100]);
    }
    await db.execute('COMMIT');
    final before = db.exportImage();
    final manager = SqlitePlusBranches(database: db, sourceId: 'benchmark');
    final watch = Stopwatch()..start();
    branch = await manager.create(name: 'prices');
    final create = watch.elapsedMicroseconds;
    if (sha256.convert(db.exportImage()) != sha256.convert(before)) {
      throw StateError('Create modified main');
    }
    // Ten rows changed regardless of dataset size; workload setup is excluded.
    final changed = count < 10 ? count : 10;
    await branch.database
        .execute('UPDATE products SET price=550 WHERE id<?', [changed]);
    await db.execute('UPDATE products SET stock=97 WHERE id<?', [changed]);
    watch
      ..reset()
      ..start();
    final diff = await branch.diff();
    final diffTime = watch.elapsedMicroseconds;
    if (diff.length != changed) throw StateError('Diff count');
    watch
      ..reset()
      ..start();
    final preview = await branch.previewMerge();
    final previewTime = watch.elapsedMicroseconds;
    if (preview.conflicts.isNotEmpty) throw StateError('Unexpected conflict');
    watch
      ..reset()
      ..start();
    final archive = await branch.exportArchive();
    final archiveTime = watch.elapsedMicroseconds;
    watch
      ..reset()
      ..start();
    final result = await branch.merge(preview: preview);
    final mergeTime = watch.elapsedMicroseconds;
    if (result.appliedRows != changed) throw StateError('Merge count');
    final rows =
        (await db.query('SELECT id,price,stock FROM products ORDER BY id'))
            .rows;
    for (var i = 0; i < count; i++) {
      if (rows[i][0] != BigInt.from(i) ||
          rows[i][1] != BigInt.from(i < changed ? 550 : 500) ||
          rows[i][2] != BigInt.from(i < changed ? 97 : 100)) {
        throw StateError('Final row');
      }
    }
    final logical =
        rows.map((r) => r.map((v) => v.toString()).toList()).toList();
    final image = db.exportImage();
    print(jsonEncode({
      'rows': count,
      'changed': changed,
      'create_us': create,
      'diff_us': diffTime,
      'preview_us': previewTime,
      'archive_us': archiveTime,
      'merge_us': mergeTime,
      'base_bytes': before.length,
      'archive_bytes': archive.length,
      'merged_bytes': image.length,
      'image_sha256': sha256.convert(image).toString(),
      'logical_sha256':
          sha256.convert(utf8.encode(jsonEncode(logical))).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await branch?.close();
    await db.close();
  }
}
