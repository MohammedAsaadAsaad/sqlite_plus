@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  for (final encoding in [1, 2, 3]) {
    test('diagnostic execution matches pinned native, encoding=$encoding',
        () async {
      final version =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id()']);
      expect(version.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final source = await openInMemory(encoding: encoding, pageSize: 512);
      final dir = await Directory.systemTemp.createTemp('diagnostic-native-');
      SqliteDatabase? reader;
      try {
        await source.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER,s TEXT COLLATE NOCASE,b BLOB)');
        await source.execute("INSERT INTO t VALUES ${[
          for (var i = 1; i <= 100; i++)
            "($i,${i % 13 == 0 ? 'NULL' : i % 17},'${[
              'a',
              'A',
              'ب',
              'z'
            ][i % 4]}',X'${(i % 9).toRadixString(16).padLeft(2, '0')}')"
        ].join(',')}");
        await source.execute('CREATE INDEX idx_n ON t(n)');
        await source.execute('CREATE INDEX idx_s ON t(s)');
        await source.execute('ANALYZE');
        final image = source.exportImage();
        final path = '${dir.path}/oracle.db';
        await File(path).writeAsBytes(image);
        reader = await SqliteDatabase.openReadOnly(ByteImageStorage(image));
        for (final query in [
          'SELECT id,n,s FROM t WHERE n>=3 ORDER BY n DESC NULLS FIRST,id',
          "SELECT id,n,s FROM t WHERE s='a' ORDER BY s COLLATE RTRIM,id DESC",
          'SELECT id,hex(b) AS blob FROM t WHERE id>=7 ORDER BY b,id',
          'SELECT DISTINCT n,s FROM t ORDER BY n,s COLLATE BINARY',
          'SELECT id,n FROM t NOT INDEXED WHERE n IS NULL ORDER BY id',
          'SELECT id,n FROM t INDEXED BY idx_s WHERE n>=0 ORDER BY n,id',
        ]) {
          for (final limits in [
            (0, 0),
            (1, 0),
            (31, 0),
            (32, 0),
            (33, 3),
            (64, 5),
            (999, 0),
            (-1, 3)
          ]) {
            final sql = '$query LIMIT ${limits.$1} OFFSET ${limits.$2}';
            final native = await Process.run(cli, ['-json', path, sql]);
            expect(native.exitCode, 0, reason: native.stderr.toString());
            final expected = native.stdout.toString().trim().isEmpty
                ? []
                : (jsonDecode(native.stdout.toString()) as List)
                    .map((r) => (r as Map).values.toList())
                    .toList();
            final report = await reader.diagnoseQuery(sql);
            final rows = report.result.rows
                .map((r) => r.map((v) => v is BigInt ? v.toInt() : v).toList())
                .toList();
            expect(rows, expected, reason: sql);
            expect(report.plan.access, reader.explain(sql).access);
            expect(report.result.rows, (await reader.query(sql)).rows);
          }
        }
      } finally {
        await reader?.close();
        await source.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
