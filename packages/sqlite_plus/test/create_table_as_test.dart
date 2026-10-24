import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('CREATE TABLE AS copies rows and affinities without constraints',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute(
        "CREATE TABLE source(id INTEGER PRIMARY KEY,t VARCHAR(20) NOT NULL DEFAULT 'a',r REAL,n NUMERIC,b BLOB,g INT AS(id+1))");
    await db.execute(
        "INSERT INTO source(id,t,r,n,b) VALUES(1,'λ😀',2,3,X'00ff'),(2,'B',3.5,4,NULL)");
    final result = await db.execute(
        'CREATE TABLE copied AS SELECT id,t,r,n,b,g FROM source ORDER BY id DESC');
    expect(result.changes, 0);
    expect(result.lastInsertRowid, isNull);
    expect((await db.query('SELECT id,g FROM copied ORDER BY rowid')).rows, [
      [BigInt.two, BigInt.from(3)],
      [BigInt.one, BigInt.two]
    ]);
    final info = (await db.query('PRAGMA table_info(copied)')).rows;
    expect(info.map((r) => r[2]), ['INT', 'TEXT', 'REAL', 'NUM', '', 'INT']);
    expect(
        info.every(
            (r) => r[3] == BigInt.zero && r[4] == null && r[5] == BigInt.zero),
        isTrue);
    await db.execute('INSERT INTO copied(id,g) VALUES(1,99)');
    await db.execute('CREATE TABLE empty AS SELECT * FROM source LIMIT 0');
    expect((await db.query('PRAGMA table_info(empty)')).rows.map((r) => r[2]),
        ['INT', 'TEXT', 'REAL', 'NUM', '', 'INT']);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    expect((await reopened.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('CREATE TABLE AS parameters, duplicate names and failures are atomic',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE params AS SELECT ? AS x,CAST(? AS REAL) AS r', [1, 2]);
    expect((await db.query('SELECT * FROM params')).rows, [
      [BigInt.one, 2.0]
    ]);
    await db.execute(
        "CREATE TABLE duplicate AS SELECT 1 AS x,2 AS X,3 AS 'x:1',4 AS ''");
    expect(
        (await db.query('PRAGMA table_info(duplicate)')).rows.map((r) => r[1]),
        ['x', 'X:1', 'x:2', '']);
    final image = db.exportImage();
    await expectLater(
        db.execute('CREATE TABLE bad AS SELECT abs(-9223372036854775808)'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    await expectLater(db.execute('CREATE TABLE bad AS SELECT ?', []),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    await db.execute('BEGIN');
    await db.execute('CREATE TABLE undone AS VALUES(1),(2)');
    await db.execute('ROLLBACK');
    expect(db.exportImage(), image);
  });

  test('REPLACE shorthand shares conflict, UPSERT and trigger behavior',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v INT UNIQUE)');
    await db.execute('REPLACE INTO t VALUES(1,1),(2,2)');
    final result = await db.execute('REPLACE INTO t VALUES(3,2) RETURNING *');
    expect(result.changes, 1);
    expect(result.returning!.rows, [
      [BigInt.from(3), BigInt.two]
    ]);
    await db.execute(
        'REPLACE INTO t VALUES(1,3) ON CONFLICT(id) DO UPDATE SET v=excluded.v');
    await db.execute(
        'CREATE TRIGGER tr AFTER INSERT ON t WHEN new.id=4 BEGIN REPLACE INTO t VALUES(1,new.v+10); END');
    await db.execute('REPLACE INTO t VALUES(4,4)');
    expect((await db.query('SELECT v FROM t WHERE id=1')).rows, [
      [BigInt.from(14)]
    ]);
  });
}
