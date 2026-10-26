import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';
import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(
      File('test/fixtures/pragma_table_oracle.json').readAsStringSync()) as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final encoding in [1, 2, 3]) {
    test('metadata PRAGMA table sources encoding $encoding', () async {
      expect(oracle['source_id'], manifest['source_id']);
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      final calls = <Object?>[];
      db.functions.registerScalar('probe', 1, (arguments) {
        calls.add(arguments.single);
        return arguments.single;
      });
      for (final sql in oracle['setup'] as List) {
        await db.execute(sql as String);
      }
      for (final entry in oracle['cases'] as List) {
        final sql = entry['sql'] as String;
        final parameters = (entry['parameters'] as List).cast<Object?>();
        calls.clear();
        if (entry.containsKey('error')) {
          await expectLater(
              db.query(sql, parameters), throwsA(isA<SqlException>()),
              reason: sql);
        } else {
          final result = await db.query(sql, parameters);
          expect(result.columns, entry['columns'], reason: sql);
          expect(
              result.rows,
              (entry['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList(),
              reason: sql);
        }
        if (entry.containsKey('calls')) {
          expect(calls, (entry['calls'] as List).map(expectedValue).toList(),
              reason: sql);
        }
      }
    });
    test('PRAGMA source schema dependencies encoding $encoding', () async {
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      for (final sql in oracle['setup'] as List) {
        await db.execute(sql as String);
      }
      for (final operation in oracle['schema_operations'] as List) {
        final sql = operation['sql'] as String;
        if (operation.containsKey('error')) {
          await expectLater(
              operation['query'] as bool ? db.query(sql) : db.execute(sql),
              throwsA(isA<SqlException>()),
              reason: sql);
        } else if (operation['query'] as bool) {
          final result = await db.query(sql);
          expect(result.columns, operation['columns'], reason: sql);
          expect(
              result.rows,
              (operation['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList(),
              reason: sql);
        } else {
          await db.execute(sql);
        }
      }
    });
  }

  test('PRAGMA source preparation never invokes argument callbacks', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(a,b)');
    await db.execute('CREATE TABLE empty(n)');
    var calls = 0;
    db.functions.registerScalar('probe', 0, (arguments) {
      calls++;
      return 't';
    });
    final skipped =
        await db.query('SELECT * FROM pragma_table_info(probe()) LIMIT 0');
    expect(skipped.columns,
        ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk']);
    expect(skipped.rows, isEmpty);
    expect(calls, 0);
    final empty =
        await db.query('SELECT * FROM empty,pragma_table_info(probe())');
    expect(empty.columns.length, 7);
    expect(empty.rows, isEmpty);
    expect(calls, 0);
    final result =
        await db.query('SELECT name FROM pragma_table_info(probe())');
    expect(result.rows, [
      ['a'],
      ['b']
    ]);
    expect(calls, 1);
    await db
        .execute('CREATE VIEW v AS SELECT * FROM pragma_table_info(probe())');
    final metadata = await db.query("PRAGMA table_info('v')");
    expect(metadata.rows.length, 6);
    expect(calls, 1);
  });

  test('unsupported table functions and lateral scopes reject explicitly',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(n)');
    await db.execute("INSERT INTO t VALUES('t')");
    for (final sql in [
      'SELECT * FROM pragma_foreign_keys()',
      'SELECT * FROM pragma_integrity_check()',
      'SELECT * FROM arbitrary_function()',
      'SELECT * FROM pragma_table_info(t.n),t',
      'SELECT * FROM t RIGHT JOIN pragma_table_info(t.n)',
      'SELECT * FROM t FULL JOIN pragma_table_info(t.n)',
    ]) {
      await expectLater(db.query(sql), throwsA(isA<SqlException>()),
          reason: sql);
    }
    await db.execute('CREATE TABLE pragma_table_info(x)');
    await db.execute('INSERT INTO pragma_table_info VALUES(9)');
    expect((await db.query('SELECT * FROM pragma_table_info')).rows, [
      [BigInt.from(9)]
    ]);
    await expectLater(db.query("SELECT * FROM pragma_table_info('t')"),
        throwsA(isA<SqlException>()));
  });
}
