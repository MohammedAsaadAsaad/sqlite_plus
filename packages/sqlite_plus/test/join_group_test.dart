import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(
      File('test/fixtures/join_group_oracle.json').readAsStringSync()) as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final suite in oracle['suites'] as List) {
    final encoding =
        ['UTF-8', 'UTF-16le', 'UTF-16be'].indexOf(suite['encoding'] as String) +
            1;
    test('pinned parenthesized joins encoding $encoding', () async {
      expect(oracle['source_id'], manifest['source_id']);
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      for (final sql in oracle['setup'] as List) {
        await db.execute(sql as String);
      }
      for (final entry in suite['cases'] as List) {
        final sql = entry['sql'] as String;
        if (entry.containsKey('error')) {
          await expectLater(db.query(sql), throwsA(isA<SqlException>()),
              reason: sql);
        } else {
          final result = await db.query(sql);
          expect(result.columns, entry['columns'], reason: sql);
          expect(
              result.rows,
              (entry['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList(),
              reason: sql);
        }
      }
    });
  }

  test('source groups evaluate callbacks once and preserve outer null rows',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var calls = 0;
    db.functions.registerScalar('group_probe', 0, (_) => ++calls);
    final result = await db.query('SELECT d.x FROM '
        '((SELECT group_probe() AS x)d JOIN(VALUES(1))e ON 1)q');
    expect(result.rows, [
      [BigInt.one]
    ]);
    expect(calls, 1);
    calls = 0;
    final unmatched = await db.query('SELECT a.column1,d.x FROM (VALUES(7))a '
        'LEFT JOIN((SELECT group_probe() AS x)d JOIN(VALUES(1))e ON 1)q '
        'ON a.column1=99');
    expect(unmatched.rows, [
      [BigInt.from(7), null]
    ]);
    expect(calls, 1);
  });

  test('source parentheses respect depth and alias visibility boundaries',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x)');
    await db.execute('INSERT INTO t VALUES(7)');
    final valid = '${'(' * 128}t${')' * 128}';
    expect((await db.query('SELECT x FROM $valid')).rows, [
      [BigInt.from(7)]
    ]);
    final invalid = '${'(' * 129}t${')' * 129}';
    await expectLater(
        db.query('SELECT x FROM $invalid'), throwsA(isA<SqlException>()));
    expect((await db.query('SELECT q.x FROM ((t))q')).rows, [
      [BigInt.from(7)]
    ]);
    await expectLater(
        db.query('SELECT t.x FROM ((t))q'), throwsA(isA<SqlException>()));
  });

  test('group ON prepares wildcard subquery widths on empty inputs', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE a(x,y)');
    await db.execute('CREATE TABLE b(x)');
    await db.execute('CREATE TABLE c(x)');
    for (final query in [
      'SELECT a.x FROM a LEFT JOIN(b JOIN c USING(x)) ON (SELECT * FROM a)=1',
      'SELECT a.x FROM(a JOIN b ON (SELECT * FROM a)=1) JOIN c',
      'SELECT a.x FROM a LEFT JOIN(b JOIN c USING(x)) ON (1,2,3)=(SELECT * FROM a)',
    ]) {
      await expectLater(db.query(query), throwsA(isA<SqlException>()),
          reason: query);
    }
  });
}
