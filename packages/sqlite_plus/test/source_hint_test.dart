import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(
      File('test/fixtures/source_hint_oracle.json').readAsStringSync()) as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final encoding in [1, 2, 3]) {
    test('main-qualified sources and mandatory index hints encoding $encoding',
        () async {
      expect(oracle['source_id'], manifest['source_id']);
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      for (final sql in oracle['setup'] as List) {
        await db.execute(sql as String);
      }
      for (final entry in oracle['cases'] as List) {
        final sql = entry['sql'] as String;
        Future<Object> run() =>
            entry['mode'] == 'query' ? db.query(sql) : db.execute(sql);
        if (entry.containsKey('error')) {
          await expectLater(run(), throwsA(isA<SqlException>()), reason: sql);
        } else {
          final result = await run();
          if (result is QueryResult) {
            expect(result.columns, entry['columns'], reason: sql);
            expect(
                result.rows,
                (entry['rows'] as List)
                    .map((row) => (row as List).map(expectedValue).toList())
                    .toList(),
                reason: sql);
          }
        }
      }
    });
  }
  test('index hints constrain the exposed physical query plan', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,x,n)');
    await db.execute('CREATE INDEX ix ON t(x)');
    await db.execute('CREATE INDEX inn ON t(n)');
    final storage = MemoryStorageBackend();
    await storage.write(0, db.exportImage());
    final ro = await SqliteDatabase.openReadOnly(storage);
    addTearDown(ro.close);
    expect(
        ro.explain('SELECT * FROM t INDEXED BY ix WHERE id=1').indexName, 'ix');
    expect(ro.explain('SELECT * FROM t INDEXED BY inn WHERE x=1').indexName,
        'inn');
    expect(
        ro.explain('SELECT * FROM t NOT INDEXED WHERE x=1').indexName, isNull);
    expect(ro.explain('SELECT * FROM t NOT INDEXED WHERE id=1').access,
        'rowid-lookup');
  });
}
