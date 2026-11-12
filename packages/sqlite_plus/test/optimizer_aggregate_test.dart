@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    test('streamed aggregates preserve HAVING keys and NULL extrema $encoding',
        () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      const setup =
          'CREATE TABLE t(id INTEGER PRIMARY KEY,y,v); INSERT INTO t VALUES(1,1,NULL),(2,1,NULL),(3,2,NULL),(4,2,NULL)';
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,y,v)');
      await db.execute(
          'INSERT INTO t VALUES(1,1,NULL),(2,1,NULL),(3,2,NULL),(4,2,NULL)');
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      for (final sql in [
        'SELECT sum(id) AS n FROM t GROUP BY y HAVING y=1',
        'SELECT id,min(v) AS m FROM t',
        'SELECT id,max(v) FILTER(WHERE id<3) AS m FROM t',
        'SELECT sum(id),count(v),avg(v),total(v) FROM t WHERE 0'
      ]) {
        final expected = await optimizerOracle(setup, sql);
        expect((await db.query(sql)).rows, expected, reason: sql);
        expect((await ro.query(sql)).rows, expected, reason: sql);
      }
    });
  }
}
