import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(
      File('test/fixtures/assignment_oracle.json').readAsStringSync()) as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final suite in oracle['suites'] as List) {
    test('pinned row assignments encoding ${suite['encoding']}', () async {
      expect(oracle['source_id'], manifest['source_id']);
      final db = await MutableSqliteDatabase.create(
          encoding: suite['encoding'] as int);
      addTearDown(db.close);
      var calls = 0;
      db.functions.registerScalar('tick', 0, (_) => ++calls);
      for (final step in suite['steps'] as List) {
        final sql = step['sql'] as String;
        Future<List<List<Object?>>> run() async {
          if (step['query'] == true) return (await db.query(sql)).rows;
          final mutation = await db.execute(sql);
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
        expect(calls, step['calls'], reason: 'callback count after $sql');
      }
    });
  }
}
