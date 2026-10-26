import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

void main() {
  final oracle = jsonDecode(
      File('test/fixtures/numeric_text_oracle.json').readAsStringSync()) as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final suite in oracle['suites'] as List) {
    test('pinned numeric text encoding ${suite['encoding']}', () async {
      expect(oracle['source_id'], manifest['source_id']);
      final db = await MutableSqliteDatabase.create(
          encoding: suite['encoding'] as int);
      addTearDown(db.close);
      for (final step in suite['steps'] as List) {
        final sql = step['sql'] as String;
        final parameters =
            (step['parameters'] as List).map(expectedValue).toList();
        final reason = '$sql with ${jsonEncode(step['parameters'])}';
        Future<List<List<Object?>>> run() async {
          if (step['query'] == true) {
            return (await db.query(sql, parameters)).rows;
          }
          final mutation = await db.execute(sql, parameters);
          expect(mutation.changes, step['changes'], reason: reason);
          return mutation.returning?.rows ?? [];
        }

        if (step.containsKey('error')) {
          await expectLater(run(), throwsA(isA<SqlException>()),
              reason: reason);
        } else {
          expect(
              await run(),
              (step['rows'] as List)
                  .map((row) => (row as List).map(expectedValue).toList())
                  .toList(),
              reason: reason);
        }
      }
    });
  }
}
