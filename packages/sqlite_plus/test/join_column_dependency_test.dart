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
}
