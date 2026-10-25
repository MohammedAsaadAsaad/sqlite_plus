// Development-only runner for tool/verify_planner_statistics.py.
import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

Object? _encode(Object? value) => value is BigInt
    ? {'integer': value.toString()}
    : value is List
        ? value.map(_encode).toList()
        : value;

Future<void> main(List<String> arguments) async {
  final input = jsonDecode(await File(arguments[0]).readAsString()) as Map;
  final db = await MutableSqliteDatabase.create(
      pageSize: 512, encoding: input['encoding'] as int);
  try {
    for (final sql in input['setup'] as List) {
      await db.execute(sql as String);
    }
    await File(arguments[1]).writeAsBytes(db.exportImage());
    final storage = MemoryStorageBackend();
    await storage.write(0, db.exportImage());
    final reader = await SqliteDatabase.openReadOnly(storage);
    try {
      final output = [];
      for (final query in input['queries'] as List) {
        final sql = query['sql'] as String;
        final parameters = List<Object?>.from(query['parameters'] as List);
        final plan = reader.explain(sql, parameters);
        final result = await reader.query(sql, parameters);
        output.add({
          'index': plan.indexName,
          'access': plan.access,
          'columns': result.columns,
          'rows': _encode(result.rows),
        });
      }
      stdout.write(jsonEncode(output));
    } finally {
      await reader.close();
    }
  } finally {
    await db.close();
  }
}
