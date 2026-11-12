@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    test('constant CAST and COLLATE preserve derived metadata $encoding',
        () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      for (final sql in [
        "SELECT v FROM (SELECT CAST(1 AS INTEGER) AS v) WHERE v='1'",
        "SELECT v FROM (SELECT CAST(1 AS TEXT) AS v) WHERE v=1",
        "SELECT v FROM (SELECT 'A' COLLATE NOCASE AS v) WHERE v='a'",
        "WITH c(v) AS (SELECT 'a' COLLATE NOCASE) SELECT v='A' AS result FROM c",
        "WITH RECURSIVE c(x) AS (SELECT 'a' COLLATE NOCASE UNION SELECT 'A' FROM c LIMIT 5) SELECT x FROM c",
        'SELECT 1+2 AS x,8/2 AS y,typeof(1+2) AS z',
        'SELECT 1+1 AS x UNION ALL SELECT 2+2 ORDER BY 1+1 DESC',
        'SELECT 1+1 AS x UNION ALL SELECT 2+2 ORDER BY 2+2 DESC',
        'SELECT 1+1 AS x UNION ALL SELECT 2+2 ORDER BY x DESC'
      ]) {
        final expected = await optimizerOracle('', sql);
        expect((await db.query(sql)).rows, expected, reason: sql);
        expect((await ro.query(sql)).rows, expected, reason: sql);
      }
    });
  }
}
