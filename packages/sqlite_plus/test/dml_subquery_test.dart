import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  Future<MutableSqliteDatabase> database() async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,x INT)');
    await db.execute('INSERT INTO t VALUES(1,1),(2,2),(3,3)');
    return db;
  }

  test('UPDATE scalar subqueries distinguish live correlated and once values',
      () async {
    final db = await database();
    final result = await db.execute(
        'UPDATE t SET x=(SELECT sum(a.x) FROM t AS a WHERE a.id<=t.id) RETURNING id,x');
    expect(result.returning!.rows, [
      [BigInt.one, BigInt.one],
      [BigInt.two, BigInt.from(3)],
      [BigInt.from(3), BigInt.from(7)]
    ]);
    var calls = 0;
    db.functions.registerScalar('tick', 0, (_) => ++calls);
    await db.execute('UPDATE t SET x=(SELECT tick()+max(x) FROM t)');
    expect(calls, 1);
    expect((await db.query('SELECT x FROM t')).rows,
        List.filled(3, [BigInt.from(8)]));
  });

  test('self-correlated UPDATE and DELETE predicates select before mutations',
      () async {
    final db = await database();
    expect(
        (await db.execute('UPDATE t SET x=x+10 WHERE EXISTS('
                'SELECT 1 FROM t AS a WHERE a.x=t.x-1)'))
            .changes,
        2);
    expect((await db.query('SELECT x FROM t ORDER BY id')).rows, [
      [BigInt.one],
      [BigInt.from(12)],
      [BigInt.from(13)]
    ]);
    await db.execute('UPDATE t SET x=id');
    expect(
        (await db.execute('DELETE FROM t WHERE EXISTS('
                'SELECT 1 FROM t AS a WHERE a.x=t.x-1)'))
            .changes,
        2);
    expect((await db.query('SELECT id FROM t')).rows, [
      [BigInt.one]
    ]);
  });

  test('nested scalar callbacks and shared CTE materialization stay lazy',
      () async {
    final db = await database();
    var calls = 0;
    db.functions.registerScalar('tick', 0, (_) => ++calls);
    final nested = await db.execute('UPDATE t SET x=('
        'SELECT (SELECT tick())+t.id) RETURNING x');
    expect(nested.returning!.rows, [
      [BigInt.two],
      [BigInt.from(3)],
      [BigInt.from(4)]
    ]);
    expect(calls, 1);
    for (final entry in [
      ('', 'v+t.id', [2, 4, 6], 3),
      ('MATERIALIZED', 'v+t.id', [2, 3, 4], 1),
      ('', 'v', [2, 2, 2], 1),
      ('NOT MATERIALIZED', 'v', [3, 3, 3], 2),
    ]) {
      calls = 0;
      final expression = entry.$2 == 'v'
          ? '(SELECT v FROM q)+(SELECT v FROM q)'
          : '(SELECT ${entry.$2} FROM q)';
      final result =
          await db.execute('WITH q(v) AS ${entry.$1} (SELECT tick()) '
              'UPDATE t SET x=$expression RETURNING x');
      expect(result.returning!.rows,
          entry.$3.map((value) => [BigInt.from(value)]).toList(),
          reason: entry.toString());
      expect(calls, entry.$4, reason: entry.toString());
    }
  });

  test('correlated views refresh their dependency order after earlier rows',
      () async {
    final db = await database();
    await db.execute('CREATE VIEW first_view AS SELECT id,x FROM t');
    await db.execute('CREATE VIEW second_view AS SELECT id,x FROM first_view');
    final result = await db.execute('UPDATE t SET x=(SELECT sum(x) '
        'FROM second_view WHERE id<=t.id) RETURNING x');
    expect(result.returning!.rows, [
      [BigInt.one],
      [BigInt.from(3)],
      [BigInt.from(7)]
    ]);
  });

  test('self-reading INSERT VALUES materializes before row triggers', () async {
    final db = await database();
    await db.execute('CREATE TABLE audit(x)');
    await db.execute('CREATE TRIGGER ins AFTER INSERT ON t BEGIN '
        'INSERT INTO audit VALUES(new.x); END');
    final events = <String>[];
    db.functions.registerScalar('tick', 0, (_) {
      events.add('tick');
      return 10;
    });
    final result = await db.execute('INSERT INTO t(x) VALUES('
        '(SELECT max(x)+1 FROM t)),(tick()),((SELECT max(x)+1 FROM t)) RETURNING x');
    expect(result.returning!.rows, [
      [BigInt.from(4)],
      [BigInt.from(10)],
      [BigInt.from(4)]
    ]);
    expect(events, ['tick']);
    expect(
        (await db.query('SELECT x FROM audit')).rows, result.returning!.rows);
  });

  test('IN subqueries, aliases, parameters, UPSERT and RETURNING', () async {
    final db = await database();
    final result = await db.execute(
        'UPDATE t AS target SET x=('
        'SELECT a.x+? FROM t a WHERE a.id=target.id) '
        'WHERE id IN (SELECT id FROM t WHERE id>?) '
        'RETURNING id,x,(SELECT count(*) FROM t)',
        [10, 1]);
    expect(result.returning!.rows, [
      [BigInt.two, BigInt.from(12), BigInt.from(3)],
      [BigInt.from(3), BigInt.from(13), BigInt.from(3)]
    ]);
    final upsert = await db.execute('INSERT INTO t VALUES(1,99) '
        'ON CONFLICT(id) DO UPDATE SET x=(SELECT excluded.x+t.x) '
        'WHERE EXISTS(SELECT 1 WHERE excluded.x>t.x) RETURNING x');
    expect(upsert.returning!.rows, [
      [BigInt.from(100)]
    ]);
    expect(
        (await db.execute('DELETE FROM t AS target '
                'WHERE target.id IN (SELECT id FROM t WHERE x>50)'))
            .changes,
        1);
  });

  test('leading WITH mutations share parameter indices and support recursion',
      () async {
    final db = await database();
    expect(
        (await db.execute(
                'WITH q(v) AS (VALUES(?)) '
                'UPDATE t SET x=(SELECT v FROM q)+? WHERE id=? RETURNING x',
                [8, 2, 1]))
            .returning!
            .rows,
        [
          [BigInt.from(10)]
        ]);
    expect(
        (await db.execute('WITH RECURSIVE q(n) AS ('
                'VALUES(4) UNION ALL SELECT n+1 FROM q WHERE n<5) '
                'INSERT INTO t SELECT n,n*10 FROM q RETURNING id'))
            .returning!
            .rows,
        [
          [BigInt.from(4)],
          [BigInt.from(5)]
        ]);
    expect(
        (await db.execute(
                'WITH q AS (SELECT id FROM t WHERE id>?) '
                'DELETE FROM t WHERE id IN (SELECT id FROM q)',
                [3]))
            .changes,
        2);
    expect(
        (await db.execute(
                'WITH q(v) AS (VALUES(?)) '
                'INSERT INTO t(x) VALUES((SELECT v FROM q)) RETURNING x',
                [20]))
            .returning!
            .rows,
        [
          [BigInt.from(20)]
        ]);
  });

  test('subquery errors roll back writes and empty scalar results are NULL',
      () async {
    final db = await database();
    final before = db.exportImage();
    for (final sql in [
      'UPDATE t SET x=(SELECT id,x FROM t)',
      'UPDATE t SET x=(SELECT missing FROM t)',
      'DELETE FROM t WHERE id IN (SELECT id,x FROM t)',
      'INSERT INTO t(x) VALUES((SELECT id,x FROM t))',
      'UPDATE t SET x=CASE WHEN id=1 THEN 99 ELSE (SELECT abs(-9223372036854775808)) END',
      'WITH q AS (VALUES(1)),q AS (VALUES(2)) DELETE FROM t',
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before, reason: sql);
    }
    await db.execute('UPDATE t SET x=(SELECT x FROM t WHERE 0)');
    expect((await db.query('SELECT x FROM t')).rows, List.filled(3, [null]));
    expect(
        (await db.execute('DELETE FROM t WHERE id NOT IN (SELECT x FROM t)'))
            .changes,
        0);
  });
}
