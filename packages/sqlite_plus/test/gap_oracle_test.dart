import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

import 'read_only_test.dart' show expectedValue;

Object? _oracleValue(dynamic value) {
  if (value is Map && value.containsKey('float')) {
    return double.parse(value['float'] as String);
  }
  return expectedValue(value);
}

List<List<Object?>> _rows(Object? value) => (value as List)
    .map((row) => (row as List).map(_oracleValue).toList())
    .toList();

List<String> _statements(String sql) {
  final statements = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote.isNotEmpty) {
      buffer.write(char);
      if (char == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          buffer.write(sql[++i]);
        } else {
          quote = '';
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      buffer.write(char);
      continue;
    }
    if (char == ';') {
      final text = buffer.toString().trim();
      if (text.isNotEmpty) statements.add(text);
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  final text = buffer.toString().trim();
  if (text.isNotEmpty) statements.add(text);
  return statements;
}

void main() {
  final document =
      jsonDecode(File('test/fixtures/gap_oracle.json').readAsStringSync())
          as Map<String, Object?>;
  final cases = document['cases'] as List;
  test('gap ledger names the pinned source and records every difference', () {
    expect(document['source_id'],
        '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
    expect(document['compiler_note'], contains('clang-22.1.3'));
    expect(cases, isNotEmpty);
    for (final entry in cases) {
      final disposition = entry['disposition'];
      expect(['match', 'rejected', 'differs'], contains(disposition));
      if (disposition != 'match') {
        expect((entry['reason'] as String).trim(), isNotEmpty);
      }
    }
  });

  for (final entry in cases) {
    final id = entry['id'] as String;
    test(id, () async {
      final db = await MutableSqliteDatabase.create();
      addTearDown(db.close);
      final setup = entry['setup'] as String?;
      if (setup != null) {
        for (final statement in _statements(setup)) {
          await db.execute(statement);
        }
      }
      final sql = entry['sql'] as String;
      final kind = entry['kind'] as String? ?? 'query';
      Future<Object?> run() =>
          kind == 'execute' ? db.execute(sql) : db.query(sql);
      switch (entry['disposition']) {
        case 'match':
          expect((await db.query(sql)).rows, _rows(entry['rows']));
        case 'rejected':
          SqlException? error;
          try {
            await run();
          } on SqlException catch (caught) {
            error = caught;
          }
          expect(error, isNotNull,
              reason: 'pinned difference must be rejected');
          final needle = entry['engine_message'] as String?;
          if (needle != null) {
            expect(error!.message, contains(needle));
          }
          final unchanged = entry['unchanged_sql'] as String?;
          if (unchanged != null) {
            expect((await db.query(unchanged)).rows,
                _rows(entry['unchanged_rows']));
          }
        case 'differs':
          final result = await db.query(sql);
          final engineRows = entry['engine_rows'];
          if (engineRows != null) {
            expect(result.rows, _rows(engineRows));
            expect(result.rows, isNot(_rows(entry['rows'])));
          }
          final detail = entry['engine_detail'] as Map<String, Object?>?;
          if (detail != null) {
            expect(result.columns, ['detail']);
            final text = result.rows.single.single.toString();
            for (final part in detail['contains'] as List) {
              expect(text, contains(part as String));
            }
            for (final part in detail['excludes'] as List) {
              expect(text.contains(part as String), isFalse);
            }
            expect(text, isNot((entry['sqlite_text'] as String).trim()));
          }
          final needles = entry['sqlite_text_contains'] as List?;
          if (needles != null) {
            final sqliteText = entry['sqlite_text'] as String;
            for (final part in needles) {
              expect(sqliteText, contains(part as String));
            }
          }
        default:
          fail('unknown disposition ${entry['disposition']}');
      }
    });
  }
}
