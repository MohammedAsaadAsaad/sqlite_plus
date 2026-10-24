import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('table rename follows bindings through views, aliases and CTE scopes',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE original(id INTEGER PRIMARY KEY,v TEXT)');
    await db.execute("INSERT INTO original VALUES(1,'one'),(2,'two')");
    await db.execute('CREATE VIEW plain AS SELECT original.* FROM original');
    await db.execute(
        'CREATE VIEW nested AS SELECT a.id,(SELECT count(*) FROM original '
        'WHERE original.id<=a.id) AS n FROM original AS a');
    await db.execute(
        'CREATE VIEW shadow AS WITH original(id) AS(VALUES(99)) SELECT original.id FROM original');
    await db.execute(
        "CREATE VIEW aliases AS SELECT original.id,'original' AS original FROM plain AS original");
    await db.execute('ALTER TABLE original RENAME TO changed');
    expect((await db.query('SELECT * FROM plain ORDER BY id')).rows, [
      [BigInt.one, 'one'],
      [BigInt.two, 'two']
    ]);
    expect((await db.query('SELECT * FROM nested ORDER BY id')).rows, [
      [BigInt.one, BigInt.one],
      [BigInt.two, BigInt.two]
    ]);
    expect((await db.query('SELECT * FROM shadow')).rows, [
      [BigInt.from(99)]
    ]);
    expect((await db.query('SELECT * FROM aliases ORDER BY id')).rows, [
      [BigInt.one, 'original'],
      [BigInt.two, 'original']
    ]);
    await db.execute('BEGIN');
    await db.execute('ALTER TABLE changed RENAME TO undone');
    await db.execute('ROLLBACK');
    expect((await db.query('SELECT count(*) FROM changed')).rows, [
      [BigInt.two]
    ]);
  });

  test('owner triggers, external DML and view triggers follow renamed tables',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE original(id INTEGER PRIMARY KEY,v INT,original TEXT)');
    await db.execute('CREATE TABLE events(id INT,v INT)');
    await db.execute('CREATE TABLE audit(v INT)');
    await db.execute(
        "CREATE TRIGGER original AFTER UPDATE OF original ON original BEGIN INSERT INTO audit VALUES(new.v); END");
    await db.execute('CREATE TRIGGER route AFTER INSERT ON events BEGIN '
        'INSERT INTO original(id,v) VALUES(new.id,new.v) '
        'ON CONFLICT(id) DO UPDATE SET v=original.v+excluded.v; END');
    await db.execute('CREATE VIEW edit AS SELECT id,v,original FROM original');
    await db
        .execute('CREATE TRIGGER edit_insert INSTEAD OF INSERT ON edit BEGIN '
            'REPLACE INTO original VALUES(new.id,new.v,new.original); END');
    await db.execute('ALTER TABLE original RENAME TO changed');
    // Pinned SQLite rebinds EXCLUDED.v to changed.v during this rename.
    await db.execute('INSERT INTO events VALUES(1,2),(1,3)');
    await db.execute("UPDATE changed SET original='original' WHERE id=1");
    await db.execute("INSERT INTO edit VALUES(2,7,'two')");
    expect((await db.query('SELECT * FROM changed ORDER BY id')).rows, [
      [BigInt.one, BigInt.from(4), 'original'],
      [BigInt.two, BigInt.from(7), 'two']
    ]);
    expect((await db.query('SELECT * FROM audit')).rows, [
      [BigInt.from(4)]
    ]);
    expect(
        (await db.query(
                "SELECT tbl_name FROM sqlite_schema WHERE name='original' AND type='trigger'"))
            .rows,
        [
          ['changed']
        ]);
    final beforeCollision = db.exportImage();
    await expectLater(db.execute('ALTER TABLE changed RENAME TO old'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), beforeCollision);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    await reopened.execute('INSERT INTO events VALUES(1,1)');
    expect((await reopened.query('SELECT v FROM changed WHERE id=1')).rows, [
      [BigInt.from(8)]
    ]);
  });

  test('quoted qualifiers are rewritten and ambiguous aliases fail atomically',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE "odd.name"(x INT)');
    await db.execute('INSERT INTO "odd.name" VALUES(3)');
    await db.execute('CREATE VIEW q AS SELECT "odd.name".* FROM "odd.name"');
    await db.execute('ALTER TABLE "odd.name" RENAME TO "new name"');
    expect((await db.query('SELECT * FROM q')).rows, [
      [BigInt.from(3)]
    ]);
    await db.execute(
        'CREATE VIEW ambiguous AS SELECT * FROM "new name" AS a JOIN "new name" AS a');
    final image = db.exportImage();
    await expectLater(db.execute('ALTER TABLE "new name" RENAME TO another'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    await db.execute('DROP VIEW ambiguous');
    await db.execute(
        'CREATE VIEW unresolved AS SELECT "new name".x FROM "new name" AS a');
    final unresolved = db.exportImage();
    await expectLater(db.execute('ALTER TABLE "new name" RENAME TO another'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), unresolved);
  });
}
