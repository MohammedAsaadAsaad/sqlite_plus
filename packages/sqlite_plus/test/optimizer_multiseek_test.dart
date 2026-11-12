@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final collation in ['BINARY', 'NOCASE']) {
    test('IN OR probes require comparison collation $collation', () async {
      final db = await MutableSqliteDatabase.create();
      addTearDown(db.close);
      final statements = [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a TEXT COLLATE BINARY)',
        "INSERT INTO t VALUES(1,'A'),(2,'a'),(3,'b'),(4,NULL)",
        'CREATE INDEX ia ON t(a COLLATE $collation)'
      ];
      for (final s in statements) {
        await db.execute(s);
      }
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      for (final sql in [
        "SELECT a FROM t WHERE a COLLATE NOCASE='a' OR a COLLATE NOCASE='b' ORDER BY id",
        "SELECT a FROM t WHERE a COLLATE NOCASE IN ('a','b') ORDER BY id",
        "SELECT a FROM t WHERE a='a' COLLATE NOCASE OR a='b' COLLATE NOCASE ORDER BY id",
        "SELECT a FROM t WHERE a IN ('a','b',NULL,'a') ORDER BY id",
        "SELECT a FROM t WHERE a='a' OR a='b' ORDER BY id"
      ]) {
        // Pinned SQLite itself drops A for RHS COLLATE after OR-to-IN rewriting.
        // Its NOT INDEXED execution preserves the comparison's declared semantics.
        final expected = await optimizerOracle(statements.join(';'),
            sql.replaceFirst('FROM t', 'FROM t NOT INDEXED'));
        expect((await db.query(sql)).rows, expected, reason: sql);
        expect((await ro.query(sql)).rows, expected, reason: sql);
      }
    });
  }
}
