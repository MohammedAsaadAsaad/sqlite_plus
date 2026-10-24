import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('header PRAGMAs persist and roll back with the transaction', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('PRAGMA user_version=7');
    await db.execute('PRAGMA application_id=-1');
    expect((await db.query('PRAGMA user_version')).rows, [
      [BigInt.from(7)]
    ]);
    expect((await db.query('PRAGMA application_id')).rows, [
      [-BigInt.one]
    ]);
    await db.execute('BEGIN');
    await db.execute('PRAGMA user_version=8');
    await db.execute('ROLLBACK');
    expect((await db.query('PRAGMA user_version')).rows, [
      [BigInt.from(7)]
    ]);
    await db.execute('PRAGMA user_version=2147483648');
    expect((await db.query('PRAGMA user_version')).rows, [
      [BigInt.zero]
    ]);
  });
  test('trigger IGNORE skips one row and preserves preceding trigger effects',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x INT)');
    await db.execute('CREATE TABLE audit(x INT)');
    await db.execute(
        'CREATE TRIGGER guard BEFORE INSERT ON t WHEN new.x=2 BEGIN INSERT INTO audit VALUES(new.x); SELECT RAISE(IGNORE); END');
    expect((await db.execute('INSERT INTO t VALUES(1),(2),(3)')).changes, 2);
    expect((await db.query('SELECT x FROM t ORDER BY x')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
    expect((await db.query('SELECT x FROM audit')).rows, [
      [BigInt.two]
    ]);
    await db.execute(
        'CREATE TRIGGER update_guard BEFORE UPDATE ON t BEGIN SELECT RAISE(IGNORE); END');
    expect((await db.execute('UPDATE t SET x=9')).changes, 0);
    expect((await db.query('SELECT x FROM t ORDER BY x')).rows, [
      [BigInt.one],
      [BigInt.from(3)]
    ]);
  });
  test(
      'foreign keys require unique parents and REPLACE performs delete actions',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys=1');
    await db.execute('CREATE TABLE p(id INT)');
    await db.execute('INSERT INTO p VALUES(1)');
    await db.execute('CREATE TABLE c(pid INT REFERENCES p(id))');
    await expectLater(
        db.execute('INSERT INTO c VALUES(1)'), throwsA(isA<SqlException>()));
    await db.execute('CREATE UNIQUE INDEX p_id ON p(id)');
    await db.execute('INSERT INTO c VALUES(1)');
    await db.execute('DROP TABLE c');
    await db
        .execute('CREATE TABLE c(pid INT REFERENCES p(id) ON DELETE CASCADE)');
    await db.execute('INSERT INTO c VALUES(1)');
    await db.execute('INSERT OR REPLACE INTO p VALUES(1)');
    expect((await db.query('SELECT * FROM c')).rows, isEmpty);
  });
  test('views and row triggers are transactional and survive reopen', () async {
    var db = await MutableSqliteDatabase.create(pageSize: 512);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT)');
    await db.execute('CREATE TABLE audit(event TEXT,id INT,v TEXT)');
    await db.execute(
        "CREATE VIEW visible(k,value) AS SELECT id,v FROM t WHERE id>0");
    await db.execute(
        "CREATE TRIGGER ins AFTER INSERT ON t BEGIN INSERT INTO audit VALUES('I',new.id,new.v); END");
    await db.execute(
        "CREATE TRIGGER upd AFTER UPDATE OF v ON t BEGIN INSERT INTO audit VALUES('U',old.id,new.v); END");
    await db.execute(
        "CREATE TRIGGER del AFTER DELETE ON t BEGIN INSERT INTO audit VALUES('D',old.id,old.v); END");
    await db.execute(
        "CREATE TRIGGER guard BEFORE INSERT ON t WHEN new.v='bad' BEGIN SELECT RAISE(ABORT,'rejected'); END");
    await db.execute("INSERT INTO t VALUES(1,'a'),(2,'b')");
    final before = db.exportImage();
    await expectLater(db.execute("INSERT INTO t VALUES(3,'ok'),(4,'bad')"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute("UPDATE t SET v='changed' WHERE id=1");
    await db.execute('DELETE FROM t WHERE id=2');
    expect((await db.query('SELECT * FROM visible')).rows, [
      [BigInt.one, 'changed']
    ]);
    expect(
        (await db.query('SELECT event,id,v FROM audit ORDER BY rowid')).rows, [
      ['I', BigInt.one, 'a'],
      ['I', BigInt.two, 'b'],
      ['U', BigInt.one, 'changed'],
      ['D', BigInt.two, 'b']
    ]);
    await db.execute('BEGIN');
    await db.execute("INSERT INTO t VALUES(3,'rollback')");
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT count(*) FROM audit')).rows, [
      [BigInt.from(4)]
    ]);
    final image = db.exportImage();
    await db.close();
    db = await MutableSqliteDatabase.fromImage(image);
    addTearDown(db.close);
    await db.execute("INSERT INTO t VALUES(5,'reopened')");
    expect((await db.query('SELECT count(*) FROM audit')).rows, [
      [BigInt.from(5)]
    ]);
    await db.execute('DROP TRIGGER ins');
    await db.execute('DROP VIEW visible');
    await expectLater(
        db.query('SELECT * FROM visible'), throwsA(isA<SqlException>()));
  });
  test('create, constraints, secondary indexes, conflict policies and drop',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE users(id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, age INT DEFAULT 18 CHECK(age>=0))');
    await db.execute("INSERT INTO users(email) VALUES('a'),('b')");
    await db.execute(
        'CREATE INDEX users_age ON users(age DESC,email COLLATE NOCASE)');
    expect((await db.query('SELECT id,age FROM users ORDER BY id')).rows, [
      [BigInt.one, BigInt.from(18)],
      [BigInt.two, BigInt.from(18)]
    ]);
    for (final sql in [
      "INSERT INTO users(email) VALUES(NULL)",
      "INSERT INTO users(email,age) VALUES('c',-1)",
      "INSERT INTO users(email) VALUES('a')"
    ]) {
      final before = db.exportImage();
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
    expect(
        (await db.execute("INSERT OR IGNORE INTO users(email) VALUES('a')"))
            .changes,
        0);
    await db.execute("INSERT OR REPLACE INTO users(email) VALUES('a')");
    expect((await db.query('SELECT id,email FROM users ORDER BY id')).rows, [
      [BigInt.two, 'b'],
      [BigInt.from(3), 'a']
    ]);
    await db.execute('DROP INDEX users_age');
    await db.execute('DROP TABLE users');
    expect(
        (await db.query("SELECT name FROM sqlite_schema WHERE type='table'"))
            .rows,
        isEmpty);
  });
  test('foreign keys, cascading actions and deferred validation', () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys=1');
    await db.execute('CREATE TABLE p(id INTEGER PRIMARY KEY)');
    await db.execute(
        'CREATE TABLE c(id INTEGER PRIMARY KEY, parent INT REFERENCES p(id) ON DELETE CASCADE ON UPDATE CASCADE DEFERRABLE INITIALLY DEFERRED)');
    await db.execute('BEGIN');
    await db.execute('INSERT INTO c VALUES(1,7)');
    await expectLater(db.execute('COMMIT'), throwsA(isA<SqlException>()));
    expect(db.inTransaction, isTrue);
    await db.execute('INSERT INTO p VALUES(7)');
    await db.execute('COMMIT');
    await db.execute('UPDATE p SET id=8 WHERE id=7');
    expect((await db.query('SELECT parent FROM c')).rows, [
      [BigInt.from(8)]
    ]);
    await db.execute('DELETE FROM p');
    expect((await db.query('SELECT * FROM c')).rows, isEmpty);
  });
  test('autoincrement sequence survives deletes, reopen and rollback',
      () async {
    var db = await MutableSqliteDatabase.create(pageSize: 512);
    await db.execute(
        'CREATE TABLE seq(id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT)');
    await db.execute("INSERT INTO seq(value) VALUES('a')");
    await db.execute('DELETE FROM seq');
    final image = db.exportImage();
    await db.close();
    db = await MutableSqliteDatabase.fromImage(image);
    addTearDown(db.close);
    expect(
        (await db.execute("INSERT INTO seq(value) VALUES('b')"))
            .lastInsertRowid,
        BigInt.two);
    await db.execute('BEGIN');
    await db.execute("INSERT INTO seq(value) VALUES('x')");
    await db.execute('ROLLBACK');
    expect(
        (await db.execute("INSERT INTO seq(value) VALUES('c')"))
            .lastInsertRowid,
        BigInt.from(3));
    expect(
        (await db.query('SELECT seq FROM sqlite_sequence WHERE name=\'seq\''))
            .rows,
        [
          [BigInt.from(3)]
        ]);
  });
  test('WITHOUT ROWID and secondary index records survive rebuild', () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE pairs(a TEXT,b INT,value BLOB,PRIMARY KEY(a,b)) WITHOUT ROWID');
    for (var i = 0; i < 80; i++) {
      await db.execute('INSERT INTO pairs VALUES(?,?,?)',
          ['k${i % 7}', i, Uint8List.fromList(List.filled(100, i))]);
    }
    await db.execute('CREATE INDEX pair_value ON pairs(value)');
    expect((await db.query('SELECT count(*) FROM pairs')).rows, [
      [BigInt.from(80)]
    ]);
    await expectLater(db.execute('INSERT INTO pairs(a,b) VALUES(NULL,81)'),
        throwsA(isA<SqlException>()));
    await db.execute('UPDATE pairs SET a=? WHERE b=?', ['changed', 1]);
    expect((await db.query('SELECT a FROM pairs WHERE b=1')).rows, [
      ['changed']
    ]);
  });
  test(
      'CTE bulk insert and safe ADD COLUMN preserve defaults and transaction atomicity',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute('CREATE TABLE nums(id INTEGER PRIMARY KEY,n INT)');
    await db.execute(
        'INSERT INTO nums(n) WITH RECURSIVE x(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM x WHERE n<1000) SELECT n FROM x');
    expect((await db.query('SELECT count(*),sum(n) FROM nums')).rows, [
      [BigInt.from(1000), BigInt.from(500500)]
    ]);
    await db.execute(
        "ALTER TABLE nums ADD COLUMN label TEXT NOT NULL DEFAULT 'new'");
    expect(
        (await db.query("SELECT count(*) FROM nums WHERE label='new'")).rows, [
      [BigInt.from(1000)]
    ]);
    final before = db.exportImage();
    await expectLater(
        db.execute('ALTER TABLE nums ADD COLUMN bad INT NOT NULL'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute('BEGIN');
    await db.execute('CREATE TABLE tx(id INT)');
    await db.execute('ROLLBACK');
    await expectLater(
        db.query('SELECT * FROM tx'), throwsA(isA<SqlException>()));
  });
  test(
      'declared collations govern predicates, grouping, sorting and unique keys',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE words(id INTEGER PRIMARY KEY,v TEXT COLLATE NOCASE)');
    await db.execute("INSERT INTO words(v) VALUES('a'),('A'),('b')");
    expect((await db.query("SELECT count(*) FROM words WHERE v='A'")).rows, [
      [BigInt.two]
    ]);
    expect((await db.query('SELECT count(DISTINCT v) FROM words')).rows, [
      [BigInt.two]
    ]);
    expect(
        (await db.query('SELECT count(*) FROM words GROUP BY v ORDER BY v'))
            .rows,
        [
          [BigInt.two],
          [BigInt.one]
        ]);
    await expectLater(db.execute('CREATE UNIQUE INDEX words_v ON words(v)'),
        throwsA(isA<SqlException>()));
  });
}
