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

List<List<Object?>> _rows(dynamic rows) => (rows as List)
    .map((row) => (row as List).map(_oracleValue).toList())
    .toList();

void main() {
  final catalog =
      jsonDecode(File('test/fixtures/search_oracle.json').readAsStringSync())
          as Map<String, dynamic>;
  final replay = catalog['replay'] as List;

  for (final encoding in [1, 2, 3]) {
    for (final (index, entry)
        in replay.where((entry) => entry['encoding'] == encoding).indexed) {
      final sql = entry['sql'] as String;
      test('search replay $encoding.${index + 1}: $sql', () async {
        final db = await MutableSqliteDatabase.create(encoding: encoding);
        addTearDown(db.close);
        final setup = (entry['setup'] as List).cast<String>();
        if (entry['error'] == true) {
          await expectLater(() async {
            for (final statement in setup) {
              await db.execute(statement);
            }
            await db.query(sql);
          }(), throwsA(isA<SqlException>()));
          return;
        }
        for (final statement in setup) {
          await db.execute(statement);
        }
        expect((await db.query(sql)).rows, _rows(entry['rows']));
      });
    }
  }

  for (final image in catalog['images'] as List) {
    final encoding = image['encoding'] as int;
    final module = image['module'] as String;
    final bytes = File('test/fixtures/${image['file']}').readAsBytesSync();
    for (final query in image['queries'] as List) {
      final sql = query['sql'] as String;
      test('search image $module $encoding: $sql', () async {
        final db = await MutableSqliteDatabase.fromImage(bytes);
        addTearDown(db.close);
        expect((await db.query(sql)).rows, _rows(query['rows']));
      });
    }
  }
}
