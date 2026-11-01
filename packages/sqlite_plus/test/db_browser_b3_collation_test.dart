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

  late String tool;
  setUpAll(() async {
    tool = cli();
    final id =
        await Process.run(tool, [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.exitCode, 0, reason: id.stderr.toString());
    expect(id.stdout.toString().trim(), _pin);
  });

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
        final token = line.substring(index, end);
        values.add(
            token.contains('.') || token.contains('e') || token.contains('E')
                ? double.parse(token)
                : BigInt.parse(token));
        index = end;
      }
      if (index < line.length && line[index] == ',') index++;
    }
    return values;
  }

  String cell(Object? value) => value == null
      ? 'NULL'
      : value is double
          ? value.toString()
          : value.toString();

  Future<void> match(List<String> statements) async {
    final cliResult = await Process.run(
        tool, [':memory:', '.mode quote', '.headers off', ...statements]);
    final db = await MutableSqliteDatabase.create();
    Object? engineError;
    List<List<Object?>>? rows;
    try {
      for (var i = 0; i < statements.length; i++) {
        final sql = statements[i];
        final query =
            RegExp(r'^\s*(SELECT|PRAGMA|WITH|EXPLAIN)\b', caseSensitive: false)
                .hasMatch(sql);
        if (query) {
          final result = await db.query(sql);
          if (i == statements.length - 1) rows = result.rows;
        } else {
          await db.execute(sql);
        }
      }
    } on SqlException catch (error) {
      engineError = error.message;
    } finally {
      await db.close();
    }
    if (cliResult.exitCode == 0) {
      expect(engineError, isNull,
          reason: '${statements.join('; ')}\n$engineError');
      final expected = [
        for (final line in cliResult.stdout.toString().split('\n'))
          if (line.isNotEmpty) parseQuote(line)
      ];
      String shown(List<List<Object?>> table) =>
          table.map((row) => row.map(cell).join(',')).join('\n');
      expect(shown(rows ?? []), shown(expected), reason: statements.join('; '));
      return;
    }
    expect(engineError, isNotNull, reason: cliResult.stderr.toString());
    expect(cliResult.stderr.toString(), contains(engineError),
        reason: statements.join('; '));
  }

  test('positive built-in comparisons match the pin', () async {
    const cases = [
      "SELECT 'a'='A' COLLATE NOCASE",
      "SELECT 'a'='A' COLLATE BINARY",
      "SELECT 'a '='a' COLLATE RTRIM",
      "SELECT 'á'<'b' COLLATE NOCASE",
      "SELECT 'a'='A' COLLATE nocase",
      "SELECT '10'>'9' COLLATE decimal",
      "SELECT '10'='9' COLLATE decimal",
      "SELECT '1.50'='1.5' COLLATE decimal",
      "SELECT '1.50'='1.5' COLLATE uint",
      "SELECT '1e2'='100' COLLATE decimal",
      "SELECT '1e2'='100' COLLATE uint",
      "SELECT 'x00123y'='x123y' COLLATE uint",
      "SELECT 'a10'<'a2' COLLATE uint",
      "SELECT 'abc'='def' COLLATE decimal",
      "SELECT '1'='1x' COLLATE decimal",
      "SELECT '10 '='10' COLLATE decimal",
      "SELECT '10 '>'10' COLLATE decimal",
      "SELECT '-2'<'-10' COLLATE decimal",
      "SELECT '-2'<'1' COLLATE decimal",
      "SELECT '  10'='10' COLLATE decimal",
      "SELECT '+10'='10' COLLATE decimal",
      "SELECT '10' COLLATE decimal > '9'",
      "SELECT typeof('a' COLLATE ICU)",
      "SELECT 'a' COLLATE ICU",
      "SELECT 'a' COLLATE \"\"",
      "SELECT '1 0'='10' COLLATE decimal",
      "SELECT '1.2.3'='1.23' COLLATE decimal",
      "SELECT '1e'='1' COLLATE decimal",
      "SELECT '1e2x3'='1e23' COLLATE decimal",
      "SELECT '  -001.50e+1'='-15' COLLATE decimal",
      "SELECT '1E-2'='0.01' COLLATE decimal",
      "SELECT x'31'='1' COLLATE decimal",
      "SELECT 10>9 COLLATE decimal",
      "SELECT '10'>9 COLLATE decimal",
      "SELECT 'A'='a' COLLATE uint",
      "SELECT 'A'<'a' COLLATE uint",
      "SELECT ''='' COLLATE decimal",
      "SELECT ''='' COLLATE uint",
      "SELECT '0'='000' COLLATE decimal",
      "SELECT '0'='000' COLLATE uint",
      "SELECT '00a'='a' COLLATE uint",
      "SELECT '10a'='010a' COLLATE uint",
      "SELECT 'a10b2'<'a2b10' COLLATE uint",
      "SELECT '9'<'10' COLLATE uint",
      "SELECT '1.'='1' COLLATE decimal",
      "SELECT '.5'='0.5' COLLATE decimal",
      "SELECT '.'='0' COLLATE decimal",
      "SELECT 'e2'='100' COLLATE decimal",
      "SELECT '--1'='1' COLLATE decimal",
      "SELECT '++1'='1' COLLATE decimal",
      "SELECT quote('a' COLLATE en_US)",
    ];
    for (final sql in cases) {
      await match([sql]);
    }
  });

  test('ORDER BY, GROUP BY, and column collation match the pin', () async {
    await match([
      'CREATE TABLE t(v)',
      "INSERT INTO t VALUES('-2'),('1.5'),('9'),('10')",
      'SELECT v FROM t ORDER BY v COLLATE decimal',
    ]);
    await match([
      'CREATE TABLE t(v)',
      "INSERT INTO t VALUES('a10'),('a2'),('a001')",
      'SELECT v FROM t ORDER BY v COLLATE uint',
    ]);
    await match([
      'CREATE TABLE t(v TEXT COLLATE decimal)',
      "INSERT INTO t VALUES('10'),('9'),('1.5')",
      'SELECT v FROM t ORDER BY v',
    ]);
    await match([
      'CREATE TABLE t(v TEXT COLLATE decimal)',
      "INSERT INTO t VALUES('1.50'),('1.5'),('9')",
      'SELECT count(*) FROM t GROUP BY v ORDER BY count(*)',
    ]);
    await match([
      'CREATE TABLE t(v TEXT COLLATE uint)',
      "INSERT INTO t VALUES('a010'),('a10'),('b')",
      'SELECT count(*) FROM t GROUP BY v ORDER BY count(*)',
    ]);
    await match(['PRAGMA collation_list']);
  });

  test('negative unknown collations use the pin message', () async {
    await match(['CREATE TABLE t(v TEXT COLLATE ICU)']);
    await match(["SELECT 'a'='A' COLLATE ICU"]);
    await match(["SELECT 'a'='A' COLLATE Icu"]);
    await match(["SELECT 'a'='A' COLLATE en_US"]);
    await match(["SELECT 'a'='b' COLLATE \"\""]);
    await match(['CREATE TABLE t(v TEXT COLLATE "")']);
    await match([
      'CREATE TABLE t(a)',
      'CREATE INDEX i ON t(a COLLATE ICU)',
    ]);
    await match(["SELECT NULL='a' COLLATE ICU"]);
    await match([
      "SELECT CASE WHEN 0 THEN 'a'='A' COLLATE ICU ELSE 1 END",
    ]);
    await match([
      "SELECT CASE WHEN 0 THEN 'a' COLLATE ICU ELSE 1 END",
    ]);
    await match(["SELECT 1 OR 'a'='b' COLLATE ICU"]);
    await match(["SELECT 0 AND 'a'='b' COLLATE ICU"]);
    await match(["SELECT (1 OR 'a'='b' COLLATE ICU)=1"]);
  });

  test('boundary UNIQUE rejects equal decimal and uint spellings', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v TEXT COLLATE decimal UNIQUE)');
    await db.execute("INSERT INTO t VALUES('1.50')");
    await expectLater(
        db.execute("INSERT INTO t VALUES('1.5')"),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            contains('UNIQUE constraint failed'))));
    expect((await db.query('SELECT count(*) FROM t')).rows, [
      [BigInt.one]
    ]);
    final uint = await MutableSqliteDatabase.create();
    addTearDown(uint.close);
    await uint.execute('CREATE TABLE u(v TEXT COLLATE uint UNIQUE)');
    await uint.execute("INSERT INTO u VALUES('a010')");
    await expectLater(
        uint.execute("INSERT INTO u VALUES('a10')"),
        throwsA(isA<SqlException>().having((error) => error.message, 'message',
            contains('UNIQUE constraint failed'))));
    final pin = await Process.run(tool, [
      ':memory:',
      'CREATE TABLE t(v TEXT COLLATE decimal UNIQUE)',
      "INSERT INTO t VALUES('1.50')",
      "INSERT INTO t VALUES('1.5')",
    ]);
    expect(pin.exitCode, isNonZero);
    expect(pin.stderr.toString(), contains('UNIQUE constraint failed: t.v'));
  });

  test('regression custom collation and built-in names stay distinct',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    db.functions.createCollation('rev', (a, b) => b.compareTo(a));
    await db.execute('CREATE TABLE t(v TEXT COLLATE rev)');
    await db.execute("INSERT INTO t VALUES('a'),('c'),('b')");
    expect((await db.query('SELECT v FROM t ORDER BY v')).rows,
        ['c', 'b', 'a'].map((v) => [v]).toList());
    expect(() => db.functions.createCollation('decimal', (a, b) => 0),
        throwsArgumentError);
    expect(() => db.functions.createCollation('uint', (a, b) => 0),
        throwsArgumentError);
    expect((await db.query("SELECT 'a'='A' COLLATE NOCASE")).rows, [
      [BigInt.one]
    ]);
    expect((await db.query("SELECT 'a '='a' COLLATE RTRIM")).rows, [
      [BigInt.one]
    ]);
    expect((await db.query("SELECT 'a'='A' COLLATE BINARY")).rows, [
      [BigInt.zero]
    ]);
  });
}
