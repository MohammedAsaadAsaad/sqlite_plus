import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

final class _PatternAggregate extends SqlAggregate {
  _PatternAggregate(this.name, this.trace);
  final String name;
  final List<List<Object?>> trace;
  Object? total;

  @override
  void step(List<Object?> arguments) {
    trace.add([name, arguments]);
    total ??= BigInt.zero;
    final value = arguments.first;
    if (value is BigInt) {
      total = total is BigInt
          ? (total as BigInt) + value
          : (total as double) + value.toDouble();
    } else if (value is double) {
      total =
          (total is BigInt ? (total as BigInt).toDouble() : total as double) +
              value;
    }
  }

  @override
  Object? finish() => total;
}

void main() {
  final oracle = jsonDecode(
          File('test/fixtures/pattern_operator_oracle.json').readAsStringSync())
      as Map;
  final manifest =
      jsonDecode(File('test/fixtures/manifest.json').readAsStringSync()) as Map;
  for (final suite in oracle['suites'] as List) {
    final encoding = suite['encoding'] as int;
    final profile = suite['profile'] as String;
    test('native pattern operators $profile encoding $encoding', () async {
      expect(oracle['source_id'], manifest['source_id']);
      final db = await MutableSqliteDatabase.create(encoding: encoding);
      addTearDown(db.close);
      await db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v,p,k)');
      await db.execute(
          "INSERT INTO t VALUES(1,'a',2,'x'),(2,NULL,0,'x'),(3,'λ',NULL,'y')");
      final trace = <List<Object?>>[];
      db.functions.registerScalar('tap', 1, (arguments) {
        trace.add(['tap', arguments]);
        return arguments.single;
      });
      if (profile != 'default') {
        for (final name in ['like', 'glob', 'regexp', 'match']) {
          if (profile == 'aggregate') {
            db.functions.registerAggregate(
                name, 2, () => _PatternAggregate(name, trace));
          } else {
            for (final count in <String, List<int>>{
              'scalar2': [2],
              'scalar3': [3],
              'varargs': [-1],
              'deterministic': [2, 3]
            }[profile]!) {
              db.functions.registerScalar(name, count, (arguments) {
                trace.add([name, arguments]);
                final pattern = arguments.firstOrNull;
                return switch (pattern) {
                  'return-null' => null,
                  'return-text' => '12abc',
                  'return-blob' => Uint8List.fromList('12abc'.codeUnits),
                  'return-real' => 0.25,
                  _ => arguments.isEmpty ? 99 : pattern
                };
              }, deterministic: profile == 'deterministic');
            }
          }
        }
      }
      var definition = '';
      for (final step in suite['steps'] as List) {
        final sql = step['sql'] as String;
        if (sql.startsWith('CREATE VIEW deferred')) definition = sql;
        final reason = '$sql [$definition]';
        trace.clear();
        Future<List<List<Object?>>> run() async {
          if (step['query'] == true) return (await db.query(sql)).rows;
          return (await db.execute(sql)).returning?.rows ?? [];
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
        if (step.containsKey('trace')) {
          expect(
              trace,
              (step['trace'] as List)
                  .map((event) => [
                        event[0],
                        (event[1] as List).map(expectedValue).toList()
                      ])
                  .toList(),
              reason: 'callback order after $sql');
        }
      }
    });
  }
}
