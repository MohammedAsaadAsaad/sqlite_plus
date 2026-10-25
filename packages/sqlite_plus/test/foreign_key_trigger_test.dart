import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  Future<MutableSqliteDatabase> database(String action) async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final sql in [
      'PRAGMA foreign_keys=1',
      'CREATE TABLE p(id INTEGER PRIMARY KEY)',
      'CREATE TABLE c(id INTEGER PRIMARY KEY,pid DEFAULT 0 REFERENCES p(id) '
          'ON UPDATE $action ON DELETE $action)',
      'CREATE TABLE log(s)',
      'INSERT INTO p VALUES(0),(1)',
      'INSERT INTO c VALUES(10,1)',
      "CREATE TRIGGER pbu BEFORE UPDATE ON p BEGIN INSERT INTO log VALUES('pbu'); END",
      "CREATE TRIGGER pau AFTER UPDATE ON p BEGIN INSERT INTO log VALUES('pau'); END",
      "CREATE TRIGGER cbu BEFORE UPDATE ON c BEGIN INSERT INTO log VALUES('cbu:'||old.pid||':'||coalesce(new.pid,'N')); END",
      "CREATE TRIGGER cau AFTER UPDATE ON c BEGIN INSERT INTO log VALUES('cau:'||old.pid||':'||coalesce(new.pid,'N')); END",
      "CREATE TRIGGER cbd BEFORE DELETE ON c BEGIN INSERT INTO log VALUES('cbd:'||old.pid); END",
      "CREATE TRIGGER cad AFTER DELETE ON c BEGIN INSERT INTO log VALUES('cad:'||old.pid); END",
    ]) {
      await db.execute(sql);
    }
    return db;
  }

  for (final entry in [
    ('CASCADE', '2'),
    ('SET NULL', 'N'),
    ('SET DEFAULT', '0')
  ]) {
    test('${entry.$1} actions fire child UPDATE triggers before parent AFTER',
        () async {
      final db = await database(entry.$1);
      final result =
          await db.execute('UPDATE p SET id=2 WHERE id=1 RETURNING id');
      expect(result.changes, 1);
      expect(result.returning!.rows, [
        [BigInt.two]
      ]);
      expect((await db.query('SELECT s FROM log')).rows, [
        ['pbu'],
        ['cbu:1:${entry.$2}'],
        ['cau:1:${entry.$2}'],
        ['pau']
      ]);
      expect((await db.query('PRAGMA foreign_key_check')).rows, isEmpty);
      await db.execute('DELETE FROM log');
      await db.execute('DELETE FROM p WHERE id=2');
      expect(
          (await db.query('SELECT s FROM log')).rows,
          entry.$1 == 'CASCADE'
              ? [
                  ['cbd:2'],
                  ['cad:2']
                ]
              : isEmpty);
    });
  }

  test('nested cascades run all row triggers with recursive_triggers disabled',
      () async {
    final db = await database('CASCADE');
    await db.execute('CREATE TABLE g(id REFERENCES c(id) ON DELETE CASCADE)');
    await db.execute('INSERT INTO g VALUES(10)');
    await db.execute(
        "CREATE TRIGGER gd AFTER DELETE ON g BEGIN INSERT INTO log VALUES('gd:'||old.id); END");
    expect((await db.execute('DELETE FROM p WHERE id=1')).changes, 1);
    expect((await db.query('SELECT s FROM log')).rows, [
      ['cbd:1'],
      ['gd:10'],
      ['cad:1']
    ]);
    expect((await db.query('SELECT * FROM g')).rows, isEmpty);
  });

  test('REPLACE and DROP implicit deletes invoke cascading child triggers',
      () async {
    final db = await database('CASCADE');
    await db.execute('INSERT OR REPLACE INTO p VALUES(1)');
    expect((await db.query('SELECT s FROM log')).rows, [
      ['cbd:1'],
      ['cad:1']
    ]);
    await db.execute('INSERT INTO c VALUES(11,1)');
    await db.execute('DELETE FROM log');
    await db.execute('DROP TABLE p');
    expect((await db.query('SELECT s FROM log')).rows, [
      ['cbd:1'],
      ['cad:1']
    ]);
    expect((await db.query('SELECT * FROM c')).rows, isEmpty);
  });

  test('failed cascade rolls back row and trigger writes', () async {
    final db = await database('CASCADE');
    await db.execute(
        "CREATE TRIGGER blocked BEFORE DELETE ON c BEGIN INSERT INTO log VALUES('blocked'); SELECT RAISE(IGNORE); END");
    final before = db.exportImage();
    await expectLater(
        db.execute('DELETE FROM p WHERE id=1'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    await db.execute('DROP TRIGGER blocked');
    final defaults = await database('SET DEFAULT');
    await defaults.execute('CREATE UNIQUE INDEX unique_child ON c(pid)');
    await defaults.execute('INSERT INTO c VALUES(11,0)');
    final stable = defaults.exportImage();
    await expectLater(
        defaults.execute('UPDATE OR IGNORE p SET id=2 WHERE id=1'),
        throwsA(isA<SqlException>()));
    expect(defaults.exportImage(), stable);
  });

  test('deferred parent keys remain checked at COMMIT after child triggers',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final sql in [
      'PRAGMA foreign_keys=1',
      'CREATE TABLE p(id PRIMARY KEY)',
      'CREATE TABLE c(pid REFERENCES p ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED)',
      'CREATE TABLE audit(x)',
      'CREATE TRIGGER cu AFTER UPDATE ON c BEGIN INSERT INTO audit VALUES(new.pid); END',
      'INSERT INTO p VALUES(1)',
      'INSERT INTO c VALUES(1)',
      'BEGIN',
      'DELETE FROM p',
      'COMMIT',
    ]) {
      await db.execute(sql);
    }
    expect((await db.query('SELECT * FROM audit')).rows, [
      [null]
    ]);
    expect((await db.query('PRAGMA foreign_key_check')).rows, isEmpty);
  });
}
