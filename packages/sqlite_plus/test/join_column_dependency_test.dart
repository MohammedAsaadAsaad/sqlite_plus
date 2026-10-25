import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('NATURAL column rewrite follows LEFT RIGHT and FULL merged origins',
      () async {
    for (final scenario in [
      ('', 't', 'renamed', [1, 1, 2, 2]),
      ('LEFT', 't', 'renamed', [1, 1, 2, 2]),
      ('RIGHT', 't', 'a', [1, 1, 3, 3]),
      ('FULL', 't', 'a', [1, 1, 3, 3]),
      ('', 'u', 'a', [1, 1, 2, 2]),
      ('LEFT', 'u', 'a', [1, 1, 2, 2]),
      ('RIGHT', 'u', 'renamed', [1, 1, 3, 3]),
      ('FULL', 'u', 'a', [1, 1, 2, 2]),
    ]) {
      final db = await MutableSqliteDatabase.create();
      try {
        await db.execute('CREATE TABLE t(a INT,l TEXT)');
        await db.execute('CREATE TABLE u(a INT,r TEXT)');
        await db.execute("INSERT INTO t VALUES(1,'t1'),(2,'t2')");
        await db.execute("INSERT INTO u VALUES(1,'u1'),(3,'u3')");
        await db.execute(
            'CREATE VIEW v AS SELECT a FROM t NATURAL ${scenario.$1} JOIN u');
        await db.execute('ALTER TABLE ${scenario.$2} RENAME a TO renamed');
        final result = await db.query('SELECT * FROM v ORDER BY 1');
        expect(result.columns, [scenario.$3], reason: '$scenario');
        expect(result.rows, scenario.$4.map((n) => [BigInt.from(n)]).toList(),
            reason: '$scenario');
      } finally {
        await db.close();
      }
    }
  });

  test('USING key and FULL self-join failures preserve the complete image',
      () async {
    for (final source in [
      't JOIN u USING(a)',
      't LEFT JOIN u USING(a)',
      't RIGHT JOIN u USING(a)',
      't x JOIN t y USING(a)',
      't x NATURAL FULL JOIN t y'
    ]) {
      final db = await MutableSqliteDatabase.create();
      try {
        await db.execute('CREATE TABLE t(a INT,l INT)');
        await db.execute('CREATE TABLE u(a INT,r INT)');
        await db.execute('CREATE VIEW v AS SELECT a FROM $source');
        final image = db.exportImage();
        await expectLater(db.execute('ALTER TABLE t RENAME a TO renamed'),
            throwsA(isA<SqlException>()));
        expect(db.exportImage(), image, reason: source);
      } finally {
        await db.close();
      }
    }
  });

  test(
      'unrelated ALTER fields and explicit rowid columns resolve through joins',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INT,spare INT)');
    await db.execute('CREATE TABLE u(a INT,rowid INT)');
    await db.execute('INSERT INTO t VALUES(1,0)');
    await db.execute('INSERT INTO u VALUES(1,7)');
    await db.execute('CREATE VIEW v AS SELECT a,rowid FROM t NATURAL JOIN u');
    await db.execute('ALTER TABLE t RENAME spare TO unused');
    await db.execute('ALTER TABLE t DROP unused');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.one, BigInt.from(7)]
    ]);
  });

  test('independent duplicate columns remain ambiguous during ALTER', () async {
    for (final source in [
      't JOIN u USING(a),w',
      't NATURAL JOIN u JOIN w ON t.a=w.a',
      't FULL JOIN u USING(a) CROSS JOIN w',
      't,u JOIN w USING(a)',
      't,u FULL JOIN w USING(a)',
    ]) {
      final db = await MutableSqliteDatabase.create();
      try {
        await db.execute('CREATE TABLE t(a,spare)');
        await db.execute('CREATE TABLE u(a)');
        await db.execute('CREATE TABLE w(a)');
        await db.execute('CREATE VIEW v AS SELECT a FROM $source');
        final image = db.exportImage();
        await expectLater(db.execute('ALTER TABLE t RENAME spare TO other'),
            throwsA(isA<SqlException>()),
            reason: source);
        expect(db.exportImage(), image, reason: source);
        await expectLater(db.execute('ALTER TABLE t DROP spare'),
            throwsA(isA<SqlException>()),
            reason: source);
        expect(db.exportImage(), image, reason: source);
      } finally {
        await db.close();
      }
    }
  });

  test('qualified fields survive independent join groups during ALTER',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a,spare)');
    await db.execute('CREATE TABLE u(a)');
    await db.execute('CREATE TABLE w(a)');
    await db.execute('INSERT INTO t VALUES(1,7)');
    await db.execute('INSERT INTO u VALUES(1)');
    await db.execute('INSERT INTO w VALUES(2)');
    await db
        .execute('CREATE VIEW v AS SELECT t.spare FROM t JOIN u USING(a),w');
    await db.execute('ALTER TABLE t RENAME spare TO other');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.from(7)]
    ]);
  });

  test('inferred and declared CTE duplicate names resolve during ALTER',
      () async {
    for (final declaration in ['', '(z,z)']) {
      final db = await MutableSqliteDatabase.create();
      try {
        await db.execute('CREATE TABLE t(a,spare)');
        await db.execute('INSERT INTO t VALUES(1,7)');
        await db.execute('CREATE VIEW v AS WITH q$declaration AS '
            '(SELECT a AS z,spare AS z FROM t) SELECT "z:1" FROM q');
        await db.execute('ALTER TABLE t RENAME spare TO other');
        expect((await db.query('SELECT * FROM v')).rows, [
          [BigInt.from(7)]
        ]);
        final image = db.exportImage();
        await expectLater(db.execute('ALTER TABLE t DROP other'),
            throwsA(isA<SqlException>()));
        expect(db.exportImage(), image);
      } finally {
        await db.close();
      }
    }
  });

  test('main sources bypass CTE shadows during table and column ALTER',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a,spare)');
    await db.execute('INSERT INTO t VALUES(1,7)');
    await db.execute('CREATE VIEW v AS WITH t AS(SELECT 99 AS a) '
        'SELECT main.t.a AS fixed FROM main.t');
    await db
        .execute('CREATE VIEW aliased AS SELECT main.q.a AS fixed FROM t q');
    await db.execute('ALTER TABLE t RENAME a TO value');
    for (final view in ['v', 'aliased']) {
      expect((await db.query('SELECT * FROM $view')).rows, [
        [BigInt.one]
      ]);
    }
    await db.execute('ALTER TABLE t RENAME TO renamed');
    for (final view in ['v', 'aliased']) {
      expect((await db.query('SELECT * FROM $view')).rows, [
        [BigInt.one]
      ]);
    }
    await db.execute('ALTER TABLE renamed DROP spare');
    final image = db.exportImage();
    await expectLater(db.execute('ALTER TABLE renamed DROP value'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
  });

  test('dependent JOIN ON output aliases retain field bindings through ALTER',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a,spare)');
    await db.execute('CREATE TABLE u(b)');
    await db.execute('INSERT INTO t VALUES(1,0),(3,0)');
    await db.execute('INSERT INTO u VALUES(2),(9)');
    await db
        .execute('CREATE VIEW v AS SELECT a+1 AS next FROM t JOIN u ON next=b');
    await db.execute('ALTER TABLE t RENAME a TO value');
    await db.execute('ALTER TABLE t DROP spare');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.two]
    ]);
    await db.execute('CREATE VIEW invalid_on AS SELECT sum(value) AS total '
        'FROM t JOIN u ON total=b');
    // Schema rewriting resolves names without executing or validating aggregate
    // placement in a stored view; querying the invalid view still rejects.
    await db.execute('ALTER TABLE t RENAME value TO renamed');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.two]
    ]);
    await expectLater(
        db.query('SELECT * FROM invalid_on'), throwsA(isA<SqlException>()));
  });
}
