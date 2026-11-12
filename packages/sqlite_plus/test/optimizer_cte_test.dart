@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  test('inner ordered LIMIT precedes an independent outer order', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const setup =
        'CREATE TABLE t(a INT,b INT); INSERT INTO t VALUES(10,30),(20,10),(30,20)';
    await db.execute('CREATE TABLE t(a INT,b INT)');
    await db.execute('INSERT INTO t VALUES(10,30),(20,10),(30,20)');
    final ro =
        await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
    addTearDown(ro.close);
    for (final sql in [
      'SELECT a FROM (SELECT a,b FROM t ORDER BY b LIMIT 2) AS x ORDER BY a',
      'SELECT a FROM (SELECT a,b FROM t ORDER BY b LIMIT 2 OFFSET 1) AS x ORDER BY a DESC',
      'WITH c AS (SELECT a,b FROM t ORDER BY b LIMIT 2) SELECT a FROM c ORDER BY a',
      'SELECT a FROM (SELECT a,b FROM t ORDER BY b LIMIT 2) AS x WHERE a>20 ORDER BY a'
    ]) {
      final expected = await optimizerOracle(setup, sql);
      expect((await db.query(sql)).rows, expected, reason: sql);
      expect((await ro.query(sql)).rows, expected, reason: sql);
    }
  });
}
