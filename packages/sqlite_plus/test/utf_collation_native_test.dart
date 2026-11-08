@TestOn('linux')
library;

import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  for (final encoding in [1, 2, 3]) {
    test(
        'UTF-8 built-in collations keep native index order and NUL lengths encoding=$encoding',
        () async {
      final pin =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
      expect(pin.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final db = await openInMemory(encoding: encoding);
      addTearDown(db.close);
      const schema = 'CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT)';
      const seed =
          "INSERT INTO t VALUES(1,'abc'),(2,'حليب'),(3,'A'),(4,'a'||char(0)||'x'),(5,'a'||char(0)||'y'),(6,'a'||char(0)),(7,'abc '),(8,'𝄞'),(9,'é'),(10,'\uE000')";
      await db.execute(schema);
      await db.execute(seed);
      final prefix =
          "PRAGMA encoding='${encoding == 1 ? 'UTF-8' : encoding == 2 ? 'UTF-16le' : 'UTF-16be'}';$schema;$seed;";
      for (final indexed in [false, true]) {
        for (final collation in ['BINARY', 'NOCASE', 'RTRIM']) {
          if (indexed) {
            await db.execute(
                'CREATE INDEX i_$collation ON t(v COLLATE $collation)');
          }
          for (final sql in [
            'SELECT id FROM t ORDER BY v COLLATE $collation,id',
            "SELECT id FROM t WHERE v=('a'||char(0)||'x') COLLATE $collation ORDER BY id"
          ]) {
            final native = await Process.run(cli, [':memory:', '$prefix$sql;']);
            expect(native.exitCode, 0, reason: native.stderr.toString());
            final expected = native.stdout.toString().trim();
            final actual = (await db.query(sql))
                .rows
                .map((r) => r.single.toString())
                .join('\n');
            expect(actual, expected,
                reason: 'indexed=$indexed collation=$collation');
          }
        }
      }
      final folder = Directory.systemTemp.createTempSync('utf-collation-');
      try {
        final file = File('${folder.path}/db.sqlite');
        await file.writeAsBytes(db.exportImage());
        final check =
            await Process.run(cli, [file.path, 'PRAGMA integrity_check;']);
        expect(check.exitCode, 0);
        expect(check.stdout.toString().trim(), 'ok');
      } finally {
        folder.deleteSync(recursive: true);
      }
    });
  }
}
