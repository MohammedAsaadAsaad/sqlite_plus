import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(File('test/fixtures/window_evaluation_oracle.json')
      .readAsStringSync()) as Map;
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
        int increment(String name) {
          trace.add('$name:${++serial}');
          return serial;
        }

        Object? visit(String name, Object? value) {
          trace.add('$name:$value');
          return value;
        }

        db.functions.registerScalar('tick', 0, (_) => increment('tick'));
        db.functions.registerScalar('stamp', 0, (_) => increment('stamp'));
        db.functions
            .registerScalar('visit', 1, (args) => visit('visit', args[0]));
        db.functions
            .registerScalar('audit', 1, (args) => visit('audit', args[0]));
        db.functions.registerScalar(
            'keep', 1, (args) => visit('keep', args[0]) != BigInt.two ? 1 : 0);
        db.functions.registerScalar('gate', 2, (args) {
          trace.add('gate:${args[0]}:${args[1]}');
          return args[0] == args[1] ? 1 : 0;
        });
        db.functions.registerScalar('fail_if', 1, (args) {
          visit('fail_if', args[0]);
          if (args[0] == BigInt.two) {
            throw const SqlException('requested projection failure');
          }
          return args[0];
        });
        db.functions.registerScalar('bad_stamp', 0, (_) {
          trace.add('bad_stamp');
          throw const SqlException('requested default failure');
        });
        for (final step in scenario['steps'] as List) {
          final sql = step['sql'] as String;
          final parameters = step['parameters'] as List;
          Future<List<List<Object?>>> run() async {
            if (step['query'] == true) {
              return (await db.query(sql, parameters)).rows;
            }
            final mutation = await db.execute(sql, parameters);
            expect(mutation.changes, step['changes'], reason: sql);
            return mutation.returning?.rows ?? [];
          }

          if (step.containsKey('error')) {
            await expectLater(run(), throwsA(isA<SqlException>()), reason: sql);
          } else {
            expect(
                await run(),
                (step['rows'] as List)
                    .map((row) => (row as List).map(expectedValue).toList())
                    .toList(),
                reason: sql);
          }
          expect(trace, step['trace'], reason: 'callback order after $sql');
        }
      });
    }
  }
}
