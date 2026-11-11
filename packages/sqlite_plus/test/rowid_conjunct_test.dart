import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test(
      'integer rowid conjunction keeps every lease guard and parameter coercion',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,state TEXT,token TEXT,n INTEGER CHECK(n>=0))');
    await db.execute(
        "INSERT INTO t VALUES(1,'running','a',0),(2,'running','b',0),(3,'queued',NULL,0)");
    for (final key in [2, BigInt.two, '2', 2.0]) {
      final r = await db.execute(
          "UPDATE t SET n=n+1 WHERE id=? AND state='running' AND token=? RETURNING id",
          [key, 'b']);
      expect(r.changes, 1);
      expect(r.returning!.rows.single.single, BigInt.two);
    }
    for (final args in [
      [2, 'stale'],
      [3, 'b'],
      [999, 'b'],
      [null, 'b'],
      [2.5, 'b'],
      [
        Uint8List.fromList([50]),
        'b'
      ]
    ]) {
      expect(
          (await db.execute(
                  "UPDATE t SET n=n+1 WHERE state='running' AND ?=id AND token=?",
                  args))
              .changes,
          0);
    }
    expect(
        (await db.execute(
                "UPDATE t SET n=n+1 WHERE id=1 AND id=2 AND token='b'"))
            .changes,
        0);
    expect((await db.query('SELECT n FROM t WHERE id=2')).rows.single.single,
        BigInt.from(4));
    final before = db.exportImage();
    await expectLater(db.execute("UPDATE t SET n=-1 WHERE id=2 AND token='b'"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    expect(
        (await db
                .execute("DELETE FROM t WHERE id=2 AND token='b' RETURNING id"))
            .returning!
            .rows
            .single
            .single,
        BigInt.two);
  });
  test('shadowed rowid names and OR roots never narrow to the wrong row',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,rowid INTEGER,n INTEGER)');
    await db.execute('INSERT INTO t VALUES(1,7,0),(2,7,0),(3,8,0)');
    expect(
        (await db.execute('UPDATE t SET n=n+1 WHERE rowid=7 AND n=0')).changes,
        2);
    expect(
        (await db.execute('UPDATE t SET n=n+1 WHERE id=1 OR n=0')).changes, 2);
    expect(
        (await db.execute(
                'UPDATE t AS x SET n=n+1 WHERE x.id=2 AND (n=1 OR n=2)'))
            .changes,
        1);
    expect((await db.query('SELECT id,n FROM t ORDER BY id')).rows, [
      [BigInt.one, BigInt.two],
      [BigInt.two, BigInt.two],
      [BigInt.from(3), BigInt.one]
    ]);
  });
  test('function-containing predicates retain callback evaluation and failures',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)');
    await db.execute('INSERT INTO t VALUES(1,0),(2,0),(3,0)');
    var visits = 0;
    db.functions.registerScalar('visit', 1, (a) {
      visits++;
      return a.single;
    });
    await db.execute('UPDATE t SET n=1 WHERE visit(id)>0 AND id=2');
    expect(visits, 3);
    db.functions
        .registerScalar('explode', 0, (_) => throw StateError('failure'));
    await expectLater(
        db.execute('UPDATE t SET n=9 WHERE explode()>0 AND id=999'),
        throwsA(isA<Object>()));
    expect((await db.query('SELECT n FROM t WHERE id=2')).rows.single.single,
        BigInt.one);
  });
  test('FK checks, triggers and changed unique keys still apply', () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys=ON');
    await db.execute('CREATE TABLE p(id INTEGER PRIMARY KEY)');
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,pid INTEGER REFERENCES p(id),k TEXT UNIQUE,n INTEGER)');
    await db.execute('CREATE TABLE audit(n INTEGER)');
    await db.execute(
        'CREATE TRIGGER changed AFTER UPDATE ON t BEGIN INSERT INTO audit VALUES(new.n); END');
    await db.execute('INSERT INTO p VALUES(1)');
    await db.execute("INSERT INTO t VALUES(1,1,'a',0),(2,1,'b',0)");
    final before = db.exportImage();
    await expectLater(db.execute('UPDATE t SET pid=99 WHERE id=1 AND n=0'),
        throwsA(isA<SqlException>()));
    await expectLater(db.execute("UPDATE t SET k='b' WHERE id=1 AND n=0"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    expect(
        (await db.execute('UPDATE t SET n=5 WHERE id=2 AND pid=1')).changes, 1);
    expect((await db.query('SELECT n FROM audit')).rows, [
      [BigInt.from(5)]
    ]);
  });
  test('live equality reads include new inserts and discard rolled-back rows',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,k TEXT,n INTEGER CHECK(n>=0))');
    await db.execute("INSERT INTO t VALUES(1,'same',1)");
    expect(
        (await db.query('SELECT id,n FROM t WHERE k=?', ['same'])).rows.length,
        1);
    await db.execute("INSERT INTO t VALUES(2,'same',2) RETURNING id");
    expect(
        (await db.query('SELECT id,n FROM t WHERE k=?', ['same'])).rows.length,
        2);
    await db.execute('BEGIN');
    await db.execute("INSERT INTO t VALUES(3,'same',3) RETURNING id");
    expect(
        (await db.query('SELECT id,n FROM t WHERE k=?', ['same'])).rows.length,
        3);
    await db.execute('ROLLBACK');
    expect(
        (await db.query('SELECT id,n FROM t WHERE k=?', ['same'])).rows.length,
        2);
    await expectLater(
        db.execute("INSERT INTO t VALUES(4,'same',4),(5,'same',-1)"),
        throwsA(isA<SqlException>()));
    expect(
        (await db.query('SELECT id,n FROM t WHERE k=?', ['same'])).rows.length,
        2);
  });
}
