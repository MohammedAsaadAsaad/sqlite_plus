import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('explicit fields and INTEGER PRIMARY KEY never evaluate their defaults',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var calls = 0;
    db.functions.registerScalar('tick', 0, (_) => ++calls);
    await db.execute(
        'CREATE TABLE t(id INTEGER PRIMARY KEY DEFAULT(tick()),x DEFAULT(tick()))');
    await db.execute('INSERT INTO t(x) VALUES(7),(8)');
    await db.execute('INSERT INTO t(rowid,x) VALUES(10,9)');
    expect(calls, 0);
    expect((await db.query('SELECT * FROM t')).rows, [
      [BigInt.one, BigInt.from(7)],
      [BigInt.two, BigInt.from(8)],
      [BigInt.from(10), BigInt.from(9)]
    ]);
    await db.execute('INSERT INTO t DEFAULT VALUES');
    expect(calls, 1);
    expect((await db.query('SELECT * FROM t WHERE id=11')).rows, [
      [BigInt.from(11), BigInt.one]
    ]);
  });

  test('RETURNING and triggers materialize VALUES before omitted defaults',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var calls = 0;
    db.functions.registerScalar('tick', 0, (_) => ++calls);
    await db.execute('CREATE TABLE t(x DEFAULT(tick()),y DEFAULT(tick()))');
    final first = await db
        .execute('INSERT INTO t(y) VALUES(tick()),(tick()) RETURNING *');
    expect(first.returning!.rows, [
      [BigInt.from(3), BigInt.one],
      [BigInt.from(4), BigInt.two]
    ]);
    calls = 0;
    await db.execute('CREATE TABLE audit(x)');
    await db.execute(
        'CREATE TRIGGER changed AFTER INSERT ON t BEGIN INSERT INTO audit VALUES(new.x); END');
    final triggered = await db
        .execute('INSERT INTO t(y) VALUES(tick()),(tick()) RETURNING *');
    expect(triggered.returning!.rows, [
      [BigInt.from(3), BigInt.one],
      [BigInt.from(4), BigInt.two]
    ]);
    expect(calls, 4);
    expect((await db.query('SELECT * FROM audit')).rows, [
      [BigInt.from(3)],
      [BigInt.from(4)]
    ]);
  });

  test('UPSERT evaluates missing defaults before conflict handling only',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var calls = 0;
    db.functions.registerScalar('tick', 0, (_) => ++calls);
    await db.execute('CREATE TABLE t(id PRIMARY KEY,x DEFAULT(tick()))');
    await db.execute('INSERT INTO t VALUES(1,100)');
    expect(calls, 0);
    await db.execute('INSERT INTO t(id) VALUES(1) ON CONFLICT DO NOTHING');
    expect(calls, 1);
    await db.execute('INSERT INTO t VALUES(1,101) ON CONFLICT DO NOTHING');
    expect(calls, 1);
    expect(
        (await db.execute(
                'INSERT INTO t(id) VALUES(1) ON CONFLICT DO UPDATE SET x=excluded.x RETURNING x'))
            .returning!
            .rows,
        [
          [BigInt.two]
        ]);
    expect(calls, 2);
  });

  test('unused fatal defaults are ignored and required failures stay atomic',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x DEFAULT(abs(-9223372036854775808)))');
    await db.execute('INSERT INTO t VALUES(1),(2)');
    final before = db.exportImage();
    await expectLater(db.execute('INSERT INTO t DEFAULT VALUES'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), before);
    expect((await db.query('SELECT * FROM t')).rows, [
      [BigInt.one],
      [BigInt.two]
    ]);
  });
}
