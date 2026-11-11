@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

String literal(Object? v) {
  if (v == null) return 'NULL';
  if (v is String) return "'${v.replaceAll("'", "''")}'";
  if (v is Uint8List) {
    return "X'${v.map((x) => x.toRadixString(16).padLeft(2, '0')).join()}'";
  }
  return v.toString();
}

String bind(String sql, List<Object?> args) {
  final tokens = SqlTokenizer.tokenize(sql);
  final result = StringBuffer();
  var end = 0, count = 0;
  final names = <String, int>{};
  for (final token in tokens) {
    if (token.kind != SqlTokenKind.parameter) continue;
    final n = token.text.startsWith('?')
        ? token.text.length == 1
            ? count + 1
            : int.parse(token.text.substring(1))
        : names.putIfAbsent(token.text, () => count + 1);
    if (n > count) count = n;
    result.write(sql.substring(end, token.offset));
    result.write(literal(args[n - 1]));
    end = token.offset + token.text.length;
  }
  result.write(sql.substring(end));
  return result.toString();
}

List<Object?> norm(List<Object?> row) =>
    row.map((v) => v is BigInt ? v.toInt() : v).toList();
void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  for (final encoding in [1, 2, 3]) {
    test('prepared binding/update semantics match native encoding=$encoding',
        () async {
      final version =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id()']);
      expect(version.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final dir = await Directory.systemTemp.createTemp('prepared-native-');
      final db = await openInMemory(encoding: encoding);
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER CHECK(n>=0),k TEXT COLLATE NOCASE)');
      await db.execute("INSERT INTO t VALUES(1,10,'A'),(2,20,'ب')");
      final path = '${dir.path}/oracle.db';
      await File(path).writeAsBytes(db.exportImage());
      for (final spec in <({String sql, List<List<Object?>> args})>[
        (
          sql:
              'SELECT id,n FROM t WHERE n>=? AND k IS NOT ? ORDER BY id LIMIT ?',
          args: [
            [0, null, 10],
            [15, 'a', 2],
            [30, 'ب', 1]
          ]
        ),
        (
          sql:
              'SELECT :value AS first,?3 AS third,:value AS again FROM t WHERE id=:id',
          args: [
            ['x', null, 1, 1],
            ['y', null, 2, 2]
          ]
        ),
        (
          sql: 'UPDATE t SET n=? WHERE id=? AND n>=0 RETURNING id,n',
          args: [
            [15, 1],
            [-1, 2],
            [25, 2]
          ]
        ),
      ]) {
        final stmt = await db.prepare(spec.sql);
        for (final values in spec.args) {
          final native = await Process.run(
              cli, ['-json', path, '${bind(spec.sql, values)};']);
          QueryResult? actual;
          try {
            actual = stmt.isReadOnly
                ? await stmt.query(values)
                : (await stmt.execute(values)).returning;
          } on SqlException {
            expect(native.exitCode, isNot(0));
          }
          if (actual != null) {
            expect(native.exitCode, 0, reason: native.stderr.toString());
            final expected = native.stdout.toString().trim().isEmpty
                ? []
                : (jsonDecode(native.stdout.toString()) as List)
                    .map((r) => (r as Map).values.toList())
                    .toList();
            expect(actual.rows.map(norm).toList(), expected);
          }
        }
        await stmt.close();
      }
      final exported = '${dir.path}/export.db';
      await File(exported).writeAsBytes(db.exportImage());
      final check =
          await Process.run(cli, [exported, 'PRAGMA integrity_check']);
      expect(check.exitCode, 0);
      expect(check.stdout.toString().trim(), 'ok');
    });
  }
}
