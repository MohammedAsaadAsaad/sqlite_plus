import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test(
      'mixed/repeated targets and row-slot caches survive rollback and other DML',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,sku TEXT COLLATE NOCASE UNIQUE,n INTEGER CHECK(n>=0))');
    await db.execute("INSERT INTO t VALUES(1,'a',1),(2,'b',2)");
    final result = await db.execute(
        "INSERT INTO t VALUES(1,'A',10),(3,'c',30),(3,'C',31),(2,'B',20) ON CONFLICT(sku) DO UPDATE SET n=excluded.n RETURNING id,n");
    expect(result.changes, 4);
    expect(result.returning!.rows, [
      [BigInt.one, BigInt.from(10)],
      [BigInt.from(3), BigInt.from(30)],
      [BigInt.from(3), BigInt.from(31)],
      [BigInt.two, BigInt.from(20)]
    ]);
    await db.execute('DELETE FROM t WHERE id=1');
    await db.execute("INSERT INTO t VALUES(4,'d',40)");
    await db.execute(
        "INSERT INTO t VALUES(2,'b',21),(3,'c',32),(4,'d',41) ON CONFLICT(id) DO UPDATE SET n=excluded.n");
    final before = db.exportImage();
    await expectLater(
        db.execute(
            "INSERT INTO t VALUES(2,'b',22),(5,'e',-1) ON CONFLICT(id) DO UPDATE SET n=excluded.n"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute(
        "INSERT INTO t VALUES(2,'b',23),(5,'e',50) ON CONFLICT(id) DO UPDATE SET n=excluded.n");
    expect((await db.query('SELECT id,n FROM t ORDER BY id')).rows, [
      [BigInt.two, BigInt.from(23)],
      [BigInt.from(3), BigInt.from(32)],
      [BigInt.from(4), BigInt.from(41)],
      [BigInt.from(5), BigInt.from(50)]
    ]);
  });
  test(
      'changed unique keys invalidate conflict lookups; later failure aborts prefix',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,sku TEXT UNIQUE,n INTEGER)');
    await db.execute("INSERT INTO t VALUES(1,'a',1),(2,'b',2)");
    final before = db.exportImage();
    await expectLater(
        db.execute(
            "INSERT INTO t VALUES(1,'a',10),(3,'a2',30) ON CONFLICT(id) DO UPDATE SET sku=sku||'2',n=excluded.n"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute(
        "INSERT INTO t VALUES(1,'a',10),(3,'a',30) ON CONFLICT(id) DO UPDATE SET sku=sku||'2',n=excluded.n");
    expect((await db.query('SELECT id,sku,n FROM t ORDER BY id')).rows, [
      [BigInt.one, 'a2', BigInt.from(10)],
      [BigInt.two, 'b', BigInt.two],
      [BigInt.from(3), 'a', BigInt.from(30)]
    ]);
  });
  test('foreign key violations remain atomic on prepared UPSERT updates',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute('CREATE TABLE p(id INTEGER PRIMARY KEY)');
    await db.execute(
        'CREATE TABLE c(id INTEGER PRIMARY KEY,pid REFERENCES p(id),n INTEGER)');
    await db.execute('INSERT INTO p VALUES(1)');
    await db.execute('INSERT INTO c VALUES(1,1,10)');
    final before = db.exportImage();
    await expectLater(
        db.execute(
            'INSERT INTO c VALUES(1,99,20) ON CONFLICT(id) DO UPDATE SET pid=excluded.pid,n=excluded.n'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
  });
}
