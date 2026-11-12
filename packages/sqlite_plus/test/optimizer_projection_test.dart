import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    test('pruning preserves named CTE fields and nested correlations $encoding',
        () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      await db.execute('CREATE TABLE t(a INT,b INT)');
      await db.execute('INSERT INTO t VALUES(1,30),(2,10),(3,20)');
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      const setup =
          'CREATE TABLE t(a INT,b INT); INSERT INTO t VALUES(1,30),(2,10),(3,20)';
      for (final sql in [
        'WITH c(x) AS (SELECT b FROM t LIMIT 2 OFFSET 0) SELECT x FROM c WHERE x>0 ORDER BY x',
        'SELECT x.a,(SELECT x.b+1) AS v FROM (SELECT a,b FROM t LIMIT 2 OFFSET 0) AS x ORDER BY x.a',
        'SELECT a FROM (SELECT a,b FROM t LIMIT 2 OFFSET 0) AS x ORDER BY a'
      ]) {
        final expected = await optimizerOracle(setup, sql);
        expect((await db.query(sql)).rows, expected);
        expect((await ro.query(sql)).rows, expected);
      }
      for (final query in [db.query, ro.query]) {
        expect(
            (await query('WITH c(x) AS (SELECT b FROM t LIMIT 2 OFFSET 0) '
                    'SELECT x FROM c WHERE x>0 ORDER BY x'))
                .rows,
            [
              [BigInt.from(10)],
              [BigInt.from(30)]
            ]);
        expect(
            (await query('SELECT x.a,(SELECT x.b+1) AS v FROM '
                    '(SELECT a,b FROM t LIMIT 2 OFFSET 0) AS x ORDER BY x.a'))
                .rows,
            [
              [BigInt.one, BigInt.from(31)],
              [BigInt.two, BigInt.from(11)]
            ]);
        expect(
            (await query('SELECT a FROM (SELECT a,b FROM t LIMIT 2 OFFSET 0) '
                    'AS x ORDER BY a'))
                .rows,
            [
              [BigInt.one],
              [BigInt.two]
            ]);
      }
    });
  }
}
