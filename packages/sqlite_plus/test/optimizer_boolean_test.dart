@TestOn('linux')
library;

import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  test('scalar AND OR evaluate required callbacks and errors', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE flags(a INT)');
    await db.execute('INSERT INTO flags VALUES(1),(0),(NULL)');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 7;
    });
    final ro = await SqliteDatabase.openReadOnly(
        ByteImageStorage(db.exportImage()),
        functions: db.functions);
    addTearDown(ro.close);
    for (final query in [db.query, ro.query]) {
      for (final op in ['OR', 'AND']) {
        calls = 0;
        final r =
            await query('SELECT a $op probe() AS v FROM flags ORDER BY rowid');
        expect(
            r.rows,
            op == 'OR'
                ? [
                    [BigInt.one],
                    [BigInt.one],
                    [BigInt.one]
                  ]
                : [
                    [BigInt.one],
                    [BigInt.zero],
                    [null]
                  ]);
        expect(calls, 3);
      }
      calls = 0;
      expect((await query('SELECT 0 AND probe(),1 OR probe()')).rows, [
        [BigInt.zero, BigInt.one]
      ]);
      expect(calls, 0);
    }
    await optimizerOracle('', 'SELECT 1');
    const sql = 'SELECT a OR abs(-9223372036854775808) FROM flags';
    final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
        '/tmp/sqlite-build/sqlite3';
    final native = await Process.run(cli, [
      ':memory:',
      'CREATE TABLE flags(a INT);INSERT INTO flags VALUES(1);$sql;'
    ]);
    expect(native.exitCode, isNot(0));
    await expectLater(db.query(sql), throwsA(isA<SqlException>()));
    await expectLater(ro.query(sql), throwsA(isA<SqlException>()));
  });
  test('predicate jumps preserve scalar subexpressions and NULL behavior',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE flags(a INT)');
    await db.execute('INSERT INTO flags VALUES(1),(0),(NULL)');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (_) {
      calls++;
      return 7;
    });
    for (final pair in <(String, int)>[
      ('SELECT a FROM flags WHERE a OR probe()', 2),
      ('SELECT a FROM flags WHERE a AND probe()', 1),
      ('SELECT a FROM flags WHERE NOT(a AND probe())', 2),
      ('SELECT a FROM flags WHERE (a OR probe())=1', 3),
      ('SELECT CASE WHEN a OR probe() THEN 1 ELSE 0 END FROM flags', 2),
      ('SELECT iif(a AND probe(),1,0) FROM flags', 1),
    ]) {
      calls = 0;
      await db.query(pair.$1);
      expect(calls, pair.$2, reason: pair.$1);
    }
    calls = 0;
    expect(
        (await db.execute('UPDATE flags SET a=a WHERE a AND probe()')).changes,
        1);
    expect(calls, 1);
    const safe =
        'SELECT a FROM flags WHERE a=1 AND (a OR abs(-9223372036854775808))';
    final expected = await optimizerOracle(
        'CREATE TABLE flags(a INT);INSERT INTO flags VALUES(1),(0),(NULL)',
        safe);
    expect((await db.query(safe)).rows, expected);
  });
}
