@TestOn('linux')
library;

import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';
import 'package:test/test.dart';

void main() {
  test('advised index SQL and ordered results match pinned native SQLite',
      () async {
    final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
        '/tmp/sqlite-build/sqlite3';
    final pin =
        await Process.run(cli, [':memory:', 'SELECT sqlite_source_id();']);
    expect(pin.stdout.toString().trim(),
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
    final db = await openInMemory();
    final inspector = SqlInspector();
    const schema =
        'CREATE TABLE items(id INTEGER PRIMARY KEY,tenant INTEGER,n INTEGER)';
    final seed = 'INSERT INTO items VALUES ${[
      for (var i = 1; i <= 100; i++) '($i,${i % 5},$i)'
    ].join(',')}';
    const query =
        'SELECT id,n FROM items WHERE tenant=2 AND n>=50 ORDER BY n DESC';
    try {
      await db.execute(schema);
      await db.execute(seed);
      final report = await inspector.adviseIndex(db, query);
      final advice = report.advice!;
      expect(advice.selectedByPlanner, isTrue);
      final native = await Process.run(cli, [
        '-json',
        ':memory:',
        '$schema; $seed; ${advice.createSql}; $query;'
      ]);
      expect(native.exitCode, 0, reason: native.stderr.toString());
      final expected = (jsonDecode(native.stdout as String) as List)
          .map((r) => (r as Map).values.toList())
          .toList();
      expect(
          (await db.query(query))
              .rows
              .map((r) => r.map((v) => (v as BigInt).toInt()).toList())
              .toList(),
          expected);
      final plan = await Process.run(cli, [
        ':memory:',
        '$schema; $seed; ${advice.createSql}; EXPLAIN QUERY PLAN $query;'
      ]);
      expect(plan.stdout.toString(), contains(advice.indexName));
    } finally {
      inspector.close();
      await db.close();
    }
  });
}
