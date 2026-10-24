import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';

Object? encode(Object? value) {
  if (value is BigInt) return {'integer': value.toString()};
  if (value is Uint8List) {
    return {
      'blob': value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()
    };
  }
  return value;
}

Future<void> main(List<String> args) async {
  final root = args.first;
  final encoding = args.length > 1 ? int.parse(args[1]) : 1;
  final operations =
      jsonDecode(File('$root/operations.json').readAsStringSync()) as List;
  final db =
      await MutableSqliteDatabase.create(pageSize: 512, encoding: encoding);
  try {
    for (var i = 0; i < operations.length; i++) {
      final operation = operations[i];
      Object? error;
      int changes = 0;
      QueryResult? returning;
      try {
        if (operation['query'] == true) {
          returning = await db.query(operation['sql'] as String,
              List<Object?>.from(operation['parameters'] as List));
        } else {
          final result = await db.execute(operation['sql'] as String,
              List<Object?>.from(operation['parameters'] as List));
          changes = result.changes;
          returning = result.returning;
        }
      } on SqlException catch (e) {
        error = e.message;
      }
      await File('$root/$i.db').writeAsBytes(db.exportImage());
      await File('$root/$i.json').writeAsString(jsonEncode({
        'error': error,
        'changes': changes,
        'returning': returning == null
            ? null
            : {
                'columns': returning.columns,
                'rows': returning.rows
                    .map((row) => row.map(encode).toList())
                    .toList()
              }
      }));
    }
  } finally {
    await db.close();
  }
}
