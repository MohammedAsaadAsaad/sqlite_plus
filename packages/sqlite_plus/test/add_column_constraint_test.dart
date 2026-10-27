import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    test('ADD COLUMN precedes table constraints encoding $encoding', () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      await db.execute('PRAGMA foreign_keys=ON');
      await db.execute('CREATE TABLE parent(a,b,PRIMARY KEY(a,b))');
      await db.execute('INSERT INTO parent VALUES(1,2)');
      await db.execute('CREATE TABLE child("CONSTRAINT" TEXT,a,b,'
          'CONSTRAINT fk FOREIGN KEY(a,b) REFERENCES parent(a,b),'
          'UNIQUE("CONSTRAINT"),CHECK(a>0))');
      await db.execute("INSERT INTO child VALUES('original',1,2)");
      await db.execute('ALTER TABLE child ADD note TEXT DEFAULT \'x)\'');
      expect((await db.query('SELECT * FROM child')).rows, [
        ['original', BigInt.one, BigInt.two, 'x)']
      ]);
      final sql =
          (await db.query("SELECT sql FROM sqlite_schema WHERE name='child'"))
              .rows
              .single
              .single as String;
      expect(
          sql,
          'CREATE TABLE child("CONSTRAINT" TEXT,a,b, '
          'note TEXT DEFAULT \'x)\',CONSTRAINT fk '
          'FOREIGN KEY(a,b) REFERENCES parent(a,b),'
          'UNIQUE("CONSTRAINT"),CHECK(a>0))');
      expect((await db.query('PRAGMA integrity_check')).rows, [
        ['ok']
      ]);
      await db.execute('ALTER TABLE child ADD virtual INT AS(a+b)');
      expect((await db.query('SELECT virtual FROM child')).rows, [
        [BigInt.from(3)]
      ]);
      final before = db.exportImage();
      await expectLater(db.execute('ALTER TABLE child ADD bad INT NOT NULL'),
          throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    });
    test(
        'ADD COLUMN respects quoted punctuation and comments encoding $encoding',
        () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      await db.execute('CREATE TABLE t(a TEXT /*tail*/, /*head*/ '
          'CHECK(a<>\')\'))');
      await db.execute("INSERT INTO t VALUES('old')");
      await db.execute('ALTER TABLE t ADD b INT');
      expect(
          (await db.query("SELECT sql FROM sqlite_schema WHERE name='t'"))
              .rows
              .single
              .single,
          'CREATE TABLE t(a TEXT /*tail*/, b INT, /*head*/ CHECK(a<>\')\'))');
      expect((await db.query('SELECT * FROM t')).rows, [
        ['old', null]
      ]);
    });
  }
}
