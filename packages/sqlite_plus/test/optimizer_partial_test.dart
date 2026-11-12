@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final type in ['TEXT', 'INT']) {
    test('partial implication follows $type affinity', () async {
      final db = await MutableSqliteDatabase.create();
      addTearDown(db.close);
      final statements = [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a $type)',
        "INSERT INTO t VALUES(1,'15'),(2,'3'),(3,'2')",
        'CREATE INDEX partial ON t(a) WHERE a>2'
      ];
      for (final s in statements) {
        await db.execute(s);
      }
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      for (final sql in [
        'SELECT a FROM t WHERE a>10 ORDER BY a',
        'SELECT a FROM t WHERE a>2 ORDER BY a',
        'SELECT a FROM t WHERE a=15 ORDER BY a',
        'SELECT a FROM t WHERE a>=2 ORDER BY a'
      ]) {
        final expected = await optimizerOracle(statements.join(';'), sql);
        expect((await db.query(sql)).rows, expected, reason: sql);
        expect((await ro.query(sql)).rows, expected, reason: sql);
      }
      expect(ro.explain('SELECT a FROM t WHERE a>10 ORDER BY a').indexName,
          type == 'INT' ? 'partial' : null);
    });
  }
}
