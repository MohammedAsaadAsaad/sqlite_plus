import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

import '../test/rollback_pager_test.dart' show ModelFile, CrashController;

Future<void> main(List<String> args) async {
  final path = args.single;
  final faults = CrashController();
  final main = ModelFile(File(path).readAsBytesSync(), faults);
  final log = ModelFile(File('$path-wal').readAsBytesSync(), faults);
  final pager = await WalPager.open(main, log,
      exclusiveOwnership: true, walIndexAbsent: true);
  final database = await MutableSqliteDatabase.fromImagePager(pager);
  try {
    await database
        .execute("UPDATE notes SET value='big-endian-append' WHERE id=1");
    await File(path).writeAsBytes(main.durable);
    await File('$path-wal').writeAsBytes(log.durable);
  } finally {
    await database.close();
  }
}
