import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('view DML fires INSTEAD OF triggers without physical view records',
      () async {
    final db = await MutableSqliteDatabase.create(pageSize: 512);
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v TEXT,n REAL)');
    await db.execute('CREATE VIEW edit(key,label,num) AS SELECT id,v,n FROM t');
    await expectLater(db.execute("INSERT INTO edit VALUES(1,'a',1)"),
        throwsA(isA<SqlException>()));
    await db.execute('CREATE TRIGGER ins INSTEAD OF INSERT ON edit BEGIN '
        'INSERT INTO t VALUES(new.key,new.label,new.num); END');
    final inserted = await db.execute(
        "INSERT INTO edit(label,num) VALUES('λ😀',1),('b',2) RETURNING *");
    expect(inserted.changes, 0);
    expect(inserted.lastInsertRowid, isNull);
    expect(inserted.returning!.rows, [
      [null, 'λ😀', 1.0],
      [null, 'b', 2.0]
    ]);
    await db.execute('CREATE TRIGGER upd INSTEAD OF UPDATE ON edit BEGIN '
        'UPDATE t SET v=new.label,n=new.num WHERE id=old.key; END');
    await db.execute('CREATE TRIGGER del INSTEAD OF DELETE ON edit BEGIN '
        'DELETE FROM t WHERE id=old.key; END');
    final updated = await db.execute(
        "UPDATE edit SET label='changed',num=num+1 WHERE key=1 RETURNING *");
    expect(updated.changes, 0);
    expect(updated.returning!.rows, [
      [BigInt.one, 'changed', 2.0]
    ]);
    await db.execute('BEGIN');
    final deleted = await db.execute('DELETE FROM edit RETURNING key');
    expect(deleted.changes, 0);
    expect(deleted.returning!.rows, [
      [BigInt.one],
      [BigInt.two]
    ]);
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT count(*) FROM edit')).rows, [
      [BigInt.two]
    ]);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    await reopened.execute('DELETE FROM edit WHERE key=2');
    expect((await reopened.query('SELECT * FROM t')).rows, [
      [BigInt.one, 'changed', 2.0]
    ]);
    expect((await reopened.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('view timing restrictions and pseudo-rowid errors are atomic', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x)');
    await db.execute('CREATE VIEW v AS SELECT x FROM t');
    for (final sql in [
      'CREATE TRIGGER a BEFORE INSERT ON v BEGIN SELECT 1; END',
      'CREATE TRIGGER b AFTER DELETE ON v BEGIN SELECT 1; END',
      'CREATE TRIGGER c INSTEAD OF INSERT ON t BEGIN SELECT 1; END',
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()));
    }
    await db.execute('CREATE TRIGGER ins INSTEAD OF INSERT ON v BEGIN '
        'INSERT INTO t VALUES(new.rowid); END');
    final before = db.exportImage();
    await expectLater(
        db.execute('INSERT INTO v VALUES(1)'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await expectLater(
        db.execute('UPDATE v SET x=1'), throwsA(isA<SqlException>()));
    await expectLater(
        db.execute('DELETE FROM v'), throwsA(isA<SqlException>()));
  });
}
