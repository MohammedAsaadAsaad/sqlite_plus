@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

List<Object?> normalized(List<Object?> row) =>
    row.map((v) => v is BigInt ? v.toInt() : v).toList();
List<dynamic> documents(String output) => output.trim().isEmpty
    ? []
    : output.trim().split(RegExp(r'\n(?=\[)')).map(jsonDecode).toList();
void main() {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  const scenarios = <({String schema, List<String> statements, String select})>[
    (
      schema:
          "CREATE TABLE t(id INTEGER PRIMARY KEY,sku TEXT COLLATE NOCASE UNIQUE,other TEXT UNIQUE,n INTEGER CHECK(n>=0)); INSERT INTO t VALUES(1,'a','x',1),(2,'b','y',2)",
      statements: [
        "INSERT INTO t VALUES(1,'A','unused',10),(3,'c','z',30),(3,'C','unused',31),(2,'B','unused',20) ON CONFLICT(sku) DO UPDATE SET n=excluded.n RETURNING id,sku,other,n",
        "INSERT INTO t VALUES(1,'a','unused',11) ON CONFLICT(id) DO UPDATE SET n=excluded.n WHERE excluded.n>n RETURNING id,n",
        "INSERT INTO t VALUES(1,'a','unused',1) ON CONFLICT(id) DO UPDATE SET n=excluded.n WHERE excluded.n>n RETURNING id,n",
        "INSERT INTO t VALUES(4,'c','q',40) ON CONFLICT(sku) DO NOTHING",
        "INSERT INTO t VALUES(5,'e','y',50) ON CONFLICT(sku) DO UPDATE SET n=excluded.n",
        "INSERT INTO t VALUES(1,'a','x',12),(4,'a2','q',40) ON CONFLICT(id) DO UPDATE SET sku=sku||'2',n=excluded.n",
        "INSERT INTO t VALUES(1,'a','x',12),(4,'a','q',40) ON CONFLICT(id) DO UPDATE SET sku=sku||'2',n=excluded.n RETURNING id,sku,n",
        "INSERT INTO t VALUES(6,NULL,NULL,60),(7,NULL,NULL,70) ON CONFLICT(sku) DO UPDATE SET n=excluded.n RETURNING id,n",
        "INSERT INTO t VALUES(20,'new','y',99) ON CONFLICT DO UPDATE SET n=excluded.n RETURNING id,n"
      ],
      select: 'SELECT id,sku,other,n FROM t ORDER BY id'
    ),
    (
      schema:
          "CREATE TABLE t(id INTEGER PRIMARY KEY,k TEXT COLLATE NOCASE UNIQUE,n INTEGER); INSERT INTO t VALUES(1,'a'||char(0)||'x',1),(2,'a'||char(0)||'zz',2)",
      statements: [
        "INSERT INTO t VALUES(3,'A'||char(0)||'y',3),(4,'A'||char(0)||'qq',4) ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING id,n",
        "INSERT INTO t VALUES(1,'A'||char(0)||'w',5) ON CONFLICT(id) DO UPDATE SET k=excluded.k,n=excluded.n RETURNING id,n",
        "INSERT INTO t VALUES(5,'a'||char(0)||'x',6) ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING id,n",
        "INSERT INTO t VALUES(99,'a'||char(0)||'v',99) ON CONFLICT(id) DO UPDATE SET n=excluded.n"
      ],
      select: 'SELECT id,hex(k),n FROM t ORDER BY id'
    ),
    (
      schema:
          "CREATE TABLE t(id INTEGER PRIMARY KEY,a TEXT COLLATE RTRIM,b BLOB,n INTEGER,UNIQUE(a,b)); INSERT INTO t VALUES(1,'x',X'00',1),(2,'y',X'01',2)",
      statements: [
        "INSERT INTO t VALUES(3,'x ',X'00',3),(4,'z',X'01',4),(5,'z ',X'01',5) ON CONFLICT(a,b) DO UPDATE SET n=excluded.n RETURNING id,n"
      ],
      select: 'SELECT id,a,hex(b),n FROM t ORDER BY id'
    ),
    (
      schema:
          "CREATE TABLE t(id INTEGER PRIMARY KEY,k TEXT,n INTEGER); CREATE UNIQUE INDEX expr ON t(lower(k)) WHERE n>0; INSERT INTO t VALUES(1,'a',1)",
      statements: [
        "INSERT INTO t VALUES(2,'A',2),(3,'b',3) ON CONFLICT(lower(k)) WHERE n>0 DO UPDATE SET n=excluded.n RETURNING id,n"
      ],
      select: 'SELECT id,k,n FROM t ORDER BY id'
    ),
    (
      schema:
          "CREATE TABLE t(id INTEGER PRIMARY KEY,k TEXT UNIQUE,n INTEGER); CREATE TABLE audit(x INTEGER); CREATE TRIGGER log AFTER UPDATE ON t BEGIN INSERT INTO audit VALUES(new.n); END; INSERT INTO t VALUES(1,'a',1)",
      statements: [
        "INSERT INTO t VALUES(2,'a',2),(3,'b',3),(4,'a',4) ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING id,n"
      ],
      select: 'SELECT id,k,n FROM t ORDER BY id'
    ),
    (
      schema:
          "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,k TEXT UNIQUE,n INTEGER); INSERT INTO t(k,n) VALUES('a',1)",
      statements: [
        "INSERT INTO t(k,n) VALUES('a',2),('b',3),('a',4),('c',5) ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING id,k,n"
      ],
      select: 'SELECT id,k,n FROM t ORDER BY id'
    ),
  ];
  for (final encoding in [1, 2, 3]) {
    test(
        'resident UPSERT paths match native data/counters/returning/rollback encoding=$encoding',
        () async {
      final pin =
          await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
      expect(pin.stdout.toString().trim(),
          '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
      for (var i = 0; i < scenarios.length; i++) {
        final scenario = scenarios[i];
        final dir = await Directory.systemTemp.createTemp('upsert_resident_');
        final path = '${dir.path}/native.db';
        final db = await openInMemory(encoding: encoding);
        await db.execute('PRAGMA foreign_keys=ON');
        try {
          final encodingName = encoding == 1
              ? 'UTF-8'
              : encoding == 2
                  ? 'UTF-16le'
                  : 'UTF-16be';
          final setup = await Process.run(cli,
              [path, "PRAGMA encoding='$encodingName'; ${scenario.schema};"]);
          expect(setup.exitCode, 0, reason: setup.stderr.toString());
          // Execute schema statements individually (the engine is one-statement API).
          // Trigger bodies are retained as one CREATE statement below.
          if (i == 4) {
            await db.execute(
                'CREATE TABLE t(id INTEGER PRIMARY KEY,k TEXT UNIQUE,n INTEGER)');
            await db.execute('CREATE TABLE audit(x INTEGER)');
            await db.execute(
                'CREATE TRIGGER log AFTER UPDATE ON t BEGIN INSERT INTO audit VALUES(new.n); END');
            await db.execute("INSERT INTO t VALUES(1,'a',1)");
          } else {
            for (final sql in scenario.schema.split(';')) {
              if (sql.trim().isNotEmpty) await db.execute(sql.trim());
            }
          }
          for (final sql in scenario.statements) {
            final native = await Process.run(cli, [
              '-json',
              path,
              '$sql; SELECT changes() AS changes; SELECT last_insert_rowid() AS last;'
            ]);
            MutationResult? actual;
            Object? error;
            final before = db.exportImage();
            try {
              actual = await db.execute(sql.trim());
            } catch (e) {
              error = e;
            }
            if (native.exitCode != 0) {
              expect(error, isA<SqlException>(), reason: '$i $sql');
              expect(db.exportImage(), before);
            } else {
              expect(error, isNull, reason: '$i $sql');
              final docs = documents(native.stdout.toString());
              final returning = sql.contains('RETURNING');
              final counterIndex = docs.length - 2;
              if (returning) {
                final expected =
                    counterIndex == 0 ? <dynamic>[] : docs.first as List;
                expect(actual!.returning!.rows.map(normalized).toList(),
                    expected.map((r) => (r as Map).values.toList()).toList(),
                    reason: sql);
              }
              expect(actual!.changes,
                  (docs[counterIndex] as List).single['changes'],
                  reason: sql);
              // CLI opens a new connection per call, so only compare last ID when
              // this statement actually inserted a row (nonzero CLI counter).
              final last = (docs.last as List).single['last'];
              if (last != 0) {
                expect(
                    (await db.query('SELECT last_insert_rowid()'))
                        .rows
                        .single
                        .single,
                    BigInt.from(last as int));
              }
            }
            final nativeRows =
                await Process.run(cli, ['-json', path, '${scenario.select};']);
            expect(nativeRows.exitCode, 0);
            final expected = (jsonDecode(nativeRows.stdout.toString()) as List)
                .map((r) => (r as Map).values.toList())
                .toList();
            expect(
                (await db.query(scenario.select)).rows.map(normalized).toList(),
                expected,
                reason: sql);
          }
          if (i == 4) {
            final nativeRows = await Process.run(
                cli, ['-json', path, 'SELECT x FROM audit ORDER BY rowid;']);
            expect(
                (await db.query('SELECT x FROM audit ORDER BY rowid'))
                    .rows
                    .map(normalized)
                    .toList(),
                (jsonDecode(nativeRows.stdout as String) as List)
                    .map((r) => (r as Map).values.toList())
                    .toList());
          }
          await File('${dir.path}/dart.db').writeAsBytes(db.exportImage());
          final check = await Process.run(
              cli, ['${dir.path}/dart.db', 'PRAGMA integrity_check;']);
          expect(check.exitCode, 0, reason: 'scenario=$i ${check.stderr}');
          expect(check.stdout.toString().trim(), 'ok',
              reason: 'scenario=$i ${check.stderr}');
        } finally {
          await db.close();
          await dir.delete(recursive: true);
        }
      }
    });
  }
}
