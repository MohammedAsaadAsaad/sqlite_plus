@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    test('covering requires all consumer columns and genuine rowids $encoding',
        () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      final statements = [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,a INT,b INT,rowid TEXT,oid TEXT,_rowid_ TEXT)',
        "INSERT INTO t VALUES(1,1,30,'r1','o1','u1'),(2,2,10,'r2','o2','u2'),(3,3,20,'r3','o3','u3')",
        'CREATE INDEX ia ON t(a)'
      ];
      for (final s in statements) {
        await db.execute(s);
      }
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      for (final sql in [
        'SELECT a FROM t WHERE a>0 ORDER BY b',
        'SELECT a FROM t WHERE a>0 GROUP BY b HAVING b>15 ORDER BY b',
        'SELECT a FROM t WHERE a>0 ORDER BY b LIMIT 2 OFFSET 1',
        'SELECT rowid,oid,_rowid_ FROM t WHERE a=1',
        'SELECT a FROM t WHERE a=1 AND rowid IS NOT NULL',
        'SELECT a,id FROM t WHERE a=1'
      ]) {
        final expected = await optimizerOracle(statements.join(';'), sql);
        expect((await db.query(sql)).rows, expected, reason: sql);
        expect((await ro.query(sql)).rows, expected, reason: sql);
      }
      expect(
          ro.explain('SELECT a FROM t WHERE a>0 ORDER BY b').covering, isFalse);
      expect(ro.explain('SELECT a,id FROM t WHERE a=1').covering, isTrue);
    });
  }
}
