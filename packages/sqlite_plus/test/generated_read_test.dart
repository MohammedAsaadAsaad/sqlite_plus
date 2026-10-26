import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(
          File('test/fixtures/generated_read_oracle.json').readAsStringSync())
      as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final suite in oracle['suites'] as List) {
    for (final scenario in suite['cases'] as List) {
      test('${scenario['name']} encoding ${suite['encoding']}', () async {
        expect(oracle['source_id'], manifest['source_id']);
        final db = await MutableSqliteDatabase.create(
            encoding: suite['encoding'] as int);
        addTearDown(db.close);
        final trace = <Object?>[];
        var fail = false;
        db.functions.registerScalar('visit', 1, (arguments) {
          trace.add(arguments[0]);
          if (fail) throw const SqlException('generated expression error');
          return arguments[0];
        }, deterministic: true);
        for (final sql in scenario['setup'] as List) {
          await db.execute(sql as String);
        }
        trace.clear();
        fail = scenario['fail'] as bool;
        final sql = scenario['sql'] as String;
        if (scenario['error'] == true) {
          await expectLater(db.query(sql), throwsA(isA<SqlException>()),
              reason: sql);
        } else {
          final result = await db.query(sql);
          expect(result.columns, scenario['columns'], reason: sql);
          expect(
              result.rows,
              (scenario['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList(),
              reason: sql);
        }
        expect(trace, (scenario['trace'] as List).map(expectedValue).toList(),
            reason: 'generated expression references in $sql');
      });
    }
  }
}
