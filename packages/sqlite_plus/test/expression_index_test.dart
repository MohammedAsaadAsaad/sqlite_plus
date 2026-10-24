import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test(
      'index expressions observe REAL affinity even for integer record storage',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE real_values(id INTEGER PRIMARY KEY,r REAL)');
    await db.execute('INSERT INTO real_values VALUES(1,1),(2,2.0)');
    await db.execute('CREATE INDEX real_type ON real_values(typeof(r))');
    await db.execute('CREATE INDEX real_text ON real_values(CAST(r AS TEXT))');
    expect(
        (await db.query(
                "SELECT id FROM real_values WHERE typeof(r)='real' ORDER BY id"))
            .rows,
        [
          [BigInt.one],
          [BigInt.two]
        ]);
    expect(
        (await db.query(
                "SELECT id FROM real_values WHERE CAST(r AS TEXT)='1.0'"))
            .rows,
        [
          [BigInt.one]
        ]);
    expect(
        (await db.execute('UPDATE real_values SET r=r+1 RETURNING typeof(r)'))
            .returning!
            .rows,
        [
          ['real'],
          ['real']
        ]);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });
  test('expression keys preserve Unicode and blobs across all file encodings',
      () async {
    for (final encoding in [1, 2, 3]) {
      final db =
          await MutableSqliteDatabase.create(pageSize: 512, encoding: encoding);
      addTearDown(db.close);
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT,b BLOB)');
      await db.execute('CREATE UNIQUE INDEX unicode_key ON t(lower(v))');
      await db.execute('CREATE INDEX blob_key ON t(substr(b,2,2))');
      await db.execute(
          "INSERT INTO t VALUES(1,'λ😀A',X'0001ff'),(2,'😀λA',X'0002fe')");
      await expectLater(db.execute("INSERT INTO t VALUES(3,'λ😀a',X'00')"),
          throwsA(isA<SqlException>()));
      expect((await db.query("SELECT id FROM t WHERE lower(v)='λ😀a'")).rows, [
        [BigInt.one]
      ]);
      expect(
          (await db.query("SELECT id FROM t WHERE substr(b,2,2)=X'01ff'")).rows,
          [
            [BigInt.one]
          ]);
      expect((await db.query('PRAGMA integrity_check')).rows, [
        ['ok']
      ]);
    }
  });
  test(
      'expression and partial indexes maintain keys, uniqueness and membership',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY,name TEXT COLLATE NOCASE,active INT,n INT)');
    await db.execute(
        'CREATE UNIQUE INDEX live_name ON t(lower(name)) WHERE active=1');
    await db.execute(
        'CREATE INDEX magnitude ON t(abs(n) DESC,substr(name,1,1) COLLATE RTRIM) WHERE n IS NOT NULL');
    await db.execute(
        "INSERT INTO t VALUES(1,'A',1,-7),(2,'a',0,8),(3,NULL,1,NULL),(4,NULL,1,9)");
    for (final sql in [
      "INSERT INTO t VALUES(5,'a',1,1)",
      'UPDATE t SET active=1 WHERE id=2'
    ]) {
      final before = db.exportImage();
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
    expect(
        (await db.execute("INSERT OR IGNORE INTO t VALUES(5,'a',1,1)")).changes,
        0);
    await db.execute("INSERT OR REPLACE INTO t VALUES(5,'a',1,1)");
    expect((await db.query('SELECT id FROM t ORDER BY id')).rows, [
      [BigInt.two],
      [BigInt.from(3)],
      [BigInt.from(4)],
      [BigInt.from(5)]
    ]);
    expect(
        (await db.execute(
                "INSERT INTO t VALUES(6,'A',1,2) ON CONFLICT DO UPDATE SET n=excluded.n RETURNING id,n"))
            .returning!
            .rows,
        [
          [BigInt.from(5), BigInt.two]
        ]);
    expect((await db.query('PRAGMA index_xinfo(live_name)')).rows, [
      [BigInt.zero, BigInt.from(-2), null, BigInt.zero, 'BINARY', BigInt.one],
      [BigInt.one, -BigInt.one, null, BigInt.zero, 'BINARY', BigInt.zero]
    ]);
    final image = db.exportImage();
    final storage = MemoryStorageBackend();
    await storage.write(0, image);
    final reader = await SqliteDatabase.openReadOnly(storage);
    addTearDown(reader.close);
    expect(
        reader
            .explain("SELECT id FROM t WHERE lower(name)='a' AND active=1")
            .indexName,
        'live_name');
    expect(reader.explain("SELECT id FROM t WHERE lower(name)='a'").access,
        'table-scan');
    expect(
        (await reader
                .query("SELECT id FROM t WHERE lower(name)='a' AND active=1"))
            .rows,
        [
          [BigInt.from(5)]
        ]);
    expect(
        reader
            .explain('SELECT id FROM t WHERE abs(n)>=2 AND n IS NOT NULL')
            .indexName,
        'magnitude');
    expect(
        (await db.execute(
                "INSERT INTO t VALUES(7,'A',1,3) ON CONFLICT(lower(name)) WHERE active=1 DO UPDATE SET n=excluded.n RETURNING id,n"))
            .returning!
            .rows,
        [
          [BigInt.from(5), BigInt.from(3)]
        ]);
    await expectLater(
        db.execute(
            "INSERT INTO t VALUES(8,'a',1,4) ON CONFLICT(lower(name)) DO NOTHING"),
        throwsA(isA<SqlException>()));
    for (final predicate in ['active=TRUE', 'active=1 AND n>0', '1=active']) {
      await expectLater(
          db.execute(
              "INSERT INTO t VALUES(9,'a',1,4) ON CONFLICT(lower(name)) WHERE $predicate DO NOTHING"),
          throwsA(isA<SqlException>()));
    }

    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    await db.execute('ALTER TABLE t RENAME COLUMN name TO label');
    await db.execute('ALTER TABLE t RENAME TO renamed');
    await db.execute("UPDATE renamed SET label='B' WHERE id=5");
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    await expectLater(db.execute('ALTER TABLE renamed DROP active'),
        throwsA(isA<SqlException>()));
    await db.execute('DROP INDEX live_name');
    await db.execute('ALTER TABLE renamed DROP active');
  });
  test('non-determinism and evaluation errors are not ignored as constraints',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(n)');
    db.functions.registerScalar('unstable', 1, (args) => args.single);
    db.functions.registerScalar('stable', 1, (args) => args.single,
        deterministic: true);
    for (final sql in [
      'CREATE INDEX bad ON t(?)',
      'CREATE INDEX bad ON t((SELECT 1))',
      'CREATE INDEX bad ON t(sum(n))',
      'CREATE INDEX bad ON t(rowid)',
      'CREATE INDEX bad ON t(CURRENT_TIMESTAMP)',
      "CREATE INDEX bad ON t(RAISE(ABORT,'bad'))",
      'CREATE INDEX bad ON t(unstable(n))'
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
    }
    await db.execute('CREATE TABLE constrained(x INT NOT NULL CHECK(x>0))');
    expect(
        (await db.execute(
                'INSERT OR IGNORE INTO constrained VALUES(NULL),(-1),(1)'))
            .changes,
        1);
    await db.execute('CREATE INDEX good ON t(stable(n))');
    await db.execute(
        "CREATE INDEX fixed_clock ON t(datetime('2000-01-01','subsec'))");
    await db.execute('CREATE UNIQUE INDEX absolute ON t(abs(n))');
    final before = db.exportImage();
    await expectLater(
        db.execute('INSERT OR IGNORE INTO t VALUES(-9223372036854775808)'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute('CREATE INDEX bad_clock ON t(datetime(n))');
    await expectLater(db.execute("INSERT INTO t VALUES('now')"),
        throwsA(isA<SqlException>()));
    expect((await db.query('SELECT * FROM t')).rows, isEmpty);
  });
  test('WITHOUT ROWID indexes retain PK fields when collations differ',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute('CREATE TABLE wr(k TEXT PRIMARY KEY,n INT) WITHOUT ROWID');
    await db.execute("INSERT INTO wr VALUES('A',1),('a',2),('b',3)");
    await db.execute('CREATE INDEX wr_case ON wr(k COLLATE NOCASE)');
    await db.execute('CREATE INDEX wr_expression ON wr(abs(n)) WHERE n>1');
    expect((await db.query('PRAGMA index_xinfo(wr_case)')).rows.length, 2);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
    await db.execute('UPDATE wr SET n=-n');
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });
  test('conflict expression matching preserves real tokens and boolean nodes',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INT)');
    await db.execute('CREATE UNIQUE INDEX real_key ON t(a+1.0)');
    await db.execute('INSERT INTO t VALUES(1)');
    expect(
        (await db.execute(
                'INSERT INTO t VALUES(1) ON CONFLICT(a+1.0) DO NOTHING'))
            .changes,
        0);
    await expectLater(
        db.execute('INSERT INTO t VALUES(1) ON CONFLICT(a+1.00) DO NOTHING'),
        throwsA(isA<SqlException>()));
    await db.execute('CREATE UNIQUE INDEX int_key ON t(a+1)');
    expect(
        (await db.execute(
                'INSERT INTO t VALUES(1) ON CONFLICT(a+0x1) DO NOTHING'))
            .changes,
        0);
    await expectLater(
        db.execute('INSERT INTO t VALUES(1) ON CONFLICT(a+TRUE) DO NOTHING'),
        throwsA(isA<SqlException>()));
  });
  test(
      'only proven partial predicates and matching expression trees use indexes',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INT,b INT,active INT)');
    await db.execute('INSERT INTO t VALUES(1,2,1),(2,1,0),(3,4,NULL)');
    await db.execute(
        'CREATE INDEX sum_active ON t(a+b) WHERE active=1 OR active=2');
    await db.execute('CREATE INDEX nonnull_b ON t(b) WHERE b IS NOT NULL');
    final storage = MemoryStorageBackend();
    await storage.write(0, db.exportImage());
    final reader = await SqliteDatabase.openReadOnly(storage);
    addTearDown(reader.close);
    expect(reader.explain('SELECT a FROM t WHERE a+b=3 AND active=1').indexName,
        'sum_active');
    expect(reader.explain('SELECT a FROM t WHERE b+a=3 AND active=1').access,
        'table-scan');
    expect(reader.explain('SELECT a FROM t WHERE a+b=3 AND active=3').access,
        'table-scan');
    expect(reader.explain('SELECT a FROM t WHERE b=2').indexName, 'nonnull_b');
    expect(
        (await reader.query('SELECT a FROM t WHERE a+b=3 AND active=1')).rows, [
      [BigInt.one]
    ]);
    expect(
        (await reader.query('SELECT a FROM t WHERE b+a=3 ORDER BY a')).rows, [
      [BigInt.one],
      [BigInt.two]
    ]);
  });
}
