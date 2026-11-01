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

  test('EXPLAIN QUERY PLAN keeps the pinned row beside the difference',
      () async {
    final tool = await pinnedCli();
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INTEGER PRIMARY KEY)');
    const setup = 'CREATE TABLE t(a INTEGER PRIMARY KEY)';
    final cases = <(String, List<Object?>)>[
      (
        'EXPLAIN QUERY PLAN SELECT a FROM t WHERE a=1',
        [
          BigInt.two,
          BigInt.zero,
          BigInt.from(33),
          'SEARCH t USING INTEGER PRIMARY KEY (rowid=?)'
        ]
      ),
      (
        'EXPLAIN QUERY PLAN SELECT a FROM t',
        [BigInt.two, BigInt.zero, BigInt.from(216), 'SCAN t']
      ),
      (
        'EXPLAIN QUERY PLAN SELECT a FROM t WHERE a>1',
        [
          BigInt.two,
          BigInt.zero,
          BigInt.from(196),
          'SEARCH t USING INTEGER PRIMARY KEY (rowid>?)'
        ]
      ),
    ];
    for (final entry in cases) {
      final cliRows = await pinnedRows(tool, [setup, entry.$1]);
      expect(cliRows, [entry.$2], reason: entry.$1);
      final engine = await db.query(entry.$1);
      expect(engine.columns, ['detail'], reason: entry.$1);
      final text = engine.rows.single.single.toString();
      expect(text, contains('t'), reason: entry.$1);
      expect(text, isNot(entry.$2.last), reason: entry.$1);
      expect(text.contains('INTEGER PRIMARY KEY'), isFalse, reason: entry.$1);
      expect(engine.rows, isNot(cliRows), reason: entry.$1);
    }
    final constant = await pinnedRows(tool, ['EXPLAIN QUERY PLAN SELECT 1']);
    expect(constant, [
      [BigInt.one, BigInt.zero, BigInt.zero, 'SCAN CONSTANT ROW']
    ]);
    final engineConstant = await db.query('EXPLAIN QUERY PLAN SELECT 1');
    expect(engineConstant.columns, ['detail']);
    expect(engineConstant.rows, isNot(constant));
    final missing = await Process.run(
        tool, [':memory:', 'EXPLAIN QUERY PLAN SELECT * FROM missing']);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such table: missing'));
    await expectLater(db.query('EXPLAIN QUERY PLAN SELECT * FROM missing'),
        throwsA(isA<SqlException>()));
    final bytecode = await db.query('EXPLAIN SELECT 1');
    expect(bytecode.columns,
        ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment']);
    expect(bytecode.rows[1][1], 'Integer');
    await db.execute('CREATE TABLE wide(a, b, c)');
    await db.execute('CREATE INDEX i ON wide(a, b)');
    await db.execute("INSERT INTO wide VALUES(1, 'b', 'c')");
    final covered =
        await db.query('EXPLAIN QUERY PLAN SELECT a, b FROM wide WHERE a=1');
    expect(covered.columns, ['detail']);
    expect(covered.rows.single.single.toString(), contains('COVERING'));
  });
}
