@TestOn('linux')
library;

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'support/optimizer_oracle.dart';

void main() {
  test('join planning preserves wildcard column and ordinal order', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    const statements = [
      'CREATE TABLE t(a INT)',
      'CREATE TABLE s(b INT)',
      'INSERT INTO t VALUES(2),(1)',
      'INSERT INTO s VALUES(9)',
      'ANALYZE'
    ];
    for (final s in statements) {
      await db.execute(s);
    }
    final ro =
        await SqliteDatabase.openReadOnly(ByteImageStorage(db.exportImage()));
    addTearDown(ro.close);
    for (final sql in [
      'SELECT * FROM t CROSS JOIN s ORDER BY t.a',
      'SELECT * FROM t CROSS JOIN s ORDER BY 1',
      'SELECT s.*,t.* FROM t CROSS JOIN s ORDER BY t.a',
      'SELECT t.a,s.b FROM t CROSS JOIN s ORDER BY t.a'
    ]) {
      final expected = await optimizerOracle(statements.join(';'), sql);
      expect((await db.query(sql)).rows, expected, reason: sql);
      expect((await ro.query(sql)).rows, expected, reason: sql);
    }
    expect(
        (await ro.query('SELECT * FROM t CROSS JOIN s ORDER BY t.a')).columns,
        ['a', 'b']);
    expect(
        (await ro.query('SELECT s.*,t.* FROM t CROSS JOIN s ORDER BY t.a'))
            .columns,
        ['b', 'a']);
  });
}
