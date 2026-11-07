import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import '../../packages/sqlite_plus_sync/example/memory_server.dart';
import '../changes_benchmark/workload.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--activate')) {
    final db = await openInMemory();
    try {
      await db.execute('PRAGMA recursive_triggers=ON');
      await db.execute('CREATE TABLE demo(id INTEGER PRIMARY KEY,n INTEGER)');
      final changes = await SqlitePlusChanges.open(database: db);
      final sync = await SqlitePlusSync.open(
          changes: changes, transport: MemorySyncServer(), scope: 'demo');
      await sync.register(table: 'demo', columns: ['n']);
      await changes
          .transaction((tx) => tx.execute('INSERT INTO demo VALUES(1,2)'));
      await sync.runOnce();
      if (args.contains('--resolve')) {
        for (final conflict in await sync.conflicts()) {
          await sync.resolveConflict(conflict.id, SyncResolution.keepLocal);
        }
      }
    } finally {
      await db.close();
    }
    return;
  }
  await runWorkload(args);
}
