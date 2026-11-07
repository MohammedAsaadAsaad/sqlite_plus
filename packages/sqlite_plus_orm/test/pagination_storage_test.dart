import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';
import 'reactive_model.dart';

void main() {
  test('cursor resumes after file owner close/reopen', () async {
    final dir = Directory.systemTemp.createTempSync('pagination-orm-');
    try {
      final path = '${dir.path}/items.db';
      final set = await DbSet.openDbFile(type, path);
      for (var i = 1; i <= 4; i++) {
        set.add(Product(BigInt.from(i), 'item$i', 10));
      }
      await set.saveChanges();
      final token = (await set.query.page(size: 2)).nextCursor!.encode();
      await set.close();
      final reopened = await DbSet.openDbFile(type, path);
      expect(
          (await reopened.query.page(size: 2, after: PageCursor.parse(token)))
              .items
              .map((p) => p.id),
          [BigInt.from(3), BigInt.from(4)]);
      await reopened.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('pagination reads through simulated browser and Changes adapters',
      () async {
    final store = MemoryBrowserByteStore();
    final opened =
        await openBrowserStorage(name: 'pagination', probe: () async => store);
    final connection = await BrowserDatabaseConnection.open(opened);
    await connection.engineDatabase.execute('PRAGMA recursive_triggers=ON');
    final feed =
        await SqlitePlusChanges.open(database: connection.engineDatabase);
    final context = DbContext(connection, DbModel([type]), changes: feed);
    try {
      await context.migrations.ensureCreated();
      await context.enableReactive();
      for (var i = 1; i <= 4; i++) {
        context.set(type).add(Product(BigInt.from(i), 'item$i', i));
      }
      await context.saveChanges();
      final first = await context.set(type).query.page(size: 2);
      final next =
          await context.set(type).query.page(size: 2, after: first.nextCursor);
      expect(next.items.map((p) => p.price), [3, 4]);
      expect(next.hasNextPage, isFalse);
    } finally {
      await context.close();
    }
  });
}
