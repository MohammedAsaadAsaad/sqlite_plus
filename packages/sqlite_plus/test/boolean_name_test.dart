import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(
      File('test/fixtures/boolean_name_oracle.json').readAsStringSync()) as Map;
  for (final encoding in [1, 2, 3]) {
    group('boolean fallback names encoding $encoding', () {
      late MutableSqliteDatabase db;
      var calls = 0;
      setUpAll(() async {
        db = await MutableSqliteDatabase.create(encoding: encoding);
        db.functions.registerScalar('tick', 0, (_) => ++calls);
        for (final sql in oracle['setup'] as List) {
          await db.execute(sql as String);
        }
      });
      tearDownAll(() => db.close());
      for (final entry in oracle['cases'] as List) {
        test(entry['sql'] as String, () async {
          calls = 0;
          if (entry.containsKey('error')) {
            await expectLater(
                db.query(entry['sql'] as String), throwsA(isA<SqlException>()));
          } else {
            final result = await db.query(entry['sql'] as String);
            expect(result.columns, entry['columns']);
            expect(
                result.rows,
                (entry['rows'] as List)
                    .map((row) => (row as List).map(expectedValue).toList())
                    .toList());
          }
          if (entry.containsKey('calls')) expect(calls, entry['calls']);
        });
      }
    });
  }
  test(
      'boolean defaults, generated values, checks and indexes preserve binding',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db
        .execute('CREATE TABLE t(x DEFAULT TRUE,y AS(FALSE),z CHECK(TRUE))');
    await db.execute('CREATE UNIQUE INDEX one_row ON t(TRUE) WHERE TRUE');
    await db.execute('INSERT INTO t(z)VALUES(8)');
    expect((await db.query('SELECT * FROM t')).rows, [
      [BigInt.one, BigInt.zero, BigInt.from(8)]
    ]);
    await expectLater(db.query('SELECT * FROM t INDEXED BY one_row'),
        throwsA(isA<SqlException>()));
    await expectLater(
        db.execute('INSERT INTO t(z)VALUES(9)'), throwsA(isA<SqlException>()));
    await db
        .execute('CREATE TABLE flags("true" INT CHECK(true>0),v AS(true+1))');
    await db.execute('CREATE UNIQUE INDEX true_key ON flags(true)');
    await db.execute('INSERT INTO flags(true)VALUES(2)');
    expect((await db.query('SELECT true,v FROM flags')).rows, [
      [BigInt.two, BigInt.from(3)]
    ]);
    await expectLater(db.execute('INSERT INTO flags(true)VALUES(0)'),
        throwsA(isA<SqlException>()));
    await db.execute('CREATE VIEW tv AS SELECT true,v FROM flags');
    await db.execute('ALTER TABLE flags RENAME COLUMN true TO truth');
    expect((await db.query('SELECT truth,v FROM tv')).rows, [
      [BigInt.two, BigInt.from(3)]
    ]);
    await expectLater(db.execute('CREATE TABLE cycle(x,true AS(true))'),
        throwsA(isA<SqlException>()));
  });
}
