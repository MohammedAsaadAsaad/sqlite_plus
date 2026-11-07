import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import 'memory_server.dart';

Future<void> main() async {
  final server = MemorySyncServer();
  final databases = <MutableSqliteDatabase>[];
  final feeds = <SqlitePlusChanges>[];
  final replicas = <SqlitePlusSync>[];
  try {
    for (final id in ['device-a', 'device-b']) {
      final db = await openInMemory();
      databases.add(db);
      await db.execute('PRAGMA recursive_triggers=ON');
      await db.execute(
          'CREATE TABLE products(id TEXT PRIMARY KEY,name TEXT,price INTEGER)');
      final changes = await SqlitePlusChanges.open(database: db);
      feeds.add(changes);
      final sync = await SqlitePlusSync.open(
          changes: changes,
          transport: server,
          scope: 'demo-shop',
          replicaId: id);
      await sync.register(table: 'products', columns: ['name', 'price']);
      replicas.add(sync);
    }
    // Local write works offline. Network runs only when requested.
    await feeds.first.transaction((tx) => tx.execute(
        'INSERT INTO products VALUES(?,?,?)', ['product-1', 'حليب', 10]));
    await replicas.first.runOnce();
    await replicas.last.runOnce();
    print((await databases.last.query('SELECT * FROM products')).rows);
    final audit = await feeds.last.consumer(name: 'cache');
    final remoteEvents = await audit.read();
    if (remoteEvents.events.length != 1) {
      throw StateError('Remote write missing from Changes');
    }
    await replicas.last.runOnce();
    if (server.applications != 1) {
      throw StateError('Incoming write echoed back');
    }
    print('Two replicas converged; incoming event retained without echo.');
  } finally {
    for (final db in databases) {
      await db.close();
    }
  }
}
