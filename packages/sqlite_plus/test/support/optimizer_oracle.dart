import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';

/// Development-only reference: never imported by production code.
Future<List<List<Object?>>> optimizerOracle(String setup, String sql) async {
  final cli = Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';
  final identity =
      await Process.run(cli, [':memory:', 'SELECT sqlite_source_id()']);
  expect(identity.exitCode, 0);
  expect(identity.stdout.toString().trim(),
      '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9');
  final result = await Process.run(cli, ['-json', ':memory:', '$setup; $sql;']);
  expect(result.exitCode, 0, reason: result.stderr.toString());
  final text = result.stdout.toString().trim();
  if (text.isEmpty) return [];
  return [
    for (final row in jsonDecode(text) as List)
      [
        for (final value in (row as Map).values)
          value is int ? BigInt.from(value) : value
      ]
  ];
}
