import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('unused named window references participate in column dependencies',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INT,b INT)');
    await db.execute('INSERT INTO t VALUES(1,2)');
    await db
        .execute('CREATE VIEW v AS SELECT b FROM t WINDOW w AS(ORDER BY a)');
    await db.execute('ALTER TABLE t RENAME a TO value');
    expect(
        (await db.query("SELECT sql FROM sqlite_schema WHERE name='v'"))
            .rows
            .single
            .single,
        contains('ORDER BY value'));
    final image = db.exportImage();
    await expectLater(
        db.execute('ALTER TABLE t DROP value'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.two]
    ]);
  });

  test('unary dynamic defaults do not execute during schema preparation',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var calls = 0;
    db.functions.registerScalar('peek', 0, (args) => ++calls);
    await db.execute('CREATE TABLE t(a INT DEFAULT(-peek()),b INT)');
    expect(calls, 0);
    await db.execute('CREATE VIEW v AS SELECT b FROM t');
    await db.execute('ALTER TABLE t RENAME b TO value');
    expect(calls, 0);
    final image = db.exportImage();
    await expectLater(db.execute('ALTER TABLE t ADD bad INT DEFAULT(-peek())'),
        throwsA(isA<SqlException>()));
    expect(calls, 0);
    expect(db.exportImage(), image);
    await db.execute('INSERT INTO t DEFAULT VALUES');
    expect(calls, 1);
    expect((await db.query('SELECT a FROM t')).rows, [
      [-BigInt.one]
    ]);
    expect(calls, 1);
  });

  test('column rename resolves views, aliases, fixed CTE names and joins',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a INT,b TEXT,spare INT)');
    await db.execute("INSERT INTO t VALUES(1,2,'one',0),(2,4,'two',0)");
    await db.execute('CREATE TABLE u(id INT,z INT)');
    await db.execute('INSERT INTO u VALUES(1,7)');
    await db.execute('CREATE VIEW plain AS SELECT t.a,t.b FROM t');
    await db.execute('CREATE VIEW fixed(label) AS SELECT a FROM t');
    await db.execute(
        'CREATE VIEW cte AS WITH c(value) AS(SELECT a FROM t) SELECT value FROM c');
    await db
        .execute('CREATE VIEW aliases AS SELECT a AS a,b FROM t ORDER BY a');
    await db.execute(
        'CREATE VIEW correlated AS SELECT x.id,(SELECT count(*) FROM t y WHERE y.a<=x.a) AS n FROM t x');
    await db.execute(
        'CREATE VIEW joined AS SELECT t.a,u.z FROM t JOIN u ON t.id=u.id');
    await db.execute('ALTER TABLE t RENAME a TO value');
    expect((await db.query('SELECT * FROM plain ORDER BY value')).rows, [
      [BigInt.two, 'one'],
      [BigInt.from(4), 'two']
    ]);
    expect((await db.query('SELECT * FROM aliases')).rows, [
      [BigInt.two, 'one'],
      [BigInt.from(4), 'two']
    ]);
    expect((await db.query('SELECT label FROM fixed ORDER BY label')).rows, [
      [BigInt.two],
      [BigInt.from(4)]
    ]);
    expect((await db.query('SELECT * FROM cte ORDER BY value')).rows, [
      [BigInt.two],
      [BigInt.from(4)]
    ]);
    expect((await db.query('SELECT * FROM correlated ORDER BY id')).rows, [
      [BigInt.one, BigInt.one],
      [BigInt.two, BigInt.two]
    ]);
    expect((await db.query('SELECT * FROM joined')).rows, [
      [BigInt.two, BigInt.from(7)]
    ]);
    await db.execute('ALTER TABLE t DROP spare');
    final before = db.exportImage();
    await expectLater(
        db.execute('ALTER TABLE t DROP b'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
  });

  test('column rename rewrites trigger write fields, OLD NEW and EXCLUDED',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,a INT UNIQUE)');
    await db.execute('CREATE TABLE e(id INT,v INT)');
    await db.execute('CREATE TABLE audit(old_value INT,new_value INT)');
    await db.execute(
        'CREATE TRIGGER observe AFTER UPDATE OF a ON t WHEN old.a!=new.a BEGIN INSERT INTO audit VALUES(old.a,new.a); END');
    await db.execute(
        'CREATE TRIGGER route AFTER INSERT ON e BEGIN INSERT INTO t(id,a) VALUES(new.id,new.v) ON CONFLICT(id) DO UPDATE SET a=a+excluded.a; END');
    await db.execute('ALTER TABLE t RENAME a TO value');
    await db.execute('INSERT INTO e VALUES(1,2),(1,3)');
    expect((await db.query('SELECT * FROM t')).rows, [
      [BigInt.one, BigInt.from(5)]
    ]);
    expect((await db.query('SELECT * FROM audit')).rows, [
      [BigInt.two, BigInt.from(5)]
    ]);
    await db.execute('ALTER TABLE t RENAME value TO VALUE');
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    await reopened.execute('INSERT INTO e VALUES(1,1)');
    expect((await reopened.query('SELECT VALUE FROM t')).rows, [
      [BigInt.from(6)]
    ]);
    expect((await reopened.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test(
      'dependent automatic output changes reject while explicit aliases remain',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INT,b INT)');
    await db.execute('INSERT INTO t VALUES(1,2)');
    await db.execute('CREATE VIEW v AS SELECT a FROM t');
    await db.execute('CREATE VIEW w AS SELECT a FROM v');
    final before = db.exportImage();
    await expectLater(db.execute('ALTER TABLE t RENAME a TO value'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute('DROP VIEW w');
    await db.execute('DROP VIEW v');
    await db.execute('CREATE VIEW v AS SELECT a AS a FROM t');
    await db.execute('CREATE VIEW w AS SELECT a FROM v');
    await db.execute('ALTER TABLE t RENAME a TO value');
    expect((await db.query('SELECT * FROM w')).rows, [
      [BigInt.one]
    ]);
    await db.execute('BEGIN');
    await db.execute('ALTER TABLE t RENAME value TO undone');
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT value FROM t')).rows, [
      [BigInt.one]
    ]);
  });

  test('metadata-only preparation preserves quoted fields and skips callbacks',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var calls = 0;
    db.functions.registerScalar('peek', 0, (args) => ++calls);
    await db.execute('CREATE TABLE t("a.b" INT,spare INT)');
    await db.execute('INSERT INTO t VALUES(3,0)');
    await db.execute('CREATE VIEW quoted AS SELECT t."a.b" AS fixed FROM t');
    await db.execute('CREATE VIEW callback AS SELECT peek() AS value FROM t');
    await db.execute('ALTER TABLE t RENAME "a.b" TO "new value"');
    await db.execute('ALTER TABLE t DROP spare');
    expect(calls, 0);
    expect((await db.query('SELECT * FROM quoted')).rows, [
      [BigInt.from(3)]
    ]);
    expect((await db.query('SELECT * FROM callback')).rows, [
      [BigInt.one]
    ]);
  });
}
