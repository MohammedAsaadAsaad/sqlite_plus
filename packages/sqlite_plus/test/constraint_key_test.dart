import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  setUp(() async {
    db = await MutableSqliteDatabase.create(pageSize: 512);
    await db.execute('PRAGMA foreign_keys=ON');
  });
  tearDown(() => db.close());

  test('constraint key collation overrides the column for uniqueness',
      () async {
    await db.execute('CREATE TABLE t(a TEXT COLLATE NOCASE,b TEXT,'
        'UNIQUE(a COLLATE BINARY DESC),UNIQUE(b COLLATE RTRIM ASC))');
    await db.execute("INSERT INTO t VALUES('a','one'),('A','two')");
    await expectLater(db.execute("INSERT INTO t VALUES('a','three')"),
        throwsA(isA<SqlConstraintException>()));
    await expectLater(db.execute("INSERT INTO t VALUES('b','one ')"),
        throwsA(isA<SqlConstraintException>()));
    expect((await db.query('PRAGMA index_xinfo(sqlite_autoindex_t_1)')).rows, [
      [BigInt.zero, BigInt.zero, 'a', BigInt.one, 'BINARY', BigInt.one],
      [BigInt.one, -BigInt.one, null, BigInt.zero, 'BINARY', BigInt.zero]
    ]);
  });

  test('equivalent keys deduplicate directions and retain primary origin',
      () async {
    await db.execute('CREATE TABLE t(a TEXT,b INT,UNIQUE(a DESC),'
        'PRIMARY KEY(a ASC),UNIQUE(a COLLATE NOCASE ASC))');
    expect((await db.query('PRAGMA index_list(t)')).rows, [
      [BigInt.zero, 'sqlite_autoindex_t_2', BigInt.one, 'u', BigInt.zero],
      [BigInt.one, 'sqlite_autoindex_t_1', BigInt.one, 'pk', BigInt.zero],
    ]);
    expect(
        (await db.query('PRAGMA index_xinfo(sqlite_autoindex_t_1)')).rows.first,
        [BigInt.zero, BigInt.zero, 'a', BigInt.one, 'BINARY', BigInt.one]);
    await db.execute("INSERT INTO t VALUES('a',1)");
    await expectLater(db.execute("INSERT INTO t VALUES('A',2)"),
        throwsA(isA<SqlConstraintException>()));
  });

  test('WITHOUT ROWID key ordering and auxiliary collations survive reopen',
      () async {
    await db.execute('CREATE TABLE t(a TEXT,b INT,c TEXT,'
        'PRIMARY KEY(a COLLATE NOCASE DESC,b ASC)) WITHOUT ROWID');
    await db.execute(
        "INSERT INTO t VALUES('a',1,'one'),('B',2,'two'),('a',3,'three')");
    await db.execute('CREATE INDEX t_a ON t(a COLLATE BINARY DESC)');
    expect((await db.query('SELECT a,b FROM t')).rows, [
      ['B', BigInt.two],
      ['a', BigInt.one],
      ['a', BigInt.from(3)],
    ]);
    expect((await db.query('PRAGMA index_xinfo(t)')).rows, [
      [BigInt.zero, BigInt.zero, 'a', BigInt.one, 'NOCASE', BigInt.one],
      [BigInt.one, BigInt.one, 'b', BigInt.zero, 'BINARY', BigInt.one],
      [BigInt.two, BigInt.two, 'c', BigInt.zero, 'BINARY', BigInt.zero],
    ]);
    expect((await db.query('PRAGMA index_xinfo(t_a)')).rows, [
      [BigInt.zero, BigInt.zero, 'a', BigInt.one, 'BINARY', BigInt.one],
      [BigInt.one, BigInt.zero, 'a', BigInt.one, 'NOCASE', BigInt.zero],
      [BigInt.two, BigInt.one, 'b', BigInt.zero, 'BINARY', BigInt.zero],
    ]);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    try {
      await reopened.execute("INSERT INTO t VALUES('b',2,'duplicate') "
          "ON CONFLICT(a COLLATE NOCASE,b) DO UPDATE SET c=excluded.c");
      expect((await reopened.query("SELECT c FROM t WHERE b=2")).rows, [
        ['duplicate']
      ]);
      expect((await reopened.query('PRAGMA integrity_check')).rows, [
        ['ok']
      ]);
    } finally {
      await reopened.close();
    }
  });

  test('implicit parent primary key uses its indexed collation', () async {
    for (final suffix in ['', ' WITHOUT ROWID']) {
      await db.execute('CREATE TABLE p(a TEXT,b INT,'
          'PRIMARY KEY(a COLLATE NOCASE DESC))$suffix');
      await db.execute('CREATE TABLE child(a REFERENCES p ON UPDATE CASCADE)');
      await db.execute("INSERT INTO p VALUES('a',1)");
      await db.execute("INSERT INTO child VALUES('A')");
      expect((await db.query('PRAGMA foreign_key_check')).rows, isEmpty);
      final before = db.exportImage();
      await expectLater(
          db.execute("UPDATE p SET a='b'"), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
      await expectLater(
          db.execute('DELETE FROM p'), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
      expect((await db.query('PRAGMA foreign_key_check')).rows, isEmpty);
      await db.execute('DROP TABLE child');
      await db.execute('CREATE TABLE child(a REFERENCES p(a))');
      await expectLater(db.execute("INSERT INTO child VALUES('a')"),
          throwsA(isA<SqlException>()));
      await db.execute('DROP TABLE child');
      await db.execute('DROP TABLE p');
    }
  });

  test('invalid constraint modifiers fail atomically', () async {
    for (final sql in [
      'CREATE TABLE t(a,UNIQUE(missing DESC))',
      'CREATE TABLE t(a,UNIQUE(a COLLATE missing))',
      'CREATE TABLE t(a,PRIMARY KEY(a COLLATE missing DESC))',
      'CREATE TABLE t(a,FOREIGN KEY(a DESC) REFERENCES p(a))',
      'CREATE TABLE t(a REFERENCES p(a DESC))',
      'CREATE TABLE t(a,UNIQUE(a) ON CONFLICT IGNORE,'
          'UNIQUE(a DESC) ON CONFLICT REPLACE)',
    ]) {
      final before = db.exportImage();
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before, reason: sql);
    }
  });

  test('repeated primary-key fields reject before writing a malformed image',
      () async {
    for (final suffix in ['', ' WITHOUT ROWID']) {
      for (final terms in ['a,a', 'a COLLATE NOCASE,a COLLATE BINARY', 'a,A']) {
        final before = db.exportImage();
        await expectLater(
            db.execute('CREATE TABLE repeated(a TEXT,b INT,'
                'PRIMARY KEY($terms))$suffix'),
            throwsA(isA<SqlException>()));
        expect(db.exportImage(), before);
      }
    }
  });

  test('WITHOUT ROWID index enumeration preserves numeric constraint order',
      () async {
    await db.execute('CREATE TABLE many(k INT PRIMARY KEY,'
        '${List.generate(12, (i) => 'c$i INT UNIQUE').join(',')}) WITHOUT ROWID');
    await db.execute('CREATE INDEX added ON many(c0)');
    final rows = (await db.query('PRAGMA index_list(many)')).rows;
    expect(rows.map((row) => row[1]),
        ['added', for (var i = 13; i >= 1; i--) 'sqlite_autoindex_many_$i']);
    expect(rows.last[3], 'pk');
  });

  test('foreign key schema errors prepare before empty or NULL row effects',
      () async {
    await db.execute('CREATE TABLE p(a TEXT UNIQUE,b INT,c INT)');
    await db.execute('CREATE TABLE child(a REFERENCES p(b),b INT)');
    for (final sql in [
      'INSERT INTO child VALUES(NULL,NULL)',
      'UPDATE child SET a=NULL',
      'DELETE FROM child',
      'UPDATE p SET b=NULL',
      'DELETE FROM p',
      'INSERT OR REPLACE INTO p VALUES(NULL,NULL,NULL)',
      'UPDATE OR REPLACE p SET a=NULL',
      'INSERT INTO p VALUES(NULL,NULL,NULL) ON CONFLICT(a) DO UPDATE SET b=1',
    ]) {
      final before = db.exportImage();
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before, reason: sql);
    }
    for (final sql in [
      'UPDATE child SET b=NULL',
      'UPDATE child SET rowid=rowid',
      'UPDATE p SET a=NULL',
      'UPDATE p SET c=NULL',
      'UPDATE OR REPLACE p SET c=NULL',
      'INSERT INTO p VALUES(NULL,NULL,NULL) ON CONFLICT(a) DO UPDATE SET a=1',
    ]) {
      await db.execute(sql);
    }
    await db.execute('DROP TABLE child');
    await db.execute('CREATE TABLE child(a REFERENCES missing,b INT)');
    await expectLater(db.execute('INSERT INTO child VALUES(NULL,NULL)'),
        throwsA(isA<SqlException>()));
    await db.execute('UPDATE child SET b=NULL');
  });
}
