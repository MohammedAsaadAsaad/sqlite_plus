import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(
          File('test/fixtures/cte_evaluation_oracle.json').readAsStringSync())
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
        final trace = <String>[];
        var serial = 0;
        Object? visit(String name, Object? value) {
          trace.add('$name:$value');
          return value;
        }

        db.functions.registerScalar('tick', 0, (_) {
          trace.add('tick:${++serial}');
          return serial;
        });
        db.functions
            .registerScalar('visit', 1, (args) => visit('visit', args[0]));
        db.functions.registerScalar(
            'keep', 1, (args) => visit('keep', args[0]) != BigInt.two ? 1 : 0);
        db.functions.registerScalar('fail_if', 1, (args) {
          visit('fail_if', args[0]);
          if (args[0] == BigInt.two) {
            throw const SqlException('requested projection failure');
          }
          return args[0];
        });
        for (final setup in scenario['setup'] as List) {
          await db.execute(setup as String);
        }
        expect(trace, isEmpty,
            reason: 'schema preparation must be callback free');
        final sql = scenario['sql'] as String;
        final parameters = scenario['parameters'] as List;
        if (scenario.containsKey('error')) {
          await expectLater(
              db.query(sql, parameters), throwsA(isA<SqlException>()),
              reason: sql);
        } else {
          final result = await db.query(sql, parameters);
          expect(result.columns, scenario['columns'], reason: sql);
          expect(
              result.rows,
              (scenario['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList(),
              reason: sql);
        }
        expect(trace, scenario['trace'], reason: 'callback order after $sql');
      });
    }
  }
}
