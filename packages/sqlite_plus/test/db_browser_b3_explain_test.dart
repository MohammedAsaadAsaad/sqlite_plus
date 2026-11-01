import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

const _pin =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  if (!File(cli()).existsSync()) {
    test('pinned sqlite3 is not installed', () {
      markTestSkipped('pinned sqlite3 is not installed');
    });
    return;
  }

  Future<String?> pinnedCli() async {
    final tool = cli();
    if (!File(tool).existsSync()) return null;
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
    return tool;
  }

  Future<List<String>> pinnedLines(String tool, String sql,
      {Encoding encoding = utf8}) async {
    final result = await Process.run(
      tool,
      [':memory:', '.explain off', '.mode quote', '.headers off', sql],
      stdoutEncoding: encoding,
      stderrEncoding: utf8,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}\n$sql');
    return result.stdout
        .toString()
        .split('\n')
        .where((line) => line.isNotEmpty)
        .toList();
  }

  List<Object?> parseQuote(String line) {
    final values = <Object?>[];
    var index = 0;
    while (index < line.length) {
      if (line.startsWith('NULL', index)) {
        values.add(null);
        index += 4;
      } else if (line.startsWith("unistr('", index)) {
        index += "unistr('".length;
        final chars = StringBuffer();
        while (index < line.length) {
          if (line[index] == "'") {
            if (index + 1 < line.length && line[index + 1] == "'") {
              chars.write("'");
              index += 2;
              continue;
            }
            index++;
            if (index < line.length && line[index] == ')') index++;
            break;
          }
          if (line[index] == r'\' && index + 1 < line.length) {
            final mark = line[index + 1];
            if (mark == r'\') {
              chars.write(r'\');
              index += 2;
              continue;
            }
            if (mark == 'u' && index + 6 <= line.length) {
              chars.writeCharCode(
                  int.parse(line.substring(index + 2, index + 6), radix: 16));
              index += 6;
              continue;
            }
          }
          chars.write(line[index]);
          index++;
        }
        values.add(chars.toString());
      } else if (line[index] == "'") {
        index++;
        final chars = StringBuffer();
        while (index < line.length) {
          if (line[index] == "'") {
            if (index + 1 < line.length && line[index + 1] == "'") {
              chars.write("'");
              index += 2;
              continue;
            }
            index++;
            break;
          }
          chars.write(line[index]);
          index++;
        }
        values.add(chars.toString());
      } else {
        var end = index;
        while (end < line.length && line[end] != ',') {
          end++;
        }
        values.add(BigInt.parse(line.substring(index, end)));
        index = end;
      }
      if (index < line.length && line[index] == ',') index++;
    }
    return values;
  }

  test('literal EXPLAIN matches the pinned CLI rows and columns', () async {
    final tool = await pinnedCli();
    expect(tool, isNotNull);
    final headers = await Process.run(tool!, [
      ':memory:',
      '.explain off',
      '.mode list',
      '.headers on',
      'EXPLAIN SELECT 1'
    ]);
    expect(headers.exitCode, 0, reason: headers.stderr.toString());
    expect(headers.stdout.toString().split('\n').first,
        'addr|opcode|p1|p2|p3|p4|p5|comment');
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const statements = <String>[
      'EXPLAIN SELECT 1',
      'explain select 1',
      'EXPLAIN SELECT 1;',
      'EXPLAIN SELECT /*c*/ 1',
      'EXPLAIN SELECT 2',
      'EXPLAIN SELECT -1',
      'EXPLAIN SELECT +1',
      'EXPLAIN SELECT -+1',
      'EXPLAIN SELECT +-1',
      'EXPLAIN SELECT -(+1)',
      'EXPLAIN SELECT (1)',
      'EXPLAIN SELECT ((1))',
      'EXPLAIN SELECT 1 AS x',
      'EXPLAIN SELECT 1 x',
      'EXPLAIN SELECT -0',
      'EXPLAIN SELECT 00',
      'EXPLAIN SELECT 0001',
      'EXPLAIN SELECT 1_000',
      'EXPLAIN SELECT 2147483647',
      'EXPLAIN SELECT -2147483647',
      'EXPLAIN SELECT 2147483648',
      'EXPLAIN SELECT -2147483648',
      'EXPLAIN SELECT -2147483649',
      'EXPLAIN SELECT 9223372036854775807',
      'EXPLAIN SELECT -9223372036854775808',
      'EXPLAIN SELECT 9223372036854775808',
      'EXPLAIN SELECT 0x10',
      'EXPLAIN SELECT -0x10',
      'EXPLAIN SELECT +0x10',
      'EXPLAIN SELECT 0x7fffffff',
      'EXPLAIN SELECT 0x80000000',
      'EXPLAIN SELECT 0xffffffff',
      'EXPLAIN SELECT 0xffffffffffffffff',
      'EXPLAIN SELECT 0x8000000000000000',
      'EXPLAIN SELECT NULL',
      "EXPLAIN SELECT 'a'",
      "EXPLAIN SELECT ''",
      "EXPLAIN SELECT 'a''b'",
      "EXPLAIN SELECT 'ä'",
      'EXPLAIN SELECT TRUE',
      'EXPLAIN SELECT FALSE',
      'EXPLAIN SELECT true, false',
      'EXPLAIN SELECT 1.5',
      'EXPLAIN SELECT 1.0',
      'EXPLAIN SELECT 0.0',
      'EXPLAIN SELECT -0.0',
      'EXPLAIN SELECT -1.0',
      'EXPLAIN SELECT -1.5',
      'EXPLAIN SELECT .5',
      'EXPLAIN SELECT 1.',
      'EXPLAIN SELECT 1e2',
      'EXPLAIN SELECT 1.5e1',
      'EXPLAIN SELECT 1e20',
      'EXPLAIN SELECT 1e16',
      'EXPLAIN SELECT 1e15',
      'EXPLAIN SELECT 1e-4',
      'EXPLAIN SELECT 1e-5',
      'EXPLAIN SELECT 1e-6',
      'EXPLAIN SELECT 1e-7',
      'EXPLAIN SELECT 1e-10',
      'EXPLAIN SELECT 1.2345678901234567',
      'EXPLAIN SELECT 1e309',
      'EXPLAIN SELECT -1e309',
      'EXPLAIN SELECT 1, 2',
      "EXPLAIN SELECT 1, NULL, 'a'",
      "EXPLAIN SELECT x'61'",
      "EXPLAIN SELECT x''",
      "EXPLAIN SELECT x'00'",
      "EXPLAIN SELECT x'6100'",
      "EXPLAIN SELECT x'c3a4'",
    ];
    for (final sql in statements) {
      final engine = await db.query(sql);
      final browsed = await db.browse(sql);
      final lines = await pinnedLines(tool, sql);
      final rows = [for (final line in lines) parseQuote(line)];
      expect(engine.columns,
          ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment'],
          reason: sql);
      expect(engine.rows, rows, reason: sql);
      expect(browsed.columns, engine.columns, reason: sql);
      expect(browsed.rows, engine.rows, reason: sql);
    }
    final raw = await Process.run(
      tool,
      [
        ':memory:',
        '.explain off',
        '.mode quote',
        '.headers off',
        "EXPLAIN SELECT x'ff'"
      ],
      stdoutEncoding: latin1,
    );
    expect(raw.exitCode, 0, reason: raw.stderr.toString());
    final blob = await db.query("EXPLAIN SELECT x'ff'");
    final cliBlob = [
      for (final line in raw.stdout.toString().split('\n'))
        if (line.isNotEmpty) parseQuote(line)
    ];
    expect(blob.rows, cliBlob);
    expect(blob.rows[1][1], 'Blob');
    expect(blob.rows[1][2], BigInt.one);
    expect(blob.rows[1][5], String.fromCharCode(0xff));
  });

  test('constant arithmetic EXPLAIN matches the pinned CLI', () async {
    final tool = await pinnedCli();
    expect(tool, isNotNull);
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const statements = <String>[
      'EXPLAIN SELECT 1+1',
      'EXPLAIN SELECT 5-2',
      'EXPLAIN SELECT 2-5',
      'EXPLAIN SELECT 8/2',
      'EXPLAIN SELECT 8%3',
      "EXPLAIN SELECT 'ab'||'c'",
      'EXPLAIN SELECT (1+2)',
      'EXPLAIN SELECT ((1+2))',
      'EXPLAIN SELECT 1+2+3',
      'EXPLAIN SELECT 1+2+3+4',
      'EXPLAIN SELECT 1+2*3',
      'EXPLAIN SELECT 1*2+3',
      'EXPLAIN SELECT (1+2)*3',
      'EXPLAIN SELECT 1*2*3',
      'EXPLAIN SELECT 10/2/2',
      'EXPLAIN SELECT 4-1-1',
      'EXPLAIN SELECT 2*3+4*5',
      'EXPLAIN SELECT (1+2)+(1+2)',
      'EXPLAIN SELECT 1+1,1+1',
      'EXPLAIN SELECT 1+2,3',
      "EXPLAIN SELECT 'a'||'a'",
      "EXPLAIN SELECT 'a'||'a', 'a'",
      "EXPLAIN SELECT 'a'||'b'||'c'",
      'EXPLAIN SELECT 1||2||3',
      'EXPLAIN SELECT -(1)',
      'EXPLAIN SELECT -(-1)',
      'EXPLAIN SELECT -(-1)+1',
      'EXPLAIN SELECT 1+-(-1)',
      'EXPLAIN SELECT 1+1, 1',
      'EXPLAIN SELECT 1+TRUE',
      'EXPLAIN SELECT TRUE+1',
      'EXPLAIN SELECT 8%3, 8/2, 5-2',
      "EXPLAIN SELECT NULL||'a', 1+1",
      'EXPLAIN SELECT 1e2+1',
      'EXPLAIN SELECT 1/0',
      'EXPLAIN SELECT 1 WHERE 1',
      'EXPLAIN SELECT 1 WHERE TRUE',
      'EXPLAIN SELECT 1 WHERE 2',
      'EXPLAIN SELECT 1 WHERE (1)',
      'EXPLAIN SELECT 1 WHERE 0x1',
      'EXPLAIN SELECT 1 WHERE NOT 0',
      'EXPLAIN SELECT 1 WHERE NOT NOT 1',
      'EXPLAIN SELECT FALSE, 1 WHERE TRUE',
      'EXPLAIN SELECT 1+1 WHERE 1',
      'EXPLAIN SELECT 1 WHERE 0',
      'EXPLAIN SELECT 1 WHERE FALSE',
      'EXPLAIN SELECT 1 WHERE (0)',
      'EXPLAIN SELECT 1 WHERE ((0))',
      'EXPLAIN SELECT 1 WHERE 00',
      'EXPLAIN SELECT 1 WHERE 0x0',
      'EXPLAIN SELECT 1 WHERE NOT 1',
      'EXPLAIN SELECT 1 WHERE NOT NOT 0',
      'EXPLAIN SELECT 1,2 WHERE 0',
      'EXPLAIN SELECT 1,2,3 WHERE 0',
      'EXPLAIN SELECT TRUE WHERE FALSE',
      'EXPLAIN SELECT TRUE, FALSE WHERE 0',
      'EXPLAIN SELECT 1+1 WHERE 0',
      'EXPLAIN SELECT 1+2*3 WHERE 0',
      'EXPLAIN SELECT 1 WHERE NULL',
      'EXPLAIN SELECT 1 WHERE 0.0',
      'EXPLAIN SELECT 1 WHERE 1.0',
      "EXPLAIN SELECT 1 WHERE 'a'",
      "EXPLAIN SELECT 1 WHERE ''",
      "EXPLAIN SELECT 1 WHERE '0'",
      'EXPLAIN SELECT 1 WHERE -1',
      'EXPLAIN SELECT 1 WHERE +0',
      'EXPLAIN SELECT 1 WHERE -0',
      'EXPLAIN SELECT 1 WHERE +1',
      'EXPLAIN SELECT 1 WHERE -(1)',
      'EXPLAIN SELECT 1 WHERE 0.5',
      "EXPLAIN SELECT 1 WHERE x'61'",
      "EXPLAIN SELECT 1 WHERE x''",
      "EXPLAIN SELECT 1 WHERE x'00'",
      'EXPLAIN SELECT 1 WHERE 1+1',
      'EXPLAIN SELECT 1 WHERE (1+1)',
      'EXPLAIN SELECT 1 WHERE 2+2',
      'EXPLAIN SELECT 1 WHERE 1-1',
      "EXPLAIN SELECT 1 WHERE 'a'||'b'",
      "EXPLAIN SELECT 1 WHERE NULL||'a'",
      'EXPLAIN SELECT 1 WHERE 1+0',
      'EXPLAIN SELECT 1 WHERE 0+0',
      'EXPLAIN SELECT 1 WHERE 5-5',
      "EXPLAIN SELECT 1 WHERE 'a'||''",
      'EXPLAIN SELECT 1+1 WHERE 0.0',
      "EXPLAIN SELECT 1+1 WHERE 'a'",
      'EXPLAIN SELECT 1+1 WHERE 1+1',
      'EXPLAIN SELECT 1,2 WHERE 1+2',
      'EXPLAIN SELECT 1+2 WHERE 1+2',
      "EXPLAIN SELECT 1+1 WHERE 'a'||'b'",
      'EXPLAIN SELECT 1 WHERE 2*3+4*5',
      'EXPLAIN SELECT 1 WHERE -(-1)',
      'EXPLAIN SELECT NULL WHERE NULL',
      "EXPLAIN SELECT 1, NULL WHERE 'a'",
      "EXPLAIN SELECT x'61' WHERE x'61'",
    ];
    for (final sql in statements) {
      final engine = await db.query(sql);
      final browsed = await db.browse(sql);
      final rows = [
        for (final line in await pinnedLines(tool!, sql)) parseQuote(line)
      ];
      expect(engine.columns,
          ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment'],
          reason: sql);
      expect(engine.rows, rows, reason: sql);
      expect(browsed.rows, engine.rows, reason: sql);
    }
  });

  test('table scan and literal INSERT EXPLAIN match the pinned CLI', () async {
    final tool = await pinnedCli();
    expect(tool, isNotNull);
    const cases = <(String, String)>[
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT a FROM t'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN SELECT a FROM t'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN SELECT b FROM t'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN SELECT * FROM t'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN SELECT a,b FROM t'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN SELECT b,a FROM t'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN SELECT a,a FROM t'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT * FROM t'),
      ('CREATE TABLE t(a); CREATE TABLE u(b);', 'EXPLAIN SELECT b FROM u'),
      ('CREATE TABLE t(a); CREATE TABLE u(b);', 'EXPLAIN SELECT a FROM t'),
      ('CREATE TABLE t(a,b,c);', 'EXPLAIN SELECT a,c FROM t'),
      ('CREATE TABLE t(a,b,c);', 'EXPLAIN SELECT c,a FROM t'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT a FROM main.t'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT t.a FROM t'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT a FROM t AS x'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT x.a FROM t AS x'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT t.* FROM t'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT /*c*/ a FROM t'),
      ('CREATE TABLE t("A b");', 'EXPLAIN SELECT "A b" FROM t'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT a FROM t WHERE 1'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT a FROM t WHERE 0'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT a FROM t WHERE 0.0'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT a FROM t WHERE 1+1'),
      ('CREATE TABLE t(a INT, b TEXT);', 'EXPLAIN SELECT b, a FROM t'),
      ('CREATE TABLE t(a INT PRIMARY KEY);', 'EXPLAIN SELECT a FROM t'),
      ('', 'EXPLAIN SELECT name FROM sqlite_schema'),
      ('', 'EXPLAIN SELECT type, name FROM sqlite_master'),
      ('', 'EXPLAIN SELECT * FROM sqlite_schema'),
      ('CREATE TABLE t(a);', 'EXPLAIN SELECT name FROM sqlite_schema'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (1)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (NULL)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (-1)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (-0)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (+1)'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN INSERT INTO t VALUES (1,2)'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN INSERT INTO t DEFAULT VALUES'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t DEFAULT VALUES'),
      ('CREATE TABLE t(a,b,c);', 'EXPLAIN INSERT INTO t DEFAULT VALUES'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN INSERT INTO t(a,b) VALUES (1,2)'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN INSERT INTO t(b,a) VALUES (1,2)'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN INSERT INTO t(a) VALUES (1)'),
      ('CREATE TABLE t(a,b);', 'EXPLAIN INSERT INTO t(a,b) VALUES (1, NULL)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO T VALUES (1)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO "t" VALUES (1)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO [t] VALUES (1)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO main.t VALUES (1)'),
      ('CREATE TABLE "Hello"(a);', 'EXPLAIN INSERT INTO hello VALUES (1)'),
      ('CREATE TABLE "T"(a);', 'EXPLAIN INSERT INTO t VALUES (1)'),
      ('CREATE TABLE "T t"(a);', 'EXPLAIN INSERT INTO "T t" VALUES (1)'),
      ('CREATE TABLE "T t"(a);', 'EXPLAIN SELECT a FROM "T t"'),
      ('CREATE TABLE t(a);', 'EXPLAIN REPLACE INTO t VALUES (1)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (1+2*3)'),
      ('CREATE TABLE t(a);', "EXPLAIN INSERT INTO t VALUES ('ab')"),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (1.5)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (/*c*/ 1)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (2147483648)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (0x10)'),
      (
        'CREATE TABLE t(a, b DEFAULT 2);',
        'EXPLAIN INSERT INTO t(a,b) VALUES (1,2)'
      ),
      ('CREATE TABLE t(a INTEGER PRIMARY KEY);', 'EXPLAIN SELECT a FROM t'),
      (
        'CREATE TABLE t(a INTEGER PRIMARY KEY);',
        'EXPLAIN SELECT a FROM t WHERE 0'
      ),
      ('CREATE TABLE t(a INTEGER PRIMARY KEY, b);', 'EXPLAIN SELECT * FROM t'),
      ('CREATE TABLE t(a INTEGER PRIMARY KEY, b);', 'EXPLAIN SELECT b FROM t'),
      ('CREATE TABLE t(a INTEGER PRIMARY KEY, b);', 'EXPLAIN SELECT a FROM t'),
      ('CREATE TABLE t(v);', 'EXPLAIN SELECT rowid FROM t'),
      ('CREATE TABLE t(v);', 'EXPLAIN SELECT oid, _rowid_ FROM t'),
      ('CREATE TABLE t(rowid);', 'EXPLAIN SELECT rowid FROM t'),
      (
        'CREATE TABLE t(a PRIMARY KEY) WITHOUT ROWID;',
        'EXPLAIN SELECT a FROM t'
      ),
      (
        'CREATE TABLE t(a, b, PRIMARY KEY(a, b)) WITHOUT ROWID;',
        'EXPLAIN SELECT a, b FROM t'
      ),
      (
        'CREATE TABLE t(a PRIMARY KEY, b) WITHOUT ROWID;',
        'EXPLAIN SELECT * FROM t'
      ),
      (
        'CREATE TABLE t(b, a PRIMARY KEY) WITHOUT ROWID;',
        'EXPLAIN SELECT b, a FROM t'
      ),
      (
        'CREATE TABLE t(a PRIMARY KEY COLLATE NOCASE) WITHOUT ROWID;',
        'EXPLAIN SELECT a FROM t'
      ),
      (
        'CREATE TABLE t(a PRIMARY KEY DESC) WITHOUT ROWID;',
        'EXPLAIN SELECT a FROM t'
      ),
      (
        'CREATE TABLE t(a PRIMARY KEY COLLATE binary) WITHOUT ROWID;',
        'EXPLAIN SELECT a FROM t'
      ),
      ('CREATE TABLE t(a, b AS (a+1));', 'EXPLAIN SELECT * FROM t'),
      ('CREATE TABLE t(a, b AS (a+1));', 'EXPLAIN SELECT b FROM t'),
      ('CREATE TABLE t(a, b AS (a+1));', 'EXPLAIN SELECT a FROM t'),
      ('CREATE TABLE t(a, b AS (a+1) STORED);', 'EXPLAIN SELECT * FROM t'),
      ('CREATE TABLE t(a, c, b AS (a+1));', 'EXPLAIN SELECT b FROM t'),
      ('CREATE TABLE t(a, c, b AS (a+1));', 'EXPLAIN SELECT a FROM t'),
      ('CREATE TABLE t(a, b AS (a));', 'EXPLAIN SELECT b FROM t'),
      ('CREATE TABLE t(a, b AS (a+1), c AS (a*2));', 'EXPLAIN SELECT * FROM t'),
      (
        'CREATE TABLE t(a INTEGER PRIMARY KEY, b, c AS (b+1));',
        'EXPLAIN SELECT * FROM t'
      ),
      ('CREATE TABLE t(a INT);', 'EXPLAIN INSERT INTO t VALUES (1)'),
      ('CREATE TABLE t(a TEXT);', "EXPLAIN INSERT INTO t VALUES ('ab')"),
      ('CREATE TABLE t(a REAL);', 'EXPLAIN INSERT INTO t VALUES (1.5)'),
      ('CREATE TABLE t(a BLOB);', "EXPLAIN INSERT INTO t VALUES (x'61')"),
      ('CREATE TABLE t(a, b INT);', 'EXPLAIN INSERT INTO t VALUES (1, 2)'),
      ('CREATE TABLE t(a NUMERIC);', 'EXPLAIN INSERT INTO t VALUES (1)'),
      ('CREATE TABLE t(a INTEGER);', 'EXPLAIN INSERT INTO t VALUES (1)'),
      ('CREATE TABLE t(a FLOAT);', 'EXPLAIN INSERT INTO t VALUES (1.5)'),
      ('CREATE TABLE t(a VARCHAR(10));', "EXPLAIN INSERT INTO t VALUES ('ab')"),
      ('CREATE TABLE t(a BIGINT);', 'EXPLAIN INSERT INTO t VALUES (1)'),
      ('CREATE TABLE t(a ANY);', 'EXPLAIN INSERT INTO t VALUES (1)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (1),(2)'),
      ('CREATE TABLE t(a);', 'EXPLAIN INSERT INTO t VALUES (1),(2),(3)'),
      (
        'CREATE TABLE t(a, b);',
        "EXPLAIN INSERT INTO t VALUES (1, 'x'),(2, 'y')"
      ),
      (
        'CREATE TABLE t(a, b, c);',
        'EXPLAIN INSERT INTO t VALUES (1, 2, 3),(4, 5, 6)'
      ),
      (
        'CREATE TABLE t(a, b, c, d);',
        'EXPLAIN INSERT INTO t VALUES (1, 2, 3, 4),(5, 6, 7, 8)'
      ),
      ('CREATE TABLE t(a INT);', 'EXPLAIN INSERT INTO t VALUES (1),(2)'),
      (
        'CREATE TABLE t(a INT, b TEXT);',
        "EXPLAIN INSERT INTO t VALUES (1, 'x'),(2, 'y')"
      ),
      ('', 'EXPLAIN SELECT 1 FROM (SELECT 1)'),
      ('', 'EXPLAIN SELECT 1 FROM (SELECT 1, 2)'),
      ('', 'EXPLAIN SELECT x, y FROM (SELECT 1 AS x, 2 AS y)'),
      ('', 'EXPLAIN SELECT x FROM (SELECT 1 AS x, 2 AS y)'),
    ];
    for (final (setup, sql) in cases) {
      final db = await MutableSqliteDatabase.create();
      addTearDown(db.close);
      for (final part in setup.split(';')) {
        final statement = part.trim();
        if (statement.isEmpty) continue;
        await db.execute(statement);
      }
      final QueryResult engine;
      try {
        engine = await db.query(sql);
      } catch (error) {
        fail('$setup $sql\n$error');
      }
      final browsed = await db.browse(sql);
      final script = setup.isEmpty ? sql : '$setup $sql';
      final rows = [
        for (final line in await pinnedLines(tool!, script)) parseQuote(line)
      ];
      expect(engine.rows, rows, reason: script);
      expect(browsed.rows, engine.rows, reason: script);
    }
  });

  test('unsupported EXPLAIN stays rejected beside the CLI program', () async {
    final tool = await pinnedCli();
    expect(tool, isNotNull);
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    const rejected = <String>[
      'EXPLAIN SELECT 1 FROM (SELECT 1), (SELECT 2)',
      'EXPLAIN SELECT title',
      'EXPLAIN SELECT 1 WHERE NOT 0.0',
      'EXPLAIN SELECT 1 WHERE a',
    ];
    for (final sql in rejected) {
      await expectLater(
          db.query(sql),
          throwsA(isA<SqlException>().having((error) => error.message,
              'message', 'EXPLAIN bytecode is not implemented')),
          reason: sql);
      await expectLater(
          db.browse(sql),
          throwsA(isA<SqlException>().having((error) => error.message,
              'message', 'EXPLAIN bytecode is not implemented')),
          reason: sql);
    }
    final missing =
        await Process.run(tool!, [':memory:', 'EXPLAIN SELECT title']);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such column: title'));
    final ipk = await MutableSqliteDatabase.create();
    addTearDown(ipk.close);
    await ipk.execute('CREATE TABLE t(a INTEGER PRIMARY KEY)');
    await expectLater(
        ipk.query('EXPLAIN INSERT INTO t VALUES (1)'),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'EXPLAIN bytecode is not implemented')));
    final ipkCli = await Process.run(tool, [
      ':memory:',
      'CREATE TABLE t(a INTEGER PRIMARY KEY); EXPLAIN INSERT INTO t VALUES (1)'
    ]);
    expect(ipkCli.exitCode, 0, reason: ipkCli.stderr.toString());
    await expectLater(
        db.query('EXPLAIN SELECT 1', [1]),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'EXPLAIN bytecode bindings unsupported')));
    expect((await db.query('SELECT 1')).rows, [
      [BigInt.one]
    ]);
    final plan = await db.query('EXPLAIN QUERY PLAN SELECT v FROM t');
    expect(plan.columns, ['id', 'parent', 'notused', 'detail']);
    expect(plan.rows.single[3].toString(), contains('t'));
    expect(plan.rows.single[3].toString(), isNot(contains('Opcode')));
    expect(plan.rows.single[3].toString(), isNot(contains('Init')));
  });
}
