import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Expected output directory');
  final operations =
      jsonDecode(File('${args.single}/operations.json').readAsStringSync())
          as List;
  final database = await MutableSqliteDatabase.fromImage(
      File('test/fixtures/write.db').readAsBytesSync());
  try {
    for (var i = 0; i < operations.length; i++) {
      final operation = operations[i];
      final result = await database.execute(operation['sql'] as String,
          List<Object?>.from(operation['parameters'] as List));
      await File('${args.single}/$i.db').writeAsBytes(database.exportImage());
      await File('${args.single}/$i.json').writeAsString(jsonEncode({
        'changes': result.changes,
        'lastRowid': result.lastInsertRowid?.toString()
      }));
    }
  } finally {
    await database.close();
  }
}
