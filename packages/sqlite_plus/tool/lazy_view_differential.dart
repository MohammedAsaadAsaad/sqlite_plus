import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

import 'export_schema.dart' show encode;

Future<void> main(List<String> arguments) async {
  final operations = jsonDecode(File(arguments[0]).readAsStringSync()) as List;
  final db =
      await MutableSqliteDatabase.create(encoding: int.parse(arguments[1]));
  var calls = 0;
  db.functions.registerScalar('tick', 0, (_) => ++calls);
  final results = <Object?>[];
  try {
    for (final operation in operations) {
      QueryResult? result;
      var error = false;
      var changes = 0;
      try {
        if (operation['query'] == true) {
          result = await db.query(operation['sql'] as String);
        } else {
          final mutation = await db.execute(operation['sql'] as String);
          result = mutation.returning;
          changes = mutation.changes;
        }
      } on SqlException {
        error = true;
      }
      results.add({
        'error': error,
        'changes': changes,
        'calls': calls,
        'rows': result?.rows.map((row) => row.map(encode).toList()).toList()
      });
    }
    stdout.write(jsonEncode(results));
  } finally {
    await db.close();
  }
}
