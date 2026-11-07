import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import 'package:test/test.dart';
import '../example/memory_server.dart';

void main() {
  test('remote writes reach existing search autoUpdate without outbound echo',
      () async {
    final server = MemorySyncServer();
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT,price INTEGER)');
    final search = await SqlitePlusSearch.open(database: db);
    await search.indexTable(
        table: 'products',
        primaryKey: 'id',
        textColumns: ['name'],
        autoUpdate: true);
    final changes = await SqlitePlusChanges.open(database: db);
    final sync = await SqlitePlusSync.open(
        changes: changes, transport: server, scope: 'shop');
    await sync.register(table: 'products', columns: ['name', 'price']);
    await server.push(SyncOperation(id: 'server', scope: 'shop', mutations: [
      SyncMutation(
          table: 'products',
          key: {'id': 1},
          baseVersion: null,
          values: {'id': 1, 'name': 'milk حليب', 'price': 10})
    ]));
    expect((await sync.runOnce()).pulled, 1);
    expect((await search.search('milk', table: 'products')).total, 1);
    expect((await sync.runOnce()).pushed, 0);
    expect(server.applications, 1);
  });
}
