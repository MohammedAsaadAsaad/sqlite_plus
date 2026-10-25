import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  setUp(() async {
    db = await MutableSqliteDatabase.create();
    await db.execute('CREATE TABLE t(a,b)');
    await db.execute('CREATE TABLE empty(x)');
  });
  tearDown(() => db.close());

  test('wildcard subquery width rejects before empty input or LIMIT zero',
      () async {
    for (final sql in [
      'SELECT (SELECT * FROM t) FROM empty',
      'SELECT (1,2,3)=(SELECT * FROM t) FROM empty',
      'SELECT (1,2) IN (SELECT * FROM empty) FROM empty',
      'SELECT CASE (SELECT * FROM t) WHEN (1,2,3) THEN 0 END FROM empty',
      'SELECT 1 FROM empty WHERE (SELECT * FROM t)=1',
      'SELECT (SELECT * FROM t WHERE 0) FROM empty LIMIT 0',
      'SELECT (SELECT * FROM t) FROM empty GROUP BY x',
      'SELECT 1 FROM empty ORDER BY (SELECT * FROM t)',
    ]) {
      await expectLater(db.query(sql), throwsA(isA<SqlException>()),
          reason: sql);
    }
  });

  test('matching row widths and EXISTS accept empty input', () async {
    for (final sql in [
      'SELECT (1,2)=(SELECT * FROM t) FROM empty',
      'SELECT EXISTS(SELECT * FROM t) FROM empty',
      'SELECT (1,2) IN (SELECT * FROM t) FROM empty',
      'SELECT (1,2) IN () FROM empty',
    ]) {
      expect((await db.query(sql)).rows, isEmpty, reason: sql);
    }
  });

  test('nested derived, view and CTE wildcard widths are prepared', () async {
    await db.execute('CREATE VIEW v AS SELECT * FROM t');
    for (final sql in [
      'SELECT (SELECT * FROM (SELECT * FROM t)) FROM empty',
      'SELECT (SELECT * FROM v) FROM empty',
      'WITH q AS(SELECT * FROM t) SELECT (SELECT * FROM q) FROM empty',
      'SELECT (SELECT 1 WHERE (SELECT * FROM t)=1) FROM empty',
    ]) {
      await expectLater(db.query(sql), throwsA(isA<SqlException>()),
          reason: sql);
    }
    expect(
        (await db.query('WITH q AS(SELECT * FROM t) '
                'SELECT (1,2) IN (SELECT * FROM q) FROM empty'))
            .rows,
        isEmpty);
  });

  test('shape preparation never calls projection functions', () async {
    var calls = 0;
    db.functions.registerScalar('counted', 0, (args) => ++calls);
    const subquery = '(SELECT * FROM '
        '(SELECT counted() AS a,counted() AS b))';
    await expectLater(
        db.query('SELECT $subquery FROM empty'), throwsA(isA<SqlException>()));
    expect(calls, 0);
    expect((await db.query('SELECT (1,2)=$subquery FROM empty')).rows, isEmpty);
    expect(calls, 0);
  });
}
