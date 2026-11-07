import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';
import 'reactive_model.dart';

void main() {
  test('file owner ORM watch follows commits and retains rows on reopen',
      () async {
    final dir = Directory.systemTemp.createTempSync('reactive-orm-');
    try {
      final set = await DbSet.openDbFile(type, '${dir.path}/catalog.db');
      final values = <int>[];
      final sub = set.query.watch().listen((s) => values.add(s.items.length));
      await set.context.flushReactive();
      set.add(Product(BigInt.one, 'stored', 4));
      await set.saveChanges();
      await set.context.flushReactive();
      expect(values, [0, 1]);
      await sub.cancel();
      await set.close();
      final reopened = await DbSet.openDbFile(type, '${dir.path}/catalog.db');
      expect((await reopened.query.watchFirst().first)?.name, 'stored');
      await reopened.close();
    } finally {
      dir.deleteSync(recursive: true);
    }
  });

  test('browser adapter ORM watch persists through simulated store reopen',
      () async {
    final store = MemoryBrowserByteStore();
    Future<DbContext> open() async => DbContext(
        await BrowserDatabaseConnection.open(await openBrowserStorage(
            name: 'reactive', probe: () async => store)),
        DbModel([type]));
    final context = await open();
    await context.migrations.ensureCreated();
    final counts = <BigInt>[];
    final sub = context.set(type).query.watchCount().listen(counts.add);
    await context.flushReactive();
    context.set(type).add(Product(BigInt.one, 'browser', 8));
    await context.saveChanges();
    await context.flushReactive();
    expect(counts, [BigInt.zero, BigInt.one]);
    await sub.cancel();
    await context.close();
    final reopened = await open();
    expect(
        (await reopened.set(type).query.watchFirst().first)?.name, 'browser');
    await reopened.close();
  });
}
