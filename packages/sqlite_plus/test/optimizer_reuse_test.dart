import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    test('shared subqueries distinguish semantic shape and binding $encoding',
        () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      const setup =
          'CREATE TABLE t(id INTEGER PRIMARY KEY,a INT); INSERT INTO t VALUES(1,10),(2,20),(3,10)';
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,a INT)');
      await db.execute('INSERT INTO t VALUES(1,10),(2,20),(3,10)');
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      for (final sql in [
        'SELECT (SELECT a FROM t LIMIT 1) AS x,(SELECT a FROM t LIMIT 1 OFFSET 1) AS y',
        'SELECT (SELECT count(*) FROM t LIMIT 0) AS x,(SELECT count(*) FROM t LIMIT 1) AS y',
        'SELECT (SELECT sum(a) AS n FROM t) AS x,(SELECT sum(DISTINCT a) AS n FROM t) AS y',
        'SELECT (SELECT a IN (10) AS v FROM t LIMIT 1) AS x,(SELECT a NOT IN (10) AS v FROM t LIMIT 1) AS y',
        'SELECT (SELECT CAST(a AS TEXT) AS v FROM t LIMIT 1) AS x,(SELECT CAST(a AS INTEGER) AS v FROM t LIMIT 1) AS y',
        "SELECT (SELECT 1 AS v) AS x,(SELECT '1' AS v) AS y",
        "SELECT (SELECT 'A' COLLATE NOCASE AS v)='a' AS x,(SELECT 'A' COLLATE BINARY AS v)='a' AS y",
        'SELECT (SELECT count(*) FROM t) AS x,(SELECT count(*) FROM t) AS y'
      ]) {
        final expected = await optimizerOracle(setup, sql);
        expect((await db.query(sql)).rows, expected, reason: sql);
        expect((await ro.query(sql)).rows, expected, reason: sql);
      }
      final expected = await optimizerOracle(setup,
          'SELECT (SELECT a FROM t WHERE id=1) AS x,(SELECT a FROM t WHERE id=2) AS y');
      const bound =
          'SELECT (SELECT a FROM t WHERE id=?1) AS x,(SELECT a FROM t WHERE id=?2) AS y';
      expect((await db.query(bound, [1, 2])).rows, expected);
      expect((await ro.query(bound, [1, 2])).rows, expected);
    });
  }
}
