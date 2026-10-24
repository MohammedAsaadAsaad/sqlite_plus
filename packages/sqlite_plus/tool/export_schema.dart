import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main(List<String> args) async {
  final root = args.single;
  final operations =
      jsonDecode(File('$root/operations.json').readAsStringSync()) as List;
  final db = await MutableSqliteDatabase.create(pageSize: 512);
  try {
    for (var i = 0; i < operations.length; i++) {
      final operation = operations[i];
      Object? error;
      int changes = 0;
      try {
        changes = (await db.execute(operation['sql'] as String,
                List<Object?>.from(operation['parameters'] as List)))
            .changes;
      } on SqlException catch (e) {
        error = e.message;
      }
      await File('$root/$i.db').writeAsBytes(db.exportImage());
      await File('$root/$i.json')
          .writeAsString(jsonEncode({'error': error, 'changes': changes}));
    }
  } finally {
    await db.close();
  }
}
