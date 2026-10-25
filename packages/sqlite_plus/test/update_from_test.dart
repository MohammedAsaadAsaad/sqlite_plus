import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  Future<MutableSqliteDatabase> database() async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final sql in [
      'CREATE TABLE t(id INTEGER PRIMARY KEY,n INTEGER)',
      'INSERT INTO t VALUES(1,10),(2,20),(3,30)',
      'CREATE TABLE s(id INTEGER,delta INTEGER)',
      'INSERT INTO s VALUES(1,2),(1,3),(3,4)',
    ]) {
      await db.execute(sql);
    }
    return db;
  }

  test('UPDATE FROM snapshots joined assignments and writes each target once',
      () async {
    final db = await database();
    final result = await db.execute('UPDATE t SET n=t.n+s.delta '
        'FROM s WHERE s.id=t.id RETURNING id,n');
    expect(result.changes, 2);
    expect(result.returning!.rows, [
      [BigInt.one, BigInt.from(13)],
      [BigInt.from(3), BigInt.from(34)]
    ]);
    expect((await db.query('SELECT n FROM t WHERE id=2')).rows, [
      [BigInt.from(20)]
    ]);
    await db.execute('UPDATE t AS target SET n=source.n+1 FROM t AS source '
        'WHERE target.id=source.id+1');
    expect((await db.query('SELECT n FROM t ORDER BY id')).rows, [
      [BigInt.from(13)],
      [BigInt.from(14)],
      [BigInt.from(21)]
    ]);
  });

  test('UPDATE FROM supports CTEs, joins, derived sources and parameters',
      () async {
    final db = await database();
    final result = await db.execute(
        'WITH q(id,v) AS (VALUES(?,?)) '
        'UPDATE t AS target SET n=q.v+d.delta+? FROM q '
        'JOIN (SELECT id,max(delta) AS delta FROM s GROUP BY id) AS d USING(id) '
        'WHERE target.id=q.id RETURNING t.id,n',
        [1, 40, 2]);
    expect(result.returning!.rows, [
      [BigInt.one, BigInt.from(45)]
    ]);
    await db.execute('UPDATE t SET n=s.delta FROM s LEFT JOIN '
        '(SELECT 1 AS k) AS q ON q.k=s.id WHERE t.id=s.id');
    expect((await db.query('SELECT n FROM t ORDER BY id')).rows, [
      [BigInt.from(3)],
      [BigInt.from(20)],
      [BigInt.from(4)]
    ]);
  });

  test('UPDATE FROM materializes callback values before row triggers',
      () async {
    final db = await database();
    final events = <String>[];
    var counter = 0;
    db.functions.registerScalar('tick', 1, (args) {
      events.add('tick:${args.single}');
      return ++counter;
    });
    db.functions.registerScalar('record', 1, (args) {
      events.add('row:${args.single}');
      return null;
    });
    await db.execute(
        'CREATE TRIGGER changed AFTER UPDATE ON t BEGIN SELECT record(new.id); END');
    await db.execute('UPDATE t SET n=tick(t.id) FROM s WHERE t.id=s.id');
    expect(events, ['tick:1', 'tick:1', 'tick:3', 'row:1', 'row:3']);
    expect((await db.query('SELECT n FROM t ORDER BY id')).rows, [
      [BigInt.two],
      [BigInt.from(20)],
      [BigInt.from(3)]
    ]);
  });

  test('UPDATE FROM identifies WITHOUT ROWID and fully shadowed rowids',
      () async {
    final db = await database();
    await db.execute(
        'CREATE TABLE wr(k TEXT PRIMARY KEY COLLATE NOCASE,n) WITHOUT ROWID');
    await db.execute("INSERT INTO wr VALUES('A',10),('B',20)");
    expect(
        (await db.execute(
                "UPDATE wr SET n=s.delta FROM s WHERE wr.k=CASE s.id WHEN 1 THEN 'a' ELSE 'z' END RETURNING *"))
            .returning!
            .rows,
        [
          ['A', BigInt.from(3)]
        ]);
    await db.execute('CREATE TABLE shadow(rowid,oid,_rowid_,v)');
    await db.execute("INSERT INTO shadow VALUES(1,1,1,0),(1,1,1,0)");
    expect(
        (await db.execute(
                'UPDATE shadow SET v=s.delta FROM s WHERE s.id=1 RETURNING v'))
            .changes,
        2);
    expect((await db.query('SELECT v FROM shadow')).rows, [
      [BigInt.from(3)],
      [BigInt.from(3)]
    ]);
  });

  test('UPDATE FROM supports INSTEAD OF view updates and zero direct changes',
      () async {
    final db = await database();
    await db.execute('CREATE VIEW v AS SELECT id,n FROM t');
    await db.execute('CREATE TRIGGER vu INSTEAD OF UPDATE ON v BEGIN '
        'UPDATE t SET n=new.n WHERE id=old.id; END');
    final result = await db.execute(
        'UPDATE v SET n=v.n+s.delta FROM s WHERE v.id=s.id RETURNING *');
    expect(result.changes, 0);
    expect(result.returning!.rows, [
      [BigInt.one, BigInt.from(12)],
      [BigInt.one, BigInt.from(13)],
      [BigInt.from(3), BigInt.from(34)]
    ]);
    expect((await db.query('SELECT n FROM t ORDER BY id')).rows, [
      [BigInt.from(13)],
      [BigInt.from(20)],
      [BigInt.from(34)]
    ]);
  });

  test('UPDATE FROM invalid sources and expressions preserve the image',
      () async {
    final db = await database();
    final before = db.exportImage();
    for (final sql in [
      'UPDATE t SET n=id FROM s',
      'UPDATE t SET n=missing FROM s',
      'UPDATE t SET n=1 FROM missing',
      'UPDATE t SET n=1 FROM t',
      'UPDATE t SET n=s.delta FROM s RETURNING s.delta',
      'UPDATE t AS q SET n=1 RETURNING q.n',
      'UPDATE t SET n=1 RETURNING main.t.n',
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before, reason: sql);
    }
    expect(
        (await db.execute('UPDATE t SET n=s.delta FROM s WHERE 0')).changes, 0);
  });
}
