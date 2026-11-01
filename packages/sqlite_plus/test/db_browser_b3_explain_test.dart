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

  test('unsupported EXPLAIN stays rejected beside the CLI program', () async {
    final tool = await pinnedCli();
    expect(tool, isNotNull);
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    const rejected = <String>[
      'EXPLAIN SELECT 1+1',
      'EXPLAIN SELECT -(-1)',
      'EXPLAIN SELECT 1 WHERE 0',
      'EXPLAIN SELECT 1 WHERE 1',
      'EXPLAIN SELECT 1 FROM (SELECT 1)',
      'EXPLAIN SELECT * FROM t',
      'EXPLAIN INSERT INTO t VALUES (1)',
      'EXPLAIN SELECT title',
    ];
    for (final sql in rejected) {
      await expectLater(
          db.query(sql),
          throwsA(isA<SqlException>().having((error) => error.message,
              'message', 'EXPLAIN bytecode is not implemented')),
          reason: sql);
    }
    for (final sql in rejected) {
      await expectLater(
          db.browse(sql),
          throwsA(isA<SqlException>().having((error) => error.message,
              'message', 'EXPLAIN bytecode is not implemented')),
          reason: sql);
    }
    final add = await pinnedLines(tool!, 'EXPLAIN SELECT 1+1');
    expect(add.map(parseQuote).any((row) => row[1] == 'Add'), isTrue);
    final where = await pinnedLines(tool, 'EXPLAIN SELECT 1 WHERE 1');
    expect(where.length, 5);
    final missing =
        await Process.run(tool, [':memory:', 'EXPLAIN SELECT title']);
    expect(missing.exitCode, isNonZero);
    expect(missing.stderr.toString(), contains('no such column: title'));
    await expectLater(
        db.query('EXPLAIN SELECT 1', [1]),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            'EXPLAIN bytecode bindings unsupported')));
    expect((await db.query('SELECT 1')).rows, [
      [BigInt.one]
    ]);
    final plan = await db.query('EXPLAIN QUERY PLAN SELECT v FROM t');
    expect(plan.columns, ['detail']);
    expect(plan.rows.single.single.toString(), contains('t'));
    expect(plan.rows.single.single.toString(), isNot(contains('Opcode')));
    expect(plan.rows.single.single.toString(), isNot(contains('Init')));
  });
}
