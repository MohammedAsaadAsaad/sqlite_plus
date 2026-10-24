import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';

import '../test/rollback_pager_test.dart' show ModelFile, CrashController;

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Expected output directory');
  final faults = CrashController();
  final main =
      ModelFile(File('test/fixtures/wal-base.db').readAsBytesSync(), faults);
  final wal = ModelFile(Uint8List(0), faults);
  final pager = await WalPager.open(main, wal,
      exclusiveOwnership: true, walIndexAbsent: true);
  final database = await MutableSqliteDatabase.fromImagePager(pager);
  for (var i = 0; i < 3; i++) {
    await database.execute('BEGIN');
    await database
        .execute('UPDATE notes SET value=?,n=n+1 WHERE id=1', ['dart-wal-$i']);
    await database.execute('INSERT INTO notes(value,n) VALUES(?,?)',
        ['overflow-' * (i + 1) * 1000, i]);
    await database.execute('COMMIT');
    await File('${args.single}/$i.db').writeAsBytes(main.durable);
    await File('${args.single}/$i.db-wal').writeAsBytes(wal.durable);
  }
  await pager.checkpoint();
  await File('${args.single}/checkpoint.db').writeAsBytes(main.durable);
  await File('${args.single}/checkpoint.db-wal').writeAsBytes(wal.durable);
  await database.close();

  // Exercise actual file ownership while a separate SQLite process attempts to
  // read. This uses the owner lifetime, not an isolated file-lock helper.
  final path = '${args.single}/owned.db';
  await File(path)
      .writeAsBytes(File('test/fixtures/wal-base.db').readAsBytesSync());
  await File('$path-wal').writeAsBytes([]);
  final owner =
      await DatabaseOwner.open(path, directoryEntriesDurable: true, wal: true);
  try {
    await owner.client.execute("UPDATE notes SET value='owned' WHERE id=1");
    final blocked = await Process.run('python3', [
      '-c',
      '''
import sqlite3,sys
try:
    sqlite3.connect(sys.argv[1],timeout=0).execute('select * from notes limit 1').fetchall()
except sqlite3.OperationalError as e:
    if 'locked' in str(e): sys.exit(0)
    raise
sys.exit(1)
''',
      path
    ]);
    if (blocked.exitCode != 0) {
      throw StateError(
          'External SQLite accessed the owned file: ${blocked.stderr}');
    }
    // A duplicate owner must fail without dropping the original POSIX lease.
    try {
      final duplicate = await DatabaseOwner.open(path,
          directoryEntriesDurable: true, wal: true);
      await duplicate.close();
      throw StateError('Duplicate owner succeeded');
    } on StateError catch (error) {
      if (error.toString().contains('Duplicate owner succeeded')) rethrow;
    }
    final again = await Process.run('python3', [
      '-c',
      '''
import sqlite3,sys
try:
    sqlite3.connect(sys.argv[1],timeout=0).execute('select * from notes limit 1').fetchall()
except sqlite3.OperationalError as e:
    if 'locked' in str(e): sys.exit(0)
    raise
sys.exit(1)
''',
      path
    ]);
    if (again.exitCode != 0) {
      throw StateError('Duplicate owner dropped the native lease');
    }
  } finally {
    await owner.close();
  }
}
