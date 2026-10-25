import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('IN table resolves main separately from CTE bindings', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x INT)');
    await db.execute('INSERT INTO t VALUES(1),(2),(NULL)');
    expect((await db.query('SELECT ? IN main.t,3 IN t,3 NOT IN t', [1])).rows, [
      [BigInt.one, null, null]
    ]);
    expect(
        (await db.query('WITH t(x) AS(VALUES(9)) '
                'SELECT 1 IN t,1 IN main.t,9 IN t'))
            .rows,
        [
          [BigInt.zero, BigInt.one, BigInt.one]
        ]);
    await db.execute('CREATE TABLE pairs(a INT,b TEXT COLLATE NOCASE)');
    await db.execute("INSERT INTO pairs VALUES(1,'A')");
    expect((await db.query("SELECT ('1','a') IN main.pairs")).rows, [
      [BigInt.one]
    ]);
    await expectLater(
        db.query('SELECT 1 IN pairs'), throwsA(isA<SqlException>()));
    await expectLater(
        db.query('SELECT 1 IN other.t'), throwsA(isA<SqlException>()));
  });

  test('IN table view dependencies preserve table and field alterations',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x INT)');
    await db.execute('INSERT INTO t VALUES(1),(2)');
    await db.execute('CREATE VIEW v AS SELECT 1 IN main.t AS found');
    await db.execute('ALTER TABLE t RENAME x TO value');
    final image = db.exportImage();
    await expectLater(db.execute('ALTER TABLE t RENAME TO "space name"'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    await db.execute('DROP VIEW v');
    await db.execute('ALTER TABLE t RENAME TO "space name"');
    await db.execute('CREATE VIEW v AS SELECT 1 IN "space name" AS found');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.one]
    ]);
    await db.execute('DELETE FROM "space name" WHERE value IN "space name"');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.zero]
    ]);
  });
}
