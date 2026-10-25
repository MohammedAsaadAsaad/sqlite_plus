import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle =
      jsonDecode(File('test/fixtures/row_value_oracle.json').readAsStringSync())
          as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  late MutableSqliteDatabase db;
  var callbackCount = 0;
  setUpAll(() async {
    expect(oracle['source_id'], manifest['source_id']);
    db = await MutableSqliteDatabase.create();
    db.functions.registerScalar('row_counter', 0, (_) => ++callbackCount);
    for (final sql in oracle['setup'] as List) {
      await db.execute(sql as String);
    }
  });
  tearDownAll(() => db.close());

  for (final entry in oracle['cases'] as List) {
    test('pinned row value: ${entry['sql']}', () async {
      callbackCount = 0;
      if (entry.containsKey('error')) {
        await expectLater(
            db.query(entry['sql'] as String), throwsA(isA<SqlException>()));
      } else {
        final result = await db.query(entry['sql'] as String);
        expect(result.columns, entry['columns']);
        expect(
            result.rows,
            (entry['rows'] as List)
                .map((row) => (row as List).map(expectedValue).toList())
                .toList());
      }
      if (entry.containsKey('callback_count')) {
        expect(callbackCount, entry['callback_count']);
      }
    });
  }

  test('row comparison evaluates each necessary field once', () async {
    var count = 0;
    db.functions.registerScalar('row_counter', 0, (_) => ++count);
    expect(
        (await db.query('SELECT (row_counter(),row_counter())<(1,3)')).rows, [
      [BigInt.one]
    ]);
    expect(count, 2);
    count = 0;
    expect(
        (await db.query('SELECT (row_counter(),row_counter())<(2,0)')).rows, [
      [BigInt.one]
    ]);
    expect(count, 1);
    count = 0;
    expect(
        (await db.query(
                'SELECT (row_counter(),row_counter()) BETWEEN (1,0) AND (1,3)'))
            .rows,
        [
          [BigInt.one]
        ]);
    expect(count, 2);
    count = 0;
    expect(
        (await db.query(
                'SELECT CASE (row_counter(),row_counter()) WHEN (1,3) THEN 0 WHEN (1,2) THEN 1 END'))
            .rows,
        [
          [BigInt.one]
        ]);
    expect(count, 2);
  });
}
