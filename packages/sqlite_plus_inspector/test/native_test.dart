@TestOn('linux')
library;

import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'package:test/test.dart';

void main() {
  test('explicit index/covering plan and result agree with pinned SQLite',
      () async {
    final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
        '/tmp/sqlite-build/sqlite3';
    final pin =
        await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
    expect(pin.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
    final engine = await openInMemory();
    addTearDown(engine.close);
    const schema = 'CREATE TABLE items(id INTEGER PRIMARY KEY,n INTEGER)';
    const index = 'CREATE INDEX ix ON items(n)';
    const seed = 'INSERT INTO items VALUES(1,7),(2,8),(3,7)';
    for (final sql in [schema, index, seed]) {
      await engine.execute(sql);
    }
    final inspector = SqlInspector();
    final db = inspector.database(engine);
    final before = engine.exportImage();
    final plan = await db.explain('SELECT id,n FROM items WHERE n=?', [7]);
    final native = await Process.run(cli, [
      ':memory:',
      '$schema;$index;$seed;EXPLAIN QUERY PLAN SELECT id,n FROM items WHERE n=7;SELECT id,n FROM items WHERE n=7 ORDER BY id;'
    ]);
    expect(native.exitCode, 0, reason: native.stderr.toString());
    expect(native.stdout.toString(), contains('USING COVERING INDEX ix (n=?)'));
    expect(plan.indexName, 'ix');
    expect(plan.covering, isTrue);
    final rows =
        await db.query('SELECT id,n FROM items WHERE n=? ORDER BY id', [7]);
    expect(rows.rows, [
      [BigInt.one, BigInt.from(7)],
      [BigInt.from(3), BigInt.from(7)]
    ]);
    expect(native.stdout.toString().trim(), endsWith('1|7\n3|7'));
    expect(engine.exportImage(), before);
    expect(inspector.snapshot().queryCount, 1);
  });
}
