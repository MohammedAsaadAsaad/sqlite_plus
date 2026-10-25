import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('DML checks wildcard scalar and IN widths before scanning empty targets',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x)');
    await db.execute('CREATE TABLE pair(a,b)');
    final before = db.exportImage();
    for (final sql in [
      'UPDATE t SET x=(SELECT * FROM pair)',
      'UPDATE t SET x=CASE WHEN 0 THEN (SELECT * FROM pair) ELSE 1 END',
      'DELETE FROM t WHERE x IN (SELECT * FROM pair)',
      'DELETE FROM t WHERE (x,x) IN (SELECT a FROM pair)',
      'INSERT INTO t VALUES(CASE WHEN 0 THEN (SELECT * FROM pair) ELSE 1 END)',
    ]) {
      await expectLater(db.execute(sql), throwsA(isA<SqlException>()),
          reason: sql);
      expect(db.exportImage(), before, reason: sql);
    }
    expect(
        (await db.execute('UPDATE t SET x=(SELECT a FROM pair)')).changes, 0);
    await db.execute('INSERT INTO t VALUES((SELECT a FROM pair))');
    expect((await db.query('SELECT * FROM t')).rows, [
      [null]
    ]);
  });

  test('view callbacks are lazy across unused scalar query and mutation paths',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x)');
    var calls = 0;
    db.functions.registerScalar('tick', 0, (_) => ++calls);
    await db.execute('CREATE VIEW v AS SELECT tick() AS x');
    expect(
        (await db.query('SELECT CASE WHEN 0 THEN (SELECT x FROM v) ELSE 7 END'))
            .rows,
        [
          [BigInt.from(7)]
        ]);
    expect(calls, 0);
    await db.execute('UPDATE t SET x=(SELECT x FROM v)');
    await db.execute('DELETE FROM t WHERE x IN (SELECT x FROM v)');
    expect(calls, 0);
    await db.execute(
        'INSERT INTO t VALUES(CASE WHEN 0 THEN (SELECT x FROM v) ELSE 7 END)');
    expect(calls, 0);
    await db.execute(
        'UPDATE t SET x=CASE WHEN 0 THEN (SELECT x FROM v) ELSE x END');
    expect(calls, 0);
    expect((await db.query('SELECT (SELECT x FROM v)')).rows, [
      [BigInt.one]
    ]);
    expect(calls, 1);
    await db.execute('UPDATE t SET x=(SELECT x FROM v) RETURNING x');
    expect(calls, 2);
    expect((await db.query('SELECT x FROM t')).rows, [
      [BigInt.two]
    ]);
  });

  test('unconsumed sibling views do not execute during nested mutations',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,x)');
    await db.execute('INSERT INTO t VALUES(1,1),(2,2)');
    var calls = 0;
    db.functions.registerScalar('tick', 0, (_) => ++calls);
    await db.execute('CREATE VIEW used AS SELECT tick() AS x');
    await db.execute('CREATE VIEW unused AS SELECT tick() AS x');
    final result = await db.execute('UPDATE t SET x=(SELECT CASE WHEN t.id>0 '
        'THEN (SELECT x FROM used) ELSE (SELECT x FROM unused) END) RETURNING x');
    expect(result.returning!.rows, [
      [BigInt.one],
      [BigInt.one]
    ]);
    expect(calls, 1);
  });
}
