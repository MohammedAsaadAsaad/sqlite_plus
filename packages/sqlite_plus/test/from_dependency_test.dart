import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  setUp(() async {
    db = await MutableSqliteDatabase.create(pageSize: 512);
    await db
        .execute('CREATE TABLE target(id INTEGER PRIMARY KEY,v INT,spare INT)');
    await db.execute(
        'CREATE TABLE source(id INTEGER PRIMARY KEY,amount INT,spare INT)');
    await db.execute('CREATE TABLE events(id INT)');
    await db.execute('INSERT INTO target VALUES(1,0,0),(2,0,0)');
    await db.execute('INSERT INTO source VALUES(1,7,0),(2,11,0)');
  });
  tearDown(() => db.close());

  test('trigger UPDATE FROM binds assignments after source aliases', () async {
    await db.execute('CREATE TRIGGER changed AFTER INSERT ON events BEGIN '
        'UPDATE target SET v=s.amount+(SELECT r.amount FROM source r WHERE r.id=s.id) '
        'FROM source s WHERE target.id=s.id AND s.id=new.id; END');
    await db.execute('ALTER TABLE source RENAME amount TO value');
    await db.execute('ALTER TABLE target RENAME v TO result');
    await db.execute('ALTER TABLE events RENAME id TO ident');
    await db.execute('INSERT INTO events VALUES(1)');
    expect((await db.query('SELECT id,result FROM target ORDER BY id')).rows, [
      [BigInt.one, BigInt.from(14)],
      [BigInt.two, BigInt.zero],
    ]);
    expect((await db.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('trigger UPDATE FROM rewrites physical table qualifiers and main names',
      () async {
    await db.execute('CREATE TRIGGER changed AFTER INSERT ON events BEGIN '
        'UPDATE target SET v=source.amount FROM main.source '
        'WHERE target.id=source.id AND source.id=new.id; END');
    await db.execute('ALTER TABLE source RENAME TO renamed');
    await db.execute('ALTER TABLE target RENAME TO destination');
    await db.execute('INSERT INTO events VALUES(2)');
    expect((await db.query('SELECT id,v FROM destination ORDER BY id')).rows, [
      [BigInt.one, BigInt.zero],
      [BigInt.two, BigInt.from(11)],
    ]);
  });

  test(
      'trigger FROM dependencies reject drops and USING-key renames atomically',
      () async {
    await db.execute('CREATE TABLE extra(id INT,n INT)');
    await db.execute('CREATE TRIGGER changed AFTER INSERT ON events BEGIN '
        'UPDATE target SET v=s.amount+e.n FROM source s JOIN extra e USING(id) '
        'WHERE target.id=s.id AND s.id=new.id; END');
    for (final sql in [
      'ALTER TABLE source DROP amount',
      'ALTER TABLE source RENAME id TO ident',
      'ALTER TABLE extra DROP n',
    ]) {
      final before = db.exportImage();
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before);
    }
    await db.execute('ALTER TABLE source DROP spare');
    await db.execute('ALTER TABLE extra RENAME n TO number');
  });

  test('unaliased first join group preserves resolved field provenance',
      () async {
    await db.execute('CREATE VIEW v AS SELECT s.amount,e.id FROM '
        '(source s JOIN events e ON s.id=e.id)');
    await db.execute('ALTER TABLE source RENAME amount TO value');
    await db.execute('ALTER TABLE source RENAME TO renamed');
    await db.execute('INSERT INTO events VALUES(2)');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.from(11), BigInt.two]
    ]);
  });

  test('materialized group aliases preserve output-name boundaries', () async {
    await db.execute('CREATE TABLE a(x INT,y INT)');
    await db.execute('CREATE TABLE b(x INT,z INT)');
    await db.execute('INSERT INTO a VALUES(1,2)');
    await db.execute('INSERT INTO b VALUES(1,3)');
    await db
        .execute('CREATE VIEW v AS SELECT q.x FROM (a JOIN b ON a.x=b.x) q');
    await db.execute('ALTER TABLE a RENAME x TO value');
    await db.execute('ALTER TABLE a RENAME TO renamed');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.one]
    ]);
    await db.execute('DROP VIEW v');
    await db.execute('CREATE VIEW v AS SELECT q."x:1" FROM '
        '(renamed JOIN b ON renamed.value=b.x) q');
    final before = db.exportImage();
    await expectLater(db.execute('ALTER TABLE renamed RENAME value TO x'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
  });
}
