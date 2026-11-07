import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'workload.dart';

/// No activation by default. A runtime-reachable demo retains package code in
/// this binary; it is never taken in the disabled comparison.
Future<void> main(List<String> args) =>
    runWorkload(args, configure: (db) async {
      if (args.contains('--demo')) {
        await db.execute('PRAGMA recursive_triggers=ON');
        final changes = await SqlitePlusChanges.open(database: db);
        await changes.track(table: 'items');
        final consumer = await changes.consumer(name: 'demo');
        await changes.transaction((tx) async {
          await tx.execute("INSERT INTO items VALUES(-1,'demo',0)");
        });
        final batch = await consumer.read();
        await consumer.acknowledge(batch.checkpoint);
        await changes.pruneAcknowledged();
        await changes.untrack('items');
        await db.execute('DELETE FROM items WHERE id=-1');
      }
    });
