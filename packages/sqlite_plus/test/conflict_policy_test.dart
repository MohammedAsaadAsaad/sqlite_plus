import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test(
      'explicit outer policies override trigger bodies and UPSERT updates abort',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE source(x UNIQUE)');
    await db.execute('CREATE TABLE target(x UNIQUE)');
    await db.execute('INSERT INTO target VALUES(1)');
    await db.execute('CREATE TRIGGER ins AFTER INSERT ON source BEGIN '
        'INSERT OR REPLACE INTO target VALUES(new.x); END');
    await db.execute('INSERT OR IGNORE INTO source VALUES(1),(2)');
    expect((await db.query('SELECT x FROM source ORDER BY x')).rows, [
      [BigInt.one],
      [BigInt.two]
    ]);
    await db.execute('CREATE TRIGGER upd AFTER UPDATE ON source BEGIN '
        'INSERT OR REPLACE INTO target VALUES(1); END');
    final image = db.exportImage();
    await expectLater(
        db.execute('INSERT OR IGNORE INTO source VALUES(1) '
            'ON CONFLICT(x) DO UPDATE SET x=excluded.x'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
  });

  test('FAIL retains earlier rows; ROLLBACK restores the owning transaction',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INT UNIQUE,v INT NOT NULL CHECK(v>0))');
    await expectLater(
        db.execute('INSERT OR FAIL INTO t VALUES(1,1),(2,NULL),(3,3)'),
        throwsA(isA<SqlException>()));
    expect((await db.query('SELECT * FROM t')).rows, [
      [BigInt.one, BigInt.one]
    ]);
    await db.execute('BEGIN');
    await db.execute('INSERT INTO t VALUES(4,4)');
    await db.execute('SAVEPOINT s');
    await expectLater(db.execute('INSERT OR ROLLBACK INTO t VALUES(5,5),(1,2)'),
        throwsA(isA<SqlException>()));
    expect(db.inTransaction, isFalse);
    expect((await db.query('SELECT * FROM t')).rows, [
      [BigInt.one, BigInt.one]
    ]);
    await expectLater(db.execute('RELEASE s'), throwsA(isA<SqlException>()));
  });

  test('UPSERT honors outer row policies but DO UPDATE always aborts',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INT UNIQUE,v INT NOT NULL DEFAULT 7 CHECK(v>0)) STRICT');
    await db.execute('INSERT INTO t VALUES(1,1)');
    final result =
        await db.execute('INSERT OR REPLACE INTO t VALUES(1,NULL),(2,NULL) '
            'ON CONFLICT(id) DO UPDATE SET v=excluded.v RETURNING *');
    expect(result.changes, 2);
    expect(result.returning!.rows, [
      [BigInt.one, BigInt.from(7)],
      [BigInt.two, BigInt.from(7)]
    ]);
    final image = db.exportImage();
    for (final policy in ['IGNORE', 'REPLACE', 'FAIL', 'ROLLBACK']) {
      await expectLater(
          db.execute('INSERT OR $policy INTO t VALUES(3,3),(1,1) '
              'ON CONFLICT(id) DO UPDATE SET v=NULL'),
          throwsA(isA<SqlException>()));
      expect(db.exportImage(), image);
    }
    final ignored =
        await db.execute('INSERT OR IGNORE INTO t VALUES(3,NULL),(4,4) '
            'ON CONFLICT(id) DO NOTHING RETURNING id');
    expect(ignored.returning!.rows, [
      [BigInt.from(4)]
    ]);
  });

  test('STRICT datatype errors override IGNORE and FAIL', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x INT) STRICT');
    final image = db.exportImage();
    for (final policy in ['IGNORE', 'FAIL', 'REPLACE', 'ROLLBACK']) {
      await expectLater(
          db.execute("INSERT OR $policy INTO t VALUES(1),('bad')"),
          throwsA(isA<SqlException>()));
      expect(db.exportImage(), image);
    }
    await db.execute('INSERT INTO t VALUES(1),(2)');
    for (final policy in ['IGNORE', 'FAIL']) {
      final before = db.exportImage();
      await expectLater(db.execute("UPDATE OR $policy t SET x='bad'"),
          throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
  });
}
