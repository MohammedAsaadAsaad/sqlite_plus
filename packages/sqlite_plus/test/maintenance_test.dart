import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  Future<MutableSqliteDatabase> database() async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    return db;
  }

  Future<List<List<Object?>>> statistics(MutableSqliteDatabase db) async =>
      (await db.query('SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx'))
          .rows;

  test('ANALYZE writes actual expression/partial/collated prefix statistics',
      () async {
    final db = await database();
    for (final sql in [
      'CREATE TABLE t(a TEXT COLLATE NOCASE,b INT,c)',
      'CREATE INDEX i ON t(a,b DESC)',
      'CREATE INDEX p ON t(c) WHERE b>1',
      'CREATE INDEX e ON t(lower(a),abs(b))',
      "INSERT INTO t VALUES('A',1,'x'),('a',2,'y'),('B',2,'y'),"
          '(NULL,3,NULL),(NULL,3,NULL)',
    ]) {
      await db.execute(sql);
    }
    expect((await db.execute('ANALYZE')).changes, 0);
    expect(await statistics(db), [
      ['t', 'e', '5 2 2'],
      ['t', 'i', '5 2 2'],
      ['t', 'p', '4 2'],
    ]);
    expect((await db.query('PRAGMA table_info(sqlite_stat1)')).rows, [
      [BigInt.zero, 'tbl', '', BigInt.zero, null, BigInt.zero],
      [BigInt.one, 'idx', '', BigInt.zero, null, BigInt.zero],
      [BigInt.two, 'stat', '', BigInt.zero, null, BigInt.zero],
    ]);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    expect(await statistics(reopened), await statistics(db));
    expect((await reopened.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('targeted ANALYZE leaves other statistics stale until recomputed',
      () async {
    final db = await database();
    for (final sql in [
      'CREATE TABLE t(a,b)',
      'CREATE INDEX i ON t(a)',
      'CREATE INDEX p ON t(b) WHERE a>0',
      'INSERT INTO t VALUES(1,2),(2,2)',
      'ANALYZE t',
      'INSERT INTO t VALUES(3,2),(4,4)',
    ]) {
      await db.execute(sql);
    }
    expect(await statistics(db), [
      ['t', 'i', '2 1'],
      ['t', 'p', '2 2'],
    ]);
    await db.execute('ANALYZE main.i');
    expect(await statistics(db), [
      ['t', 'i', '4 1'],
      ['t', 'p', '2 2'],
    ]);
    await db.execute('ANALYZE main.t');
    expect(await statistics(db), [
      ['t', 'i', '4 1'],
      ['t', 'p', '4 2'],
    ]);
    await db.execute('DROP INDEX i');
    expect(await statistics(db), [
      ['t', 'p', '4 2'],
    ]);
    await db.execute('DROP TABLE t');
    expect(await statistics(db), isEmpty);
  });

  test('WITHOUT ROWID primary tree and partial-only table statistics',
      () async {
    final db = await database();
    for (final sql in [
      'CREATE TABLE wr(a TEXT,b,c,PRIMARY KEY(a COLLATE NOCASE DESC,b DESC)) '
          'WITHOUT ROWID',
      'CREATE INDEX wi ON wr(c)',
      "INSERT INTO wr VALUES('A',1,9),('a',2,9),('B',1,9)",
      'CREATE TABLE t(a)',
      'CREATE INDEX p ON t(a) WHERE 0',
      'INSERT INTO t VALUES(NULL),(1),(2)',
      'CREATE TABLE empty(a UNIQUE)',
      'ANALYZE main',
    ]) {
      await db.execute(sql);
    }
    expect(await statistics(db), [
      ['t', null, '3'],
      ['t', 'p', '0 0'],
      ['wr', 'wi', '3 3'],
      ['wr', 'wr', '3 2 1'],
    ]);
    await db.execute('ANALYZE wi');
    expect(await statistics(db), [
      ['t', null, '3'],
      ['t', 'p', '0 0'],
      ['wr', 'wi', '3 3'],
      ['wr', 'wr', '3 2 1'],
    ]);
    await db.execute('DELETE FROM t');
    await db.execute('ANALYZE t');
    expect(await statistics(db), [
      ['t', 'p', '0 0'],
      ['wr', 'wi', '3 3'],
      ['wr', 'wr', '3 2 1'],
    ]);
  });

  test('statistics transactions, empty tables and schema aliases', () async {
    final db = await database();
    await db.execute('CREATE TABLE t(a)');
    await db.execute('INSERT INTO t VALUES(1),(2)');
    await db.execute('BEGIN');
    await db.execute('ANALYZE');
    expect(await statistics(db), [
      ['t', null, '2']
    ]);
    await db.execute('ROLLBACK');
    await expectLater(
        db.query('SELECT * FROM sqlite_stat1'), throwsA(isA<SqlException>()));
    await db.execute('ANALYZE sqlite_master');
    expect(await statistics(db), isEmpty);
    await db.execute('ANALYZE t');
    await db.execute('BEGIN');
    await db.execute('DELETE FROM t');
    await db.execute('ANALYZE t');
    expect(await statistics(db), isEmpty);
    await db.execute('ROLLBACK');
    expect(await statistics(db), [
      ['t', null, '2']
    ]);
    await db.execute("UPDATE sqlite_stat1 SET stat='custom'");
    await db.execute('ANALYZE main.sqlite_schema');
    expect(await statistics(db), [
      ['t', null, 'custom']
    ]);
    await db.execute('CREATE VIEW v AS SELECT * FROM t');
    await db.execute('ANALYZE v');
    expect(await statistics(db), [
      ['t', null, 'custom']
    ]);
    await db.execute('ANALYZE');
    expect(await statistics(db), [
      ['t', null, '2']
    ]);
  });

  test('REINDEX rebuilds supported keys without firing row triggers or CHECK',
      () async {
    final db = await database();
    var checks = 0;
    var evaluations = 0;
    db.functions.registerScalar('checking', 1, (_) {
      checks++;
      return 1;
    });
    db.functions.registerScalar('indexed', 1, (arguments) {
      evaluations++;
      return arguments[0];
    }, deterministic: true);
    for (final sql in [
      'CREATE TABLE t(a CHECK(checking(a)))',
      'CREATE INDEX i ON t(indexed(a))',
      'CREATE TABLE audit(a)',
      'CREATE TRIGGER tr AFTER UPDATE ON t BEGIN INSERT INTO audit VALUES(new.a); END',
      'INSERT INTO t VALUES(1),(2)',
      'ANALYZE',
    ]) {
      await db.execute(sql);
    }
    final prior = await statistics(db);
    checks = 0;
    evaluations = 0;
    for (final sql in [
      'REINDEX i',
      'REINDEX main.t',
      'REINDEX NOCASE',
      'REINDEX main.sqlite_schema',
      'REINDEX',
    ]) {
      expect((await db.execute(sql)).changes, 0);
    }
    expect(checks, 0);
    expect(evaluations, greaterThan(0));
    expect((await db.query('SELECT * FROM audit')).rows, isEmpty);
    expect(await statistics(db), prior);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('REINDEX uniqueness errors preserve the original image', () async {
    final db = await database();
    db.functions.registerScalar('indexed', 1, (arguments) => arguments[0],
        deterministic: true);
    await db.execute('CREATE TABLE t(a)');
    await db.execute('CREATE UNIQUE INDEX i ON t(indexed(a))');
    await db.execute('INSERT INTO t VALUES(1),(2)');
    final before = db.exportImage();
    db.functions.registerScalar('indexed', 1, (_) => 0, deterministic: true);
    await expectLater(
        db.execute('REINDEX i'), throwsA(isA<SqlConstraintException>()));
    expect(db.exportImage(), before);
    db.functions.registerScalar('indexed', 1, (arguments) => arguments[0],
        deterministic: true);
    await db.execute('REINDEX i');
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('maintenance rejects unknown targets, schemas, parameters and syntax',
      () async {
    final db = await database();
    await db.execute('CREATE TABLE t(a)');
    final before = db.exportImage();
    for (final sql in [
      'ANALYZE missing',
      'ANALYZE other.t',
      'ANALYZE temp',
      'ANALYZE t extra',
      'ANALYZE t.t.t',
      'ANALYZE ?',
      'REINDEX missing',
      'REINDEX other.t',
      'REINDEX main.NOCASE',
      'REINDEX main',
      'REINDEX t extra',
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before, reason: sql);
    }
    for (final sql in ['ANALYZE', 'REINDEX t']) {
      await expectLater(db.execute(sql, [1]), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
    await db.execute('ANALYZE;');
    expect(await statistics(db), isEmpty);
    expect(
        (await db.query(
                "SELECT name FROM sqlite_schema WHERE name LIKE 'sqlite_stat%'"))
            .rows,
        [
          ['sqlite_stat1']
        ]);
  });

  test('VACUUM compacts unindexed rowids and preserves indexed/aliased keys',
      () async {
    final db = await database();
    for (final sql in [
      'CREATE TABLE plain(a)',
      'CREATE TABLE indexed(a UNIQUE)',
      'CREATE TABLE aliased(id INTEGER PRIMARY KEY,a)',
      'CREATE TABLE wr(a PRIMARY KEY) WITHOUT ROWID',
      'INSERT INTO plain(rowid,a) VALUES(-10,1),(40,2),(50,3)',
      'INSERT INTO indexed(rowid,a) VALUES(-10,1),(40,2),(50,3)',
      'INSERT INTO aliased VALUES(-10,1),(40,2),(50,3)',
      'INSERT INTO wr VALUES(1),(2),(3)',
      'ANALYZE',
    ]) {
      await db.execute(sql);
    }
    final stats = await statistics(db);
    expect((await db.execute('VACUUM main')).changes, 0);
    expect((await db.query('SELECT rowid,a FROM plain')).rows, [
      [BigInt.one, BigInt.one],
      [BigInt.two, BigInt.two],
      [BigInt.from(3), BigInt.from(3)],
    ]);
    for (final name in ['indexed', 'aliased']) {
      expect((await db.query('SELECT rowid,a FROM $name')).rows, [
        [BigInt.from(-10), BigInt.one],
        [BigInt.from(40), BigInt.two],
        [BigInt.from(50), BigInt.from(3)],
      ]);
    }
    expect((await db.query('SELECT * FROM wr')).rows, [
      [BigInt.one],
      [BigInt.two],
      [BigInt.from(3)]
    ]);
    expect(await statistics(db), stats);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('VACUUM rejects transactions, external targets and INTO atomically',
      () async {
    final db = await database();
    await db.execute('CREATE TABLE t(a)');
    final before = db.exportImage();
    for (final sql in [
      'VACUUM other',
      'VACUUM main.t',
      "VACUUM INTO 'x.db'",
      "VACUUM main INTO 'x.db'"
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
    await expectLater(db.execute('VACUUM', [1]), throwsA(isA<SqlException>()));
    await db.execute('BEGIN');
    await expectLater(db.execute('VACUUM'), throwsA(isA<SqlException>()));
    expect(db.inTransaction, isTrue);
    await db.execute('ROLLBACK');
    await db.execute('SAVEPOINT s');
    await expectLater(db.execute('VACUUM'), throwsA(isA<SqlException>()));
    await db.execute('ROLLBACK');
    await db.execute('VACUUM;');
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });
}
