import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

final class _Collector extends SqlAggregate {
  _Collector(this.name, this.trace);
  final String name;
  final List<String> trace;
  final values = <String>[];
  @override
  void step(List<Object?> arguments) {
    final value = '${arguments.single}';
    trace.add('$name:$value');
    values.add(value);
  }

  @override
  Object? finish() {
    trace.add('$name:finish');
    return values.join('|');
  }
}

void main() {
  final oracle = jsonDecode(
      File('test/fixtures/aggregate_evaluation_oracle.json')
          .readAsStringSync()) as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final suite in oracle['suites'] as List) {
    for (final scenario in suite['cases'] as List) {
      test('${scenario['sql']} encoding ${suite['encoding']}', () async {
        expect(oracle['source_id'], manifest['source_id']);
        final db = await MutableSqliteDatabase.create(
            encoding: suite['encoding'] as int);
        addTearDown(db.close);
        final trace = <String>[];
        var serial = 0;
        db.functions.registerScalar('visit', 1, (args) {
          trace.add('visit:${args.single}');
          return args.single;
        });
        db.functions.registerScalar('keep', 1, (args) {
          trace.add('keep:${args.single}');
          return args.single == BigInt.two ? 0 : 1;
        });
        db.functions.registerScalar('tick', 0, (_) {
          trace.add('tick:${++serial}');
          return serial;
        });
        db.functions
            .registerAggregate('fold_a', 1, () => _Collector('a', trace));
        db.functions
            .registerAggregate('fold_b', 1, () => _Collector('b', trace));
        for (final sql in scenario['setup'] as List) {
          await db.execute(sql as String);
        }
        expect(trace, isEmpty);
        final sql = scenario['sql'] as String;
        if (scenario.containsKey('error')) {
          await expectLater(db.query(sql), throwsA(isA<SqlException>()));
        } else {
          final result = await db.query(sql);
          expect(result.columns, scenario['columns']);
          expect(
              result.rows,
              (scenario['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList());
        }
        expect(trace, scenario['trace'], reason: sql);
      });
    }
  }
}
