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

  Future<String> pinnedCli() async {
    final tool = cli();
    expect(File(tool).existsSync(), isTrue);
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
    return tool;
  }

  List<Object?> parseQuote(String line) {
    final values = <Object?>[];
    var index = 0;
    while (index < line.length) {
      if (line.startsWith('NULL', index)) {
        values.add(null);
        index += 4;
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

  Future<List<List<Object?>>> pinnedRows(
      String tool, List<String> statements) async {
    final result = await Process.run(tool, [
      ':memory:',
      '.explain off',
      '.mode quote',
      '.headers off',
      ...statements
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}\n$statements');
    return [
      for (final line in result.stdout.toString().split('\n'))
        if (line.isNotEmpty) parseQuote(line)
    ];
  }

  Future<void> expectPlan(
      MutableSqliteDatabase db, String tool, String setup, String sql) async {
    final cliRows = await pinnedRows(tool, [if (setup.isNotEmpty) setup, sql]);
    final engine = await db.query(sql);
    expect(engine.columns, ['id', 'parent', 'notused', 'detail'], reason: sql);
    expect(engine.rows, cliRows, reason: sql);
  }

  test('EXPLAIN QUERY PLAN matches the pinned rows', () async {
    final tool = await pinnedCli();
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const setup = 'CREATE TABLE t(a INTEGER PRIMARY KEY)';
    await db.execute(setup);
    const positive = [
      'EXPLAIN QUERY PLAN SELECT a FROM t WHERE a=1',
      'EXPLAIN QUERY PLAN SELECT a FROM t',
      'EXPLAIN QUERY PLAN SELECT a FROM t WHERE a>1',
      'EXPLAIN QUERY PLAN SELECT 1',
    ];
    for (final sql in positive) {
      await expectPlan(db, tool, sql == positive.last ? '' : setup, sql);
    }
    const boundary = [
      'EXPLAIN QUERY PLAN SELECT a FROM t WHERE a>=1',
      'EXPLAIN QUERY PLAN SELECT a FROM t WHERE a<1',
      'EXPLAIN QUERY PLAN SELECT a FROM t WHERE a<=1',
      'EXPLAIN QUERY PLAN SELECT a FROM t WHERE a>1 AND a<9',
      'EXPLAIN QUERY PLAN SELECT a FROM T WHERE a=1',
    ];
    for (final sql in boundary) {
      await expectPlan(db, tool, setup, sql);
    }
    await db.execute('CREATE TABLE wide(a, b, c)');
    await db.execute('CREATE INDEX i ON wide(a, b)');
    await db.execute("INSERT INTO wide VALUES(1, 'b', 'c')");
    const wide = 'CREATE TABLE wide(a, b, c); CREATE INDEX i ON wide(a, b)';
    for (final sql in const [
      'EXPLAIN QUERY PLAN SELECT a, b FROM wide WHERE a=1',
      'EXPLAIN QUERY PLAN SELECT c FROM wide WHERE a=1',
      'EXPLAIN QUERY PLAN SELECT * FROM wide AS x',
    ]) {
      await expectPlan(db, tool, wide, sql);
    }
    await db.execute('CREATE TABLE keyed(a INTEGER PRIMARY KEY, b)');
    await db.execute('CREATE INDEX ib ON keyed(b)');
    const keyed =
        'CREATE TABLE keyed(a INTEGER PRIMARY KEY, b); CREATE INDEX ib ON keyed(b)';
    await expectPlan(
        db, tool, keyed, 'EXPLAIN QUERY PLAN SELECT * FROM keyed WHERE b=1');
    final missing = await Process.run(
        tool, [':memory:', 'EXPLAIN QUERY PLAN SELECT * FROM missing']);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such table: missing'));
    await expectLater(
        db.query('EXPLAIN QUERY PLAN SELECT * FROM missing'),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', 'no such table: missing')));
    await expectLater(
        db.query('EXPLAIN QUERY PLAN SELECT a FROM t WHERE a=?', [1]),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'EXPLAIN QUERY PLAN bindings unsupported')));
    final bytecode = await db.query('EXPLAIN SELECT 1');
    expect(bytecode.columns,
        ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment']);
    expect(bytecode.rows[1][1], 'Integer');
    final covered =
        await db.query('EXPLAIN QUERY PLAN SELECT a, b FROM wide WHERE a=1');
    expect(covered.rows.single[3].toString(), contains('COVERING'));
    expect((await db.query('SELECT a, b FROM wide WHERE a=1')).rows, [
      [BigInt.one, 'b']
    ]);
  });
}
