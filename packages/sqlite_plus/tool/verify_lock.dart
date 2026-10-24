import 'dart:io';

import 'package:sqlite_plus/sqlite_plus_io.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Expected existing database path');
  final storage = await DurableFileStorageBackend.openExclusive(args.single,
      directoryEntryIsDurable: true);
  try {
    final blocked = await Process.run('python3', [
      '-c',
      '''
import sqlite3,sys
try:
    c=sqlite3.connect(sys.argv[1],timeout=0)
    c.execute('select * from notes limit 1').fetchall()
except sqlite3.OperationalError as e:
    if 'locked' in str(e): sys.exit(0)
    raise
sys.exit(1)
''',
      args.single
    ]);
    if (blocked.exitCode != 0) {
      throw StateError(
          'SQLite was not blocked by exclusive lease: ${blocked.stderr}');
    }
  } finally {
    await storage.close();
  }
  final released = await Process.run('python3', [
    '-c',
    "import sqlite3,sys;sqlite3.connect(sys.argv[1],timeout=0).execute('select * from notes limit 1').fetchall()",
    args.single
  ]);
  if (released.exitCode != 0) {
    throw StateError('Lease did not release: ${released.stderr}');
  }
  print('SQLite reader blocked under lease and succeeds after release');
}
