// Development-only runner for tool/verify_join_binding.py.
import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

Object? encode(Object? value) => value is BigInt
    ? {'integer': value.toString()}
    : value is List
        ? value.map(encode).toList()
        : value;

Future<void> main(List<String> arguments) async {
  final input = jsonDecode(await File(arguments.single).readAsString()) as Map;
  final storage = MemoryStorageBackend();
  await storage.write(0, await File(input['image'] as String).readAsBytes());
  final db = await SqliteDatabase.openReadOnly(storage);
  try {
    final output = [];
    for (final sql in input['queries'] as List) {
      try {
        final result = await db.query(sql as String);
        output.add({'columns': result.columns, 'rows': encode(result.rows)});
      } on SqlException {
        output.add({'error': true});
      }
    }
    stdout.write(jsonEncode(output));
  } finally {
    await db.close();
  }
}
