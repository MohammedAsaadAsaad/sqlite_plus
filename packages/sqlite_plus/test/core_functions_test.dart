import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final cases = jsonDecode(
          File('test/fixtures/core_function_oracle.json').readAsStringSync())
      as List;
  for (final encoding in [1, 2, 3]) {
    group('core scalars pinned encoding $encoding', () {
      late MutableSqliteDatabase db;
      setUpAll(() async {
        db = await MutableSqliteDatabase.create(encoding: encoding);
        await db.execute('CREATE TABLE t(a INTEGER,b TEXT COLLATE NOCASE)');
        await db.execute("INSERT INTO t VALUES(1,'a')");
      });
      tearDownAll(() => db.close());
      for (final (index, entry)
          in cases.where((entry) => entry['encoding'] == encoding).indexed) {
        final sql = entry['sql'] as String;
        final label = sql.length > 160 ? '${sql.substring(0, 160)}…' : sql;
        test('${index + 1}: $label', () async {
          final parameters =
              (entry['parameters'] as List).map(expectedValue).toList();
          if (entry.containsKey('error')) {
            await expectLater(
                db.query(sql, parameters), throwsA(isA<SqlException>()));
          } else {
            expect(
                (await db.query(sql, parameters)).rows,
                (entry['rows'] as List)
                    .map((row) => (row as List).map(expectedValue).toList())
                    .toList());
          }
        });
      }
    });
  }

  test('random values are signed integers excluding the ABS overflow value',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final values = (await db.query('''
      WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<256)
      SELECT random(),randomblob(32) FROM n
      ''')).rows;
    final minimum = -(BigInt.one << 63);
    final maximum = (BigInt.one << 63) - BigInt.one;
    for (final row in values) {
      expect(row[0], isA<BigInt>());
      expect(row[0] as BigInt, greaterThan(minimum));
      expect(row[0] as BigInt, lessThanOrEqualTo(maximum));
      expect(row[1], isA<Uint8List>());
      expect((row[1] as Uint8List).length, 32);
    }
    expect(values.map((row) => row[0]).toSet().length, 256);
    expect(values.map((row) => (row[1] as Uint8List).join(',')).toSet().length,
        256);
    final first = values.first[1] as Uint8List;
    final second = values[1][1] as Uint8List;
    final copy = Uint8List.fromList(second);
    first.fillRange(0, first.length, 0);
    expect(second, copy);
  });

  test('random functions reject deterministic schema use before mutation',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x)');
    for (final function in ['random()', 'randomblob(2)']) {
      final before = db.exportImage();
      for (final sql in [
        'CREATE INDEX invalid ON t($function)',
        'CREATE INDEX invalid ON t(x) WHERE $function IS NOT NULL',
        'CREATE TABLE invalid(x,y GENERATED ALWAYS AS ($function))'
      ]) {
        await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
        expect(db.exportImage(), before);
      }
    }
    await db.execute('CREATE TABLE defaults(x DEFAULT(random()))');
    await db.execute('INSERT INTO defaults DEFAULT VALUES');
    expect((await db.query('SELECT typeof(x) FROM defaults')).rows, [
      ['integer']
    ]);
  });

  test('function output limits include the exact randomblob boundary',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const maximum = 16 * 1024 * 1024;
    expect((await db.query('SELECT length(randomblob($maximum))')).rows, [
      [BigInt.from(maximum)]
    ]);
    for (final count in [maximum + 1, 9223372036854775807]) {
      await expectLater(db.query('SELECT randomblob(?)', [count]),
          throwsA(isA<SqlException>()));
    }
  });

  test('UNISTR rejects malformed Unicode rather than creating malformed text',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final escape in [
      r'\D800',
      r'\uDFFF',
      r'\U00110000',
      r'\+110000',
      r'\UFFFFFFFF',
      r'\uD83D\uDE00'
    ]) {
      await expectLater(
          db.query('SELECT unistr(?)', [escape]), throwsA(isA<SqlException>()));
    }
  });

  test('UNISTR_QUOTE expressions roundtrip valid text and escape controls',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final value in [
      '',
      r'back\slash',
      "apostrophe'",
      '\n\t\r${String.fromCharCode(31)}',
      "λ😀\\'\n"
    ]) {
      final expression = (await db.query('SELECT unistr_quote(?)', [value]))
          .rows
          .single
          .single;
      expect((await db.query('SELECT $expression')).rows, [
        [value]
      ]);
    }
  });

  test('integer scalar arguments bound large digit inputs and ignore exponents',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    expect(
        (await db.query('SELECT char(?),char(?),char(?),substr(?, ?, ?)', [
          '0' * 100000 + '65e1',
          '9' * 100000,
          '-${'9' * 100000}',
          'abcdef',
          '\t\n\r\u000b\u000c +2e2',
          '3e2'
        ]))
            .rows,
        [
          ['A', '\ufffd', '\ufffd', 'bcd']
        ]);
  });
}
