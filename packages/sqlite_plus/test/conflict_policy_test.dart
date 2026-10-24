import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('duplicate key policies and ignored replacement deletes match SQLite',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a UNIQUE,UNIQUE(a) ON CONFLICT IGNORE)');
    expect((await db.execute('INSERT INTO t VALUES(1),(1)')).changes, 1);
    await expectLater(
        db.execute(
            'CREATE TABLE bad(a UNIQUE ON CONFLICT FAIL,UNIQUE(a) ON CONFLICT IGNORE)'),
        throwsA(isA<SqlException>()));
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute(
        "CREATE TRIGGER skip BEFORE DELETE ON t BEGIN SELECT RAISE(IGNORE); END");
    final image = db.exportImage();
    await expectLater(db.execute('INSERT OR REPLACE INTO t VALUES(1),(2)'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    await db.execute('DROP TRIGGER skip');
    await db.execute(
        "CREATE TRIGGER skip AFTER DELETE ON t BEGIN SELECT RAISE(IGNORE); END");
    expect((await db.execute('INSERT OR REPLACE INTO t VALUES(1),(2)')).changes,
        2);
  });

  test('schema defaults resolve per constraint and explicit OR overrides them',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY ON CONFLICT REPLACE, '
        'a INT UNIQUE ON CONFLICT IGNORE,b INT NOT NULL ON CONFLICT REPLACE DEFAULT 7)');
    final result = await db
        .execute('INSERT INTO t VALUES(1,1,NULL),(2,1,2),(3,3,3) RETURNING *');
    expect(result.returning!.rows, [
      [BigInt.one, BigInt.one, BigInt.from(7)],
      [BigInt.from(3), BigInt.from(3), BigInt.from(3)]
    ]);
    await db.execute('INSERT INTO t VALUES(1,4,4)');
    final image = db.exportImage();
    await expectLater(db.execute('INSERT OR ABORT INTO t VALUES(5,3,5)'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    await db.execute('INSERT OR REPLACE INTO t VALUES(5,3,NULL)');
    expect((await db.query('SELECT id,a,b FROM t ORDER BY id')).rows, [
      [BigInt.one, BigInt.from(4), BigInt.from(4)],
      [BigInt.from(5), BigInt.from(3), BigInt.from(7)]
    ]);
  });

  test('REPLACE delete triggers require recursive_triggers and preserve counts',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY ON CONFLICT REPLACE,v INT UNIQUE)');
    await db.execute('CREATE TABLE audit(kind TEXT,id INT)');
    await db.execute(
        "CREATE TRIGGER before_delete BEFORE DELETE ON t BEGIN INSERT INTO audit VALUES('before',old.id); END");
    await db.execute(
        "CREATE TRIGGER after_delete AFTER DELETE ON t BEGIN INSERT INTO audit VALUES('after',old.id); END");
    await db.execute('INSERT INTO t VALUES(1,1)');
    await db.execute('INSERT INTO t VALUES(1,2)');
    expect((await db.query('SELECT * FROM audit')).rows, isEmpty);
    await db.execute('PRAGMA recursive_triggers=ON');
    final result = await db.execute('INSERT INTO t VALUES(1,3) RETURNING *');
    expect(result.changes, 1);
    expect((await db.query('SELECT * FROM audit')).rows, [
      ['before', BigInt.one],
      ['after', BigInt.one]
    ]);
    await db.execute(
        "CREATE TRIGGER stop BEFORE DELETE ON t BEGIN SELECT RAISE(ABORT,'stop'); END");
    final image = db.exportImage();
    await expectLater(db.execute('INSERT OR REPLACE INTO t VALUES(1,4)'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
  });

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
