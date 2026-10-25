// Development-only runner for tool/verify_maintenance_oracle.py.
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main(List<String> arguments) async {
  final db = await MutableSqliteDatabase.fromImage(
      await File(arguments[0]).readAsBytes());
  try {
    final before = (await db.query('PRAGMA integrity_check')).rows;
    if (before.length == 1 && before.single.single == 'ok') {
      throw StateError('Stale index was not detected');
    }
    await db.execute('REINDEX main.ri');
    final after = (await db.query('PRAGMA integrity_check')).rows;
    if (after.length != 1 || after.single.single != 'ok') {
      throw StateError('REINDEX failed to repair stale index: $after');
    }
    await File(arguments[1]).writeAsBytes(db.exportImage());
  } finally {
    await db.close();
  }
}
