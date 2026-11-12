@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  for (final encoding in [1, 2, 3]) {
    test('MIN MAX shortcuts honor shadowed rowids $encoding', () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      const setup =
          "CREATE TABLE t(id INTEGER PRIMARY KEY,rowid TEXT,oid TEXT,_rowid_ TEXT); INSERT INTO t VALUES(1,'z','o','u'),(2,'a','a','a')";
      await db.execute(
          'CREATE TABLE t(id INTEGER PRIMARY KEY,rowid TEXT,oid TEXT,_rowid_ TEXT)');
      await db.execute("INSERT INTO t VALUES(1,'z','o','u'),(2,'a','a','a')");
      final ro =
          await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
      addTearDown(ro.close);
      for (final sql in [
        'SELECT min(rowid) AS v FROM t',
        'SELECT max(rowid) AS v FROM t',
        'SELECT min(oid) AS v FROM t',
        'SELECT max(_rowid_) AS v FROM t',
        'SELECT min(id) AS v FROM t',
        'SELECT max(id) AS v FROM t',
        'SELECT min(id) AS v FROM t WHERE 0'
      ]) {
        final expected = await optimizerOracle(setup, sql);
        expect((await db.query(sql)).rows, expected, reason: sql);
        expect((await ro.query(sql)).rows, expected, reason: sql);
      }
      db.functions.registerScalar(
          'min', 1, (args) => (args.single as BigInt) * BigInt.from(10));
      expect((await db.query('SELECT min(id) AS v FROM t')).rows, [
        [BigInt.from(10)],
        [BigInt.from(20)]
      ]);
    });
  }
}
