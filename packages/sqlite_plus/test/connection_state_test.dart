import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

const _state = 'SELECT changes(),total_changes(),last_insert_rowid()';

void main() {
  final cases = jsonDecode(
          File('test/fixtures/connection_state_oracle.json').readAsStringSync())
      as List;
  for (final entry in cases) {
    test('${entry['name']}, encoding ${entry['encoding']}', () async {
      final db = await MutableSqliteDatabase.create(
          encoding: entry['encoding'] as int);
      addTearDown(db.close);
      expect((await db.query(_state)).rows.single,
          [BigInt.zero, BigInt.zero, BigInt.zero]);
      for (final step in entry['steps'] as List) {
        final sql = step['sql'] as String;
        Future<List<List<Object?>>> execute() async => step['kind'] == 'query'
            ? (await db.query(sql)).rows
            : (await db.execute(sql)).returning?.rows ?? [];
        if (step.containsKey('error')) {
          await expectLater(execute(), throwsA(isA<SqlException>()),
              reason: sql);
        } else {
          expect(
              await execute(),
              (step['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList(),
              reason: sql);
        }
        expect((await db.query(_state)).rows.single,
            (step['state'] as List).map(expectedValue).toList(),
            reason: 'counters after $sql');
      }
    });
  }

  test('connection counters are isolated and public function overrides work',
      () async {
    final first = await MutableSqliteDatabase.create();
    final second = await MutableSqliteDatabase.create();
    addTearDown(first.close);
    addTearDown(second.close);
    await first.execute('CREATE TABLE t(id INTEGER PRIMARY KEY)');
    await first.execute('INSERT INTO t VALUES(42)');
    expect((await first.query(_state)).rows.single,
        [BigInt.one, BigInt.one, BigInt.from(42)]);
    expect((await second.query(_state)).rows.single,
        [BigInt.zero, BigInt.zero, BigInt.zero]);
    first.functions.registerScalar('changes', 0, (_) => 999);
    expect((await first.query('SELECT changes()')).rows.single.single,
        BigInt.from(999));
    await first.execute('INSERT INTO t VALUES(43),(44)');
    first.functions.unregister('changes', 0);
    expect((await first.query(_state)).rows.single,
        [BigInt.two, BigInt.from(3), BigInt.from(44)]);
  });

  test('counter functions reject nondeterministic schema use', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x)');
    for (final function in ['changes', 'total_changes', 'last_insert_rowid']) {
      await expectLater(db.execute('CREATE INDEX idx ON t($function())'),
          throwsA(isA<SqlException>()));
      await expectLater(db.execute('CREATE TABLE invalid(x,y AS($function()))'),
          throwsA(isA<SqlException>()));
    }
  });
}
