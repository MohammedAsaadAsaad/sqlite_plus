import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('recursive queue parameters, offsets and writes use extracted rows',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x INT)');
    final result = await db.execute(
        'INSERT INTO t '
        'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT ? OFFSET ?) '
        'SELECT x FROM c RETURNING x',
        [3, 2]);
    expect(result.returning!.rows, [
      [BigInt.from(3)],
      [BigInt.from(4)],
      [BigInt.from(5)]
    ]);
    expect((await db.query('SELECT sum(x) FROM t')).rows, [
      [BigInt.from(12)]
    ]);
    final image = db.exportImage();
    await expectLater(
        db.execute('INSERT INTO t WITH RECURSIVE c(x) AS('
            'SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT NULL) SELECT x FROM c'),
        throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    var calls = 0;
    db.functions.registerScalar('counter', 0, (args) => ++calls);
    expect(
        (await db.query('WITH RECURSIVE c(x) AS(SELECT counter() '
                'UNION ALL SELECT x+1 FROM c LIMIT 0) SELECT x FROM c'))
            .rows,
        isEmpty);
    expect(calls, 0);
    expect(
        (await db.query('WITH c(x) AS(SELECT counter()) SELECT x FROM c')).rows,
        [
          [BigInt.one]
        ]);
    expect(calls, 1);
  });

  test('recursive row budget accepts the boundary and rejects one more',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final result = await db.query('WITH RECURSIVE c(x) AS(SELECT 1 '
        'UNION ALL SELECT x+1 FROM c LIMIT 100000) SELECT count(*),max(x) FROM c');
    expect(result.rows, [
      [BigInt.from(100000), BigInt.from(100000)]
    ]);
    await expectLater(
        db.query('WITH RECURSIVE c(x) AS(SELECT 1 '
            'UNION ALL SELECT x+1 FROM c LIMIT 100001) SELECT count(*) FROM c'),
        throwsA(isA<SqlException>()));
  });
}
