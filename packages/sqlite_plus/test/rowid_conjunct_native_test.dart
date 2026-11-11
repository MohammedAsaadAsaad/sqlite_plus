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
  var index = 0;
  return sql.replaceAllMapped(RegExp(r'\?'), (_) => literal(args[index++]));
}

List<Object?> normalize(List<Object?> r) =>
    r.map((v) => v is BigInt ? v.toInt() : v).toList();
void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  for (final encoding in [1, 2, 3]) {
    test(
        'rowid AND predicates/identity key preservation match native encoding=$encoding',
        () async {
      final version =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id()']);
      expect(version.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      final dir = await Directory.systemTemp.createTemp('rowid-and-');
      final db = await openInMemory(encoding: encoding);
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY,state TEXT,token TEXT COLLATE NOCASE,n INTEGER CHECK(n>=0))');
      await db.execute('CREATE UNIQUE INDEX ix ON t(n,id)');
      await db.execute('CREATE INDEX expr ON t(lower(token)) WHERE n>0');
      await db.execute(
          "INSERT INTO t VALUES(-2,'running','neg',0),(1,'running','a',1),(2,'running','B',2),(3,'queued',NULL,3),(9223372036854775807,'running','last',4)");
      final nativePath = '${dir.path}/native.db';
      await File(nativePath).writeAsBytes(db.exportImage());
      final operations = <({String sql, List<Object?> args})>[
        (
          sql:
              "UPDATE t SET n=n+1 WHERE id=? AND state='running' AND token=? RETURNING id,n",
          args: [2, 'b']
        ),
        (
          sql:
              "UPDATE t SET n=n+1 WHERE id=? AND state='running' AND token=? RETURNING id,n",
          args: [2, 'stale']
        ),
        (
          sql: 'UPDATE t AS x SET n=n+1 WHERE ?=x.id AND n>=0 RETURNING id,n',
          args: [-2]
        ),
        (
          sql: 'UPDATE t SET n=n+1 WHERE id=? AND n>=0 RETURNING id,n',
          args: ['2']
        ),
        (
          sql: 'UPDATE t SET n=n+1 WHERE id=? AND n>=0 RETURNING id,n',
          args: [2.0]
        ),
        (
          sql: 'UPDATE t SET n=n+1 WHERE id=? AND n>=0 RETURNING id,n',
          args: [2.5]
        ),
        (
          sql: 'UPDATE t SET n=n+1 WHERE id=? AND n>=0 RETURNING id,n',
          args: [null]
        ),
        (
          sql: 'UPDATE t SET n=n+1 WHERE id=? AND n>=0 RETURNING id,n',
          args: [
            Uint8List.fromList([50])
          ]
        ),
        (
          sql: 'UPDATE t SET n=n+1 WHERE id=? AND n>=0 RETURNING id,n',
          args: [BigInt.parse('9223372036854775807')]
        ),
        (
          sql:
              "UPDATE t SET n=n+1 WHERE id=? AND (state='queued' OR token='b') RETURNING id,n",
          args: [3]
        ),
        (sql: 'UPDATE t SET n=n+1 WHERE id=1 OR id=2 RETURNING id,n', args: []),
        (
          sql:
              "UPDATE t SET n=(SELECT max(n) FROM t) WHERE id=? AND state='running' RETURNING id,n",
          args: [2]
        ),
        (
          sql:
              'UPDATE t SET n=n+1 WHERE id=? AND n<(SELECT max(n) FROM t) RETURNING id,n',
          args: [1]
        ),
        (
          sql: 'UPDATE t SET n=-1 WHERE id=? AND n>=0 RETURNING id,n',
          args: [2]
        ),
        (
          sql: 'UPDATE t SET id=1 WHERE id=? AND n>=0 RETURNING id,n',
          args: [2]
        ),
        (
          sql: 'DELETE FROM t WHERE id=? AND token=? RETURNING id,n',
          args: [2, 'wrong']
        ),
        (
          sql: 'DELETE FROM t WHERE id=? AND token=? RETURNING id,n',
          args: [2, 'b']
        ),
      ];
      for (final op in operations) {
        final native = await Process.run(cli, [
          '-json',
          nativePath,
          '${bind(op.sql, op.args)}; SELECT changes() AS changed;'
        ]);
        MutationResult? result;
        try {
          result = await db.execute(op.sql, op.args);
        } on SqlException {
          expect(native.exitCode, isNot(0), reason: op.sql);
        }
        if (result != null) {
          expect(native.exitCode, 0, reason: native.stderr.toString());
          final docs = native.stdout
              .toString()
              .trim()
              .split(RegExp(r'\n(?=\[)'))
              .map(jsonDecode)
              .toList();
          expect(result.changes, (docs.last as List).single['changed']);
          final returned = docs.length == 1
              ? []
              : (docs.first as List)
                  .map((r) => (r as Map).values.toList())
                  .toList();
          expect(result.returning!.rows.map(normalize).toList(), returned,
              reason: op.sql);
        }
        final state = await Process.run(cli, [
          '-json',
          nativePath,
          'SELECT id,state,token,n FROM t ORDER BY id'
        ]);
        expect(
            (await db.query('SELECT id,state,token,n FROM t ORDER BY id'))
                .rows
                .map(normalize)
                .toList(),
            (jsonDecode(state.stdout.toString()) as List)
                .map((r) => (r as Map).values.toList())
                .toList());
        final path = '${dir.path}/export.db';
        await File(path).writeAsBytes(db.exportImage());
        final integrity =
            await Process.run(cli, [path, 'PRAGMA integrity_check']);
        expect(integrity.exitCode, 0, reason: integrity.stderr.toString());
        expect(integrity.stdout.toString().trim(), 'ok');
      }
    });
  }
}
