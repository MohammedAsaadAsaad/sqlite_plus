import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  for (final encoding in ['UTF-8', 'UTF-16le', 'UTF-16be']) {
    test('native generated storage, overflow and writes $encoding', () async {
      final bytes =
          await File('test/fixtures/generated-$encoding.db').readAsBytes();
      final storage = MemoryStorageBackend();
      await storage.write(0, bytes);
      final reader = await SqliteDatabase.openReadOnly(storage);
      expect(
          (await reader.query('SELECT id,c,r,kind FROM generated ORDER BY id'))
              .rows,
          [
            [BigInt.one, BigInt.from(3), 3.0, 'real'],
            [BigInt.two, BigInt.from(3000), 3000.0, 'real'],
            [BigInt.from(3), null, null, 'null']
          ]);
      expect(
          (await reader.query(
                  "SELECT a.b,a.c FROM generated a JOIN generated a2 ON a.id=a2.id WHERE a.id=1"))
              .rows,
          [
            ['λ😀a', BigInt.from(3)]
          ]);
      await reader.close();
      final db = await MutableSqliteDatabase.fromImage(bytes);
      addTearDown(db.close);
      await db.execute("UPDATE generated SET a='λ😀B' WHERE id=1");
      await db.execute('UPDATE generated_wr SET a=a+2');
      expect(
          (await db.query("SELECT c FROM generated WHERE b='λ😀b' AND c>0"))
              .rows,
          [
            [BigInt.from(3)]
          ]);
      expect((await db.query('SELECT b,c FROM generated WHERE id=1')).rows, [
        ['λ😀b', BigInt.from(3)]
      ]);
      expect((await db.query('SELECT b,c FROM generated_wr ORDER BY a')).rows, [
        [BigInt.from(4), '4λ'],
        [BigInt.from(5), '5😀']
      ]);
      expect((await db.query('PRAGMA integrity_check')).rows, [
        ['ok']
      ]);
    });
  }

  test('stored and virtual chains follow affinity, indexes and rowid changes',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,a INT, '
        'b INT AS(c+1) STORED,c INT AS(a*2),r REAL AS(a),kind TEXT AS(typeof(r)), '
        'label TEXT AS(a||\'λ😀\') UNIQUE)');
    final result =
        await db.execute('INSERT INTO t(a) VALUES(2),(3),(NULL) RETURNING *');
    expect(result.returning!.rows, [
      [
        BigInt.one,
        BigInt.two,
        BigInt.from(5),
        BigInt.from(4),
        2.0,
        'real',
        '2λ😀'
      ],
      [
        BigInt.two,
        BigInt.from(3),
        BigInt.from(7),
        BigInt.from(6),
        3.0,
        'real',
        '3λ😀'
      ],
      [BigInt.from(3), null, null, null, null, 'null', null]
    ]);
    await db.execute('CREATE INDEX idx ON t(b,c) WHERE a>0');
    await db.execute('UPDATE t SET id=10,a=4 WHERE id=1');
    await db.execute(
        'INSERT INTO t(a) VALUES(4) ON CONFLICT(label) DO UPDATE SET a=5');
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    expect(
        (await reopened.query('SELECT a,b,c,kind FROM t WHERE id=10')).rows, [
      [BigInt.from(5), BigInt.from(11), BigInt.from(10), 'real']
    ]);
    expect(
        (await reopened.query(
                'SELECT x.b,y.c FROM t x JOIN t y ON x.id=y.id WHERE x.id=10'))
            .rows,
        [
          [BigInt.from(11), BigInt.from(10)]
        ]);
    expect((await reopened.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('generated metadata, ALTER and read-only index queries stay coherent',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a INT,b INT AS(a+1) STORED,c AS(b+1))');
    await db.execute('INSERT INTO t VALUES(3)');
    expect(
        (await db.query('PRAGMA table_info(t)')).rows.map((r) => r[1]), ['a']);
    expect((await db.query('PRAGMA table_xinfo(t)')).rows.map((r) => r.last),
        [BigInt.zero, BigInt.from(3), BigInt.two]);
    await db.execute('ALTER TABLE t ADD d TEXT AS(c||\'!\')');
    await db.execute('ALTER TABLE t RENAME a TO value');
    expect((await db.query('SELECT * FROM t')).rows, [
      [BigInt.from(3), BigInt.from(4), BigInt.from(5), '5!']
    ]);
    final before = db.exportImage();
    for (final sql in [
      'ALTER TABLE t DROP value',
      'ALTER TABLE t DROP b',
      'ALTER TABLE t ADD bad AS(value) STORED',
      'UPDATE t SET c=0',
      'INSERT INTO t(a,b) VALUES(1,2)'
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
    await db.execute('ALTER TABLE t DROP d');
    await db.execute('ALTER TABLE t DROP c');
    await db.execute('ALTER TABLE t DROP b');
    expect((await db.query('SELECT * FROM t')).rows, [
      [BigInt.from(3)]
    ]);
  });

  test('generated constraints, STRICT types and BEFORE/AFTER values', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE t(a TEXT,b INT AS(a) STORED CHECK(b>0) NOT NULL) STRICT');
    await db.execute('CREATE TABLE audit(b INT)');
    await db.execute(
        'CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO audit VALUES(new.b); END');
    final result = await db.execute(
        "INSERT OR IGNORE INTO t VALUES('2'),('-1'),(NULL) RETURNING b");
    expect(result.returning!.rows, [
      [BigInt.two]
    ]);
    expect((await db.query('SELECT * FROM audit')).rows, [
      [BigInt.two]
    ]);
    final before = db.exportImage();
    await expectLater(db.execute("INSERT OR IGNORE INTO t VALUES('bad')"),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute('BEGIN');
    await db.execute("UPDATE t SET a='3'");
    await db.execute('ROLLBACK');
    expect(db.exportImage(), before);
  });

  test('generated expression restrictions reject invalid empty schemas',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final before = db.exportImage();
    for (final body in [
      'a,b AS(b)',
      'a,b AS(c),c AS(b)',
      'a AS(1)',
      'a,b AS(a) DEFAULT 1',
      'a,b AS(a) PRIMARY KEY',
      'a,b AS(rowid)',
      'a,b AS((SELECT 1))',
      'a,b AS(?)',
      'a,b AS(sum(a))',
      'a,b AS(CURRENT_TIMESTAMP)',
      'a,b AS(missing+1)'
    ]) {
      await expectLater(
          db.execute('CREATE TABLE t($body)'), throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
  });
}
