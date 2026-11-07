import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';

Future<void> main() async {
  final db = await openInMemory();
  try {
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT,price INTEGER)');
    final changes = await SqlitePlusChanges.open(database: db);
    await changes.track(table: 'products', columns: ['name', 'price']);
    final search = await changes.consumer(name: 'search');
    await changes.transaction((tx) async {
      await tx.execute('INSERT INTO products VALUES(?,?,?)', [1, 'حليب', 10]);
      await tx.execute('UPDATE products SET price=? WHERE id=?', [12, 1]);
    });
    final batch = await search.read();
    for (final transaction in batch.transactions) {
      for (final event in transaction.events) {
        print(
            '${transaction.id}: ${event.kind.name} ${event.table} ${event.key} ${event.changedColumns}');
      }
    }
    await search.acknowledge(batch.checkpoint);
    print('checkpoint: ${batch.checkpoint.encode()}');
    await changes.pruneAcknowledged();
  } finally {
    await db.close();
  }
}
