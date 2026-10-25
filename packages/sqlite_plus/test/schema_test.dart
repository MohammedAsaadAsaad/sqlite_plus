import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('column ALTER preserves constraints, index/FK metadata and rollback',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE alter_p(id INTEGER PRIMARY KEY,code TEXT UNIQUE,junk BLOB,value INT CHECK(value>0),CHECK(length(code)>0))');
    await db.execute('CREATE INDEX alter_idx ON alter_p(code,value DESC)');
    await db
        .execute('CREATE TABLE alter_c(code TEXT REFERENCES alter_p(code))');
    await db.execute("INSERT INTO alter_p VALUES(1,'a',zeroblob(2000),7)");
    await db.execute("INSERT INTO alter_c VALUES('a')");
    await db.execute('ALTER TABLE alter_p RENAME COLUMN code TO label');
    expect((await db.query('PRAGMA foreign_key_list(alter_c)')).rows.single[4],
        'label');
    await db.execute('ALTER TABLE alter_p DROP COLUMN junk');
    expect((await db.query('SELECT * FROM alter_p')).rows, [
      [BigInt.one, 'a', BigInt.from(7)]
    ]);
    await db.execute('ALTER TABLE alter_p RENAME value TO length');
    await db.execute('ALTER TABLE alter_p RENAME COLUMN length TO amount');
    final before = db.exportImage();
    await expectLater(db.execute('ALTER TABLE alter_p DROP COLUMN amount'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute('DROP INDEX alter_idx');
    await db.execute('ALTER TABLE alter_p DROP amount');
    expect((await db.query('SELECT * FROM alter_p')).rows, [
      [BigInt.one, 'a']
    ]);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    await db.execute('BEGIN');
    await db.execute('ALTER TABLE alter_p RENAME label TO temporary');
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT label FROM alter_p')).rows, [
      ['a']
    ]);
    for (final sql in [
      'ALTER TABLE alter_p DROP label',
      'ALTER TABLE alter_p DROP id',
      'ALTER TABLE alter_p RENAME label TO id'
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
    }
    await db.execute(
        'CREATE TABLE alter_wr(k TEXT PRIMARY KEY,pad BLOB,n INT) WITHOUT ROWID');
    await db.execute("INSERT INTO alter_wr VALUES('key',zeroblob(1000),7)");
    await db.execute('ALTER TABLE alter_wr DROP pad');
    await db.execute('ALTER TABLE alter_wr RENAME k TO ident');
    expect((await db.query('SELECT * FROM alter_wr')).rows, [
      ['key', BigInt.from(7)]
    ]);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    await db.execute('CREATE TABLE punct("(" TEXT,")" INT,"," BLOB)');
    await db.execute("INSERT INTO punct VALUES('x',7,X'00')");
    await db.execute('ALTER TABLE punct RENAME COLUMN ")" TO number');
    await db.execute('ALTER TABLE punct DROP COLUMN ","');
    expect((await db.query('SELECT * FROM punct')).rows, [
      ['x', BigInt.from(7)]
    ]);
    await db.execute('CREATE VIEW alter_view AS SELECT * FROM alter_p');
    await db.execute('ALTER TABLE alter_p RENAME label TO blocked');
    expect((await db.query('SELECT * FROM alter_view')).columns,
        contains('blocked'));
  });
  test('integrity checks detect stale index keys without mutating data',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,k TEXT)');
    await db.execute("INSERT INTO t VALUES(1,'a'),(2,'b')");
    await db.execute('CREATE INDEX t_k ON t(k)');
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    expect((await db.query('PRAGMA quick_check(1)')).rows, [
      ['ok']
    ]);
    final image = db.exportImage();
    final schemaStorage = MemoryStorageBackend();
    await schemaStorage.write(0, image);
    final reader = await SqliteDatabase.openReadOnly(schemaStorage);
    final root =
        reader.catalog.entries.firstWhere((e) => e.name == 't_k').rootPage;
    await reader.close();
    final header = DatabaseHeader.decode(image);
    final page = Uint8List.sublistView(image, (root - 1) * 512, root * 512);
    final framing =
        BtreePageHeader.decode(page, database: header, pageNumber: root);
    final cell = SqliteByteReader(page, offset: framing.cellOffsets.first);
    cell.varint();
    final payload = cell.offset;
    final record = SqliteByteReader(page, offset: payload);
    final body = payload + record.varint().toInt();
    expect(page[body], 97);
    page[body] = 99;
    final corrupt = await MutableSqliteDatabase.fromImage(image);
    addTearDown(corrupt.close);
    expect((await corrupt.query('PRAGMA integrity_check')).rows.single.single,
        contains('Index content'));
    expect((await corrupt.query('PRAGMA quick_check')).rows, [
      ['ok']
    ]);
    expect(corrupt.exportImage(), image);
    await expectLater(
        db.query('PRAGMA integrity_check(0)'), throwsA(isA<SqlException>()));
  });
  test(
      'foreign_key_check reports rowids and WITHOUT ROWID nulls and schema mismatch',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE p(id INTEGER PRIMARY KEY)');
    await db.execute('INSERT INTO p VALUES(1)');
    await db.execute('CREATE TABLE c(id INTEGER PRIMARY KEY,pid REFERENCES p)');
    await db.execute('INSERT INTO c VALUES(1,1),(2,9),(3,NULL)');
    expect((await db.query('PRAGMA foreign_key_check(c)')).rows, [
      ['c', BigInt.two, 'p', BigInt.zero]
    ]);
    await db.execute(
        'CREATE TABLE wr(k TEXT PRIMARY KEY,pid REFERENCES p) WITHOUT ROWID');
    await db.execute("INSERT INTO wr VALUES('x',9)");
    expect((await db.query('PRAGMA foreign_key_check(wr)')).rows, [
      ['wr', null, 'p', BigInt.zero]
    ]);
    await db.execute('CREATE TABLE nonunique(x)');
    await db.execute('CREATE TABLE mismatch(x REFERENCES nonunique(x))');
    await expectLater(db.query('PRAGMA foreign_key_check(mismatch)'),
        throwsA(isA<SqlException>()));
  });
  test('OLD/NEW trigger values are bound independently from SQL text',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(v)');
    await db.execute('CREATE TABLE audit(v)');
    await db.execute(
        'CREATE TRIGGER copy AFTER INSERT ON t BEGIN INSERT INTO audit VALUES(new.v); END');
    final values = <Object?>[
      'a\u0000b',
      "quote' and ?1",
      double.infinity,
      double.negativeInfinity,
      Uint8List.fromList([0, 39, 255])
    ];
    for (final value in values) {
      await db.execute('INSERT INTO t VALUES(?)', [value]);
    }
    expect((await db.query('SELECT v FROM audit ORDER BY rowid')).rows,
        values.map((v) => [v]).toList());
  });
  test(
      'schema collisions and malformed trigger bodies fail before changing the image',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x)');
    await db.execute('CREATE VIEW v AS SELECT * FROM t');
    for (final sql in [
      'CREATE TABLE v(x)',
      'CREATE INDEX v ON t(x)',
      'CREATE VIEW sqlite_bad AS SELECT 1',
      'CREATE TRIGGER bad AFTER INSERT ON t BEGIN UPDATE t SET ; END',
      'CREATE TRIGGER bad AFTER INSERT ON t BEGIN INSERT INTO t VALUES(1) RETURNING x; END'
    ]) {
      final before = db.exportImage();
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before);
    }
    await db.execute(
        "CREATE TRIGGER good AFTER INSERT ON t BEGIN SELECT RAISE(ABORT,'negative') WHERE new.x<0; END");
    await db.execute('INSERT INTO t VALUES(1)');
    await expectLater(
        db.execute('INSERT INTO t VALUES(-1)'), throwsA(isA<SqlException>()));
  });
  test(
      'table rename rewrites index/FK/sequence metadata and rolls back atomically',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute('PRAGMA foreign_keys=1');
    await db.execute(
        'CREATE TABLE p(id INTEGER PRIMARY KEY AUTOINCREMENT,k TEXT UNIQUE)');
    await db.execute('CREATE INDEX p_k ON p(k)');
    await db.execute("INSERT INTO p(k) VALUES('a')");
    await db.execute('CREATE TABLE c(pid INT REFERENCES p(id))');
    await db.execute('INSERT INTO c VALUES(1)');
    await db.execute('ALTER TABLE p RENAME TO renamed');
    expect((await db.query("SELECT name FROM sqlite_sequence")).rows, [
      ['renamed']
    ]);
    await db.execute("INSERT INTO renamed(k) VALUES('b')");
    await db.execute('INSERT INTO c VALUES(2)');
    expect((await db.query('PRAGMA foreign_key_list(c)')).rows.single[2],
        'renamed');
    await db.execute('BEGIN');
    await db.execute('ALTER TABLE renamed RENAME TO temporary');
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT count(*) FROM renamed')).rows, [
      [BigInt.two]
    ]);
    await db.execute('CREATE VIEW v AS SELECT * FROM renamed');
    final before = db.exportImage();
    await db.execute('BEGIN');
    await db.execute('ALTER TABLE renamed RENAME TO blocked');
    expect((await db.query('SELECT count(*) FROM v')).rows, [
      [BigInt.two]
    ]);
    await db.execute('ROLLBACK');
    expect(db.exportImage(), before);
    await db.execute('DROP VIEW v');
    await db.execute('ALTER TABLE renamed RENAME TO "space name"');
    expect((await db.query('SELECT count(*) FROM "space name"')).rows, [
      [BigInt.two]
    ]);
  });
  test('UPSERT resolves target keys, excluded values, conditions and RETURNING',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT,k TEXT UNIQUE,n INT NOT NULL CHECK(n>0))');
    await db.execute("INSERT INTO t(k,n) VALUES('a',1),('b',2)");
    final result = await db.execute(
        "INSERT INTO t(k,n) VALUES('a',3),('c',4) ON CONFLICT(k) DO UPDATE SET n=t.n+excluded.n RETURNING id,k,n");
    expect(result.changes, 2);
    expect(result.lastInsertRowid, BigInt.from(4));
    expect(result.returning!.rows, [
      [BigInt.one, 'a', BigInt.from(4)],
      [BigInt.from(4), 'c', BigInt.from(4)]
    ]);
    final ignored = await db.execute(
        "INSERT INTO t(k,n) VALUES('a',1) ON CONFLICT(k) DO NOTHING RETURNING id");
    expect(ignored.changes, 0);
    expect(ignored.returning!.rows, isEmpty);
    expect(ignored.lastInsertRowid, isNull);
    expect(
        (await db.execute(
                "INSERT INTO t(k,n) VALUES('a',1) ON CONFLICT(k) DO UPDATE SET n=excluded.n WHERE excluded.n>t.n RETURNING id"))
            .returning!
            .rows,
        isEmpty);
    expect(
        (await db.execute(
                "INSERT INTO t(id,k,n) VALUES(1,'new',8) ON CONFLICT(id) DO UPDATE SET n=excluded.n RETURNING n"))
            .returning!
            .rows,
        [
          [BigInt.from(8)]
        ]);
    final before = db.exportImage();
    await expectLater(
        db.execute(
            "INSERT INTO t(k,n) VALUES('a',NULL) ON CONFLICT(k) DO NOTHING"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await expectLater(
        db.execute(
            "INSERT INTO t(k,n) VALUES('a',2) ON CONFLICT(k) DO UPDATE SET k='b'"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    expect(
        (await db.execute(
                "INSERT INTO t(k,n) SELECT 'a',2 WHERE 1 ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING n"))
            .returning!
            .rows,
        [
          [BigInt.two]
        ]);
    final multiple = await db.execute(
        "INSERT INTO t(id,k,n) VALUES(1,'unused',1),(99,'b',2),(100,'fresh',3) ON CONFLICT(id) DO NOTHING ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING k,n");
    expect(multiple.returning!.rows, [
      ['b', BigInt.two],
      ['fresh', BigInt.from(3)]
    ]);
    expect(
        (await db.execute(
                "INSERT INTO t(k,n) VALUES('a',9) ON CONFLICT DO UPDATE SET n=excluded.n RETURNING n"))
            .returning!
            .rows,
        [
          [BigInt.from(9)]
        ]);
    await db.execute('CREATE TABLE wr(k TEXT PRIMARY KEY,n INT) WITHOUT ROWID');
    await db.execute("INSERT INTO wr VALUES('x',1)");
    expect(
        (await db.execute(
                "INSERT INTO wr VALUES('x',2) ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING *"))
            .returning!
            .rows,
        [
          ['x', BigInt.two]
        ]);
    await expectLater(
        db.execute("INSERT INTO wr VALUES('x',3) ON CONFLICT(n) DO NOTHING"),
        throwsA(isA<SqlException>()));
  });
  test(
      'RETURNING reports direct rows before AFTER triggers and excludes ignored rows',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT UNIQUE)');
    final insert = await db.execute(
        "INSERT INTO t(v) VALUES('a'),('b') RETURNING *,id+10 AS next");
    expect(insert.returning!.columns, ['id', 'v', 'next']);
    expect(insert.returning!.rows, [
      [BigInt.one, 'a', BigInt.from(11)],
      [BigInt.two, 'b', BigInt.from(12)]
    ]);
    final ignored =
        await db.execute("INSERT OR IGNORE INTO t(v) VALUES('a') RETURNING id");
    expect(ignored.returning!.rows, isEmpty);
    expect(ignored.returning!.columns, ['id']);
    await db.execute(
        "CREATE TRIGGER changed AFTER UPDATE ON t BEGIN UPDATE t SET v='trigger' WHERE id=new.id; END");
    final updated =
        await db.execute("UPDATE t SET v='direct' WHERE id=1 RETURNING t.id,v");
    expect(updated.returning!.rows, [
      [BigInt.one, 'direct']
    ]);
    expect((await db.query('SELECT v FROM t WHERE id=1')).rows, [
      ['trigger']
    ]);
    expect(
        (await db.execute('DELETE FROM t WHERE id=1 RETURNING *'))
            .returning!
            .rows,
        [
          [BigInt.one, 'trigger']
        ]);
    expect(
        (await db.execute("INSERT INTO t(v) SELECT 'c' RETURNING id,v"))
            .returning!
            .rows,
        [
          [BigInt.from(3), 'c']
        ]);
    expect(
        (await db.execute('UPDATE t SET v=? WHERE id=? RETURNING id,? AS bound',
                ['updated', 3, 'value']))
            .returning!
            .rows,
        [
          [BigInt.from(3), 'value']
        ]);
    final before = db.exportImage();
    await expectLater(db.execute('DELETE FROM t RETURNING count(*)'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
  });
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
