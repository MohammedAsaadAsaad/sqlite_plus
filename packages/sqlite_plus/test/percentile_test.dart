import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final cases = jsonDecode(
      File('test/fixtures/percentile_oracle.json').readAsStringSync()) as List;
  for (final encoding in [1, 2, 3]) {
    group('pinned percentile aggregate/window encoding $encoding', () {
      late MutableSqliteDatabase db;
      setUpAll(() async {
        db = await MutableSqliteDatabase.create(encoding: encoding);
      });
      tearDownAll(() => db.close());
      for (final (index, entry)
          in cases.where((entry) => entry['encoding'] == encoding).indexed) {
        final sql = entry['sql'] as String;
        final label = sql.length > 120 ? '${sql.substring(0, 120)}…' : sql;
        test('${index + 1}: $label', () async {
          final parameters =
              (entry['parameters'] as List).map(expectedValue).toList();
          if (entry.containsKey('error')) {
            await expectLater(
                db.query(sql, parameters), throwsA(isA<SqlException>()));
          } else {
            expect(
                (await db.query(sql, parameters)).rows,
                (entry['rows'] as List)
                    .map((row) => (row as List).map(expectedValue).toList())
                    .toList());
          }
        });
      }
    });
  }

  test('aggregate and window percentile callbacks evaluate input once',
      () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    var calls = 0;
    db.functions.registerScalar('probe', 1, (arguments) {
      calls++;
      return arguments.single;
    });
    expect(
        (await db.query('WITH t(x) AS(VALUES(1),(3),(7)) '
                'SELECT median(probe(x)) FROM t'))
            .rows,
        [
          [3.0]
        ]);
    expect(calls, 3);
    calls = 0;
    expect(
        (await db.query('WITH t(x) AS(VALUES(1),(3),(7)) '
                'SELECT percentile_cont(probe(x),0.5) OVER('
                'ORDER BY x ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) '
                'FROM t ORDER BY x'))
            .rows,
        [
          [1.0],
          [2.0],
          [5.0]
        ]);
    expect(calls, 3);
  });

  test('percentiles reject deterministic schema contexts atomically', () async {
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    await db.execute('CREATE TABLE t(x)');
    final before = db.exportImage();
    for (final expression in [
      'median(x)',
      'percentile(x,50)',
      'percentile_cont(x,0.5)',
      'percentile_disc(x,0.5)'
    ]) {
      await expectLater(db.execute('CREATE INDEX bad ON t($expression)'),
          throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
    }
  });
}
