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
    test('Top-K matches pinned native sort semantics encoding=$encoding',
        () async {
      final version =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id()']);
      expect(version.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final db = await openInMemory(encoding: encoding);
      final dir = await Directory.systemTemp.createTemp('top-k-native-');
      try {
        await db.execute(
            'CREATE TABLE t(id INTEGER PRIMARY KEY,k,s TEXT COLLATE NOCASE,b BLOB)');
        await db.execute('INSERT INTO t VALUES ${[
          for (var i = 1; i <= 170; i++)
            "($i,${i % 13 == 0 ? 'NULL' : i % 7 == 0 ? "'${i % 23}'" : (i * 67) % 41},'${[
              'a',
              'A',
              'ب',
              'z'
            ][i % 4]}',X'${(i % 9).toRadixString(16).padLeft(2, '0')}')"
        ].join(',')}');
        final path = '${dir.path}/native.db';
        await File(path).writeAsBytes(db.exportImage());
        final shapes = [
          'SELECT id,k,s FROM t ORDER BY k,id',
          'SELECT id,k,s FROM t ORDER BY k DESC NULLS FIRST,s COLLATE RTRIM,id DESC',
          'SELECT id,k,s FROM t WHERE id%3!=0 ORDER BY s COLLATE NOCASE DESC,k NULLS LAST,id',
          'SELECT id,k,s FROM t ORDER BY b DESC,id',
          'SELECT id,k+0 AS v,s FROM t ORDER BY 2 DESC,1',
          'SELECT DISTINCT k,s FROM t ORDER BY k,s COLLATE BINARY',
          'SELECT k,count(*) AS n FROM t GROUP BY k ORDER BY n DESC,k',
          'SELECT id,row_number() OVER(ORDER BY id) AS n FROM t ORDER BY id DESC',
          'WITH c AS MATERIALIZED(SELECT * FROM t) SELECT id,k FROM c ORDER BY k,id',
          'SELECT a.id,a.k FROM t AS a JOIN t AS b ON a.id=b.id ORDER BY a.k,a.id',
        ];
        for (final shape in shapes) {
          for (final spec in [
            (0, 0),
            (1, 0),
            (31, 0),
            (32, 0),
            (33, 0),
            (64, 5),
            (1, 32),
            (32, -1),
            (999, 0),
            (-1, 3)
          ]) {
            final sql = '$shape LIMIT ${spec.$1} OFFSET ${spec.$2}';
            final oracle = await Process.run(cli, ['-json', path, sql]);
            expect(oracle.exitCode, 0, reason: oracle.stderr.toString());
            final expected = oracle.stdout.toString().trim().isEmpty
                ? []
                : (jsonDecode(oracle.stdout.toString()) as List)
                    .map((r) => (r as Map).values.toList())
                    .toList();
            final actual = (await db.query(sql))
                .rows
                .map((r) => r.map((v) => v is BigInt ? v.toInt() : v).toList())
                .toList();
            expect(actual, expected, reason: sql);
          }
        }
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    });
  }
}
