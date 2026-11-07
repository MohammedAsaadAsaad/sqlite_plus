@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/src/btree/rowid_page_patch.dart';
import 'package:test/test.dart';

const _cli = '/tmp/sqlite-build/sqlite3';
void main() {
  setUpAll(() async {
    final pin =
        await Process.run(_cli, [':memory:', 'SELECT sqlite_source_id()']);
    expect(pin.exitCode, 0);
    expect(pin.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
  });
  for (final encoding in [1, 2, 3]) {
    test(
        'multi-page and overflow catalog roots match native encoding $encoding',
        () async {
      final db = await openInMemory(pageSize: 512, encoding: encoding);
      addTearDown(db.close);
      for (var i = 0; i < 12; i++) {
        await db.execute('CREATE TABLE t$i(id INTEGER PRIMARY KEY,n INTEGER)');
        await db.execute('CREATE INDEX index_$i ON t$i(n)');
        await db.execute('INSERT INTO t$i VALUES(1,1),(2,2)');
      }
      final longColumn = List.filled(1200, 'x').join();
      await db.execute(
          'CREATE TABLE overflow_schema(id INTEGER PRIMARY KEY,"$longColumn" TEXT)');
      var image = db.exportImage();
      expect(image[100], 5);
      final dir = await Directory.systemTemp.createTemp('schema-roots-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/db.sqlite');
      await file.writeAsBytes(image);
      final native = await Process.run(_cli, [
        '-json',
        file.path,
        "SELECT name,rootpage FROM sqlite_schema WHERE rootpage>0"
      ]);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final expected = {
        for (final row in jsonDecode(native.stdout.toString()) as List)
          row['name']: row['rootpage']
      };
      expect(RowidPagePatch.schemaRoots(image), expected);
      await db.execute('BEGIN');
      await db.execute('SAVEPOINT s');
      await db.execute('DELETE FROM t0 WHERE id=1');
      await db.execute('CREATE TABLE extra(id INTEGER PRIMARY KEY,n)');
      await db.execute('ROLLBACK TO s');
      await db.execute('RELEASE s');
      await db.execute('COMMIT');
      await db.execute('VACUUM');
      await db.execute('UPDATE t11 SET n=99 WHERE id=2');
      await db.execute('INSERT INTO t0 VALUES(3,3)');
      expect((await db.query('SELECT n FROM t11 WHERE id=2')).rows, [
        [BigInt.from(99)]
      ]);
      image = db.exportImage();
      await file.writeAsBytes(image);
      final check = await Process.run(_cli, [
        file.path,
        'PRAGMA integrity_check; SELECT n FROM t11 WHERE id=2; SELECT count(*) FROM t0;'
      ]);
      expect(check.exitCode, 0, reason: check.stderr.toString());
      expect(check.stdout.toString().trim(), 'ok\n99\n3');
      final roots = RowidPagePatch.schemaRoots(image)!;
      expect(RowidPagePatch.clearRoot(image, roots['overflow_schema']!), null);
    });
  }
  test(
      'catalog traversal rejects cycles, out-of-range children and truncated images',
      () async {
    final db = await openInMemory(pageSize: 512);
    addTearDown(db.close);
    for (var i = 0; i < 20; i++) {
      await db.execute('CREATE TABLE table_$i(id INTEGER PRIMARY KEY,n TEXT)');
    }
    final original = db.exportImage();
    expect(original[100], 5);
    for (final child in [1, original.length ~/ 512 + 1]) {
      final corrupt = Uint8List.fromList(original);
      ByteData.sublistView(corrupt).setUint32(108, child);
      final before = Uint8List.fromList(corrupt);
      expect(RowidPagePatch.schemaRoots(corrupt), null);
      expect(corrupt, before);
    }
    expect(
        RowidPagePatch.schemaRoots(
            Uint8List.sublistView(original, 0, original.length - 1)),
        null);
  });
}
