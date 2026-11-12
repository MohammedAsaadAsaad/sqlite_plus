@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final type in ['TEXT', 'INT', '']) {
    test('contradiction proof respects $type comparisons', () async {
      final db = await MutableSqliteDatabase.create();
      addTearDown(db.close);
      final statements = [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a $type)',
        "INSERT INTO t VALUES(1,'15'),(2,'3'),(3,'2')"
      ];
      for (final s in statements) {
        await db.execute(s);
      }
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      for (final sql in [
        'SELECT a FROM t WHERE a>10 AND a<2 ORDER BY id',
        "SELECT a FROM t WHERE a>'10' AND a<'2' ORDER BY id",
        'SELECT count(*) AS n FROM t WHERE a>2 AND a<2',
        'SELECT id FROM t WHERE (a>2 AND a<2) OR id=2 ORDER BY id',
        'SELECT count(*) AS n FROM t WHERE 0'
      ]) {
        final expected = await optimizerOracle(statements.join(';'), sql);
        expect((await db.query(sql)).rows, expected, reason: sql);
        expect((await ro.query(sql)).rows, expected, reason: sql);
      }
    });
  }
}
