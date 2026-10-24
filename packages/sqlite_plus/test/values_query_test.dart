import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

void main() {
  test('VALUES parameters, CTEs, views and trigger bodies retain context',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final result = await db.query('VALUES(?,?),(?,?)', [1, 'λ😀', 2, null]);
    expect(result.columns, ['column1', 'column2']);
    expect(result.rows, [
      [BigInt.one, 'λ😀'],
      [BigInt.two, null]
    ]);
    expect(
        (await db.query(
                'WITH c(a,b) AS(VALUES(?,?),(?,?)) SELECT a,b FROM c ORDER BY a DESC',
                [1, 'one', 2, 'two']))
            .rows,
        [
          [BigInt.two, 'two'],
          [BigInt.one, 'one']
        ]);
    await db.execute('CREATE VIEW v AS VALUES(1),(2)');
    expect((await db.query('SELECT * FROM v')).rows, [
      [BigInt.one],
      [BigInt.two]
    ]);
    await db.execute('CREATE TABLE t(x INT)');
    await db.execute(
        "CREATE TRIGGER guard BEFORE INSERT ON t WHEN new.x<0 BEGIN VALUES(RAISE(ABORT,'negative')); END");
    await db.execute('INSERT INTO t SELECT * FROM v');
    final image = db.exportImage();
    await expectLater(
        db.execute('INSERT INTO t VALUES(-1)'), throwsA(isA<SqlException>()));
    expect(db.exportImage(), image);
    expect((await db.query('SELECT x,(VALUES(x+1)) FROM t ORDER BY x')).rows, [
      [BigInt.one, BigInt.two],
      [BigInt.two, BigInt.from(3)]
    ]);
  });

  test('VALUES grammar rejects wrong widths and terminal ORDER or LIMIT',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    for (final sql in [
      'VALUES()',
      'VALUES(1),(1,2)',
      'VALUES(1) ORDER BY 1',
      'VALUES(1) LIMIT 0',
      'SELECT 1 UNION VALUES(2) LIMIT 1',
      'VALUES(sum(1)),(sum(2))'
    ]) {
      await expectLater(db.query(sql), throwsA(isA<SqlException>()));
    }
    expect((await db.query('VALUES(sum(1))')).rows, [
      [BigInt.one]
    ]);
    expect(
        (await db.query('VALUES(1),(2) UNION SELECT 3 ORDER BY 1 DESC LIMIT 2'))
            .rows,
        [
          [BigInt.from(3)],
          [BigInt.two]
        ]);
    expect(
        (await db.query(
                'WITH RECURSIVE c(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM c LIMIT 3) SELECT x FROM c'))
            .rows,
        [
          [BigInt.one],
          [BigInt.two],
          [BigInt.from(3)]
        ]);
  });
}
