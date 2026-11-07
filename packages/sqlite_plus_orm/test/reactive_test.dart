import 'dart:async';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

import 'reactive_model.dart';
import 'package:sqlite_plus_sync/sqlite_plus_sync.dart';
import '../../sqlite_plus_sync/example/memory_server.dart';

void main() {
  for (final capture in [false, true]) {
    test(
        'ORM filters/order/page/watchFirst/count/any follow saves capture=$capture',
        () async {
      final db = await openInMemory();
      await db.execute('PRAGMA recursive_triggers=ON');
      final feed = capture ? await SqlitePlusChanges.open(database: db) : null;
      final context = DbContext(MutableDatabaseConnection(db), DbModel([type]),
          changes: feed);
      addTearDown(() async {
        await context.close();
        await db.close();
      });
      await context.migrations.ensureCreated();
      final products = context.set(type);
      final q = products.query
          .where(price.lt(20))
          .orderBy([price.asc(), id.asc()]).take(2);
      final rows = <List<String>>[],
          counts = <BigInt>[],
          first = <String?>[],
          any = <bool>[];
      final subscriptions = <StreamSubscription>[
        q.watch().listen((s) => rows.add(s.items.map((x) => x.name).toList())),
        q.watchCount().listen(counts.add),
        q.watchFirst().listen((p) => first.add(p?.name)),
        q.watchAny().listen(any.add)
      ];
      await context.flushReactive();
      expect(rows, [[]]);
      expect(counts, [BigInt.zero]);
      expect(first, [null]);
      expect(any, [false]);
      products.add(Product(BigInt.one, 'milk', 10));
      products.add(Product(BigInt.two, 'tea', 15));
      products.add(Product(BigInt.from(3), 'other', 30));
      await context.saveChanges();
      await context.flushReactive();
      expect(rows.last, ['milk', 'tea']);
      expect(counts.last, BigInt.two);
      expect(first.last, 'milk');
      expect(any.last, isTrue);
      final other = await products.find(EntityKey([BigInt.from(3)]));
      other!.price = 5;
      await context.saveChanges();
      await context.flushReactive();
      expect(rows.last, ['other', 'milk']);
      for (final sub in subscriptions) {
        await sub.cancel();
      }
      expect(context.activeReactiveQueryCount, 0);
    });
  }

  test('watch snapshots never replace or mutate unsaved tracked entities',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    addTearDown(context.close);
    await context.migrations.ensureCreated();
    final products = context.set(type);
    final product = Product(BigInt.one, 'stored', 10);
    products.add(product);
    await context.saveChanges();
    product.name = 'unsaved';
    final values = <Product>[];
    final sub =
        products.query.watch().listen((s) => values.add(s.items.single));
    await context.flushReactive();
    expect(values.single.name, 'stored');
    expect(identical(values.single, product), isFalse);
    expect(product.name, 'unsaved');
    values.single.name = 'snapshot edit';
    expect(product.name, 'unsaved');
    expect(context.entry(product).state, EntityState.modified);
    await context.saveChanges();
    await context.flushReactive();
    expect(values.last.name, 'unsaved');
    await sub.cancel();
  });

  test(
      'external Changes writes notify ORM while rollback sends no notification',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('PRAGMA recursive_triggers=ON');
    final feed = await SqlitePlusChanges.open(database: db);
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]),
        changes: feed);
    addTearDown(context.close);
    await context.migrations.ensureCreated();
    final rows = <List<String>>[];
    final sub = context
        .set(type)
        .query
        .watch()
        .listen((s) => rows.add(s.items.map((p) => p.name).toList()));
    await context.flushReactive();
    await feed.transaction(
        (tx) => tx.execute("INSERT INTO products VALUES(1,'remote',10)"));
    await context.flushReactive();
    expect(rows, [
      [],
      ['remote']
    ]);
    await expectLater(feed.transaction((tx) async {
      await tx.execute("UPDATE products SET name='discarded'");
      throw StateError('rollback');
    }), throwsStateError);
    await context.flushReactive();
    expect(rows.length, 2);
    await sub.cancel();
    expect((await db.query('SELECT name FROM _spc_consumers')).rows, isEmpty);
  });
  test('Sync inbound commits refresh a live ORM watch', () async {
    final server = MemorySyncServer();
    final databases = <MutableSqliteDatabase>[];
    final feeds = <SqlitePlusChanges>[];
    final replicas = <SqlitePlusSync>[];
    for (final replica in ['a', 'b']) {
      final db = await openInMemory();
      databases.add(db);
      await db.execute('PRAGMA recursive_triggers=ON');
      await db.execute(
          'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT NOT NULL,price INTEGER NOT NULL)');
      final feed = await SqlitePlusChanges.open(database: db);
      feeds.add(feed);
      final sync = await SqlitePlusSync.open(
          changes: feed,
          transport: server,
          scope: 'reactive-test',
          replicaId: replica);
      await sync.register(table: 'products', columns: ['name', 'price']);
      replicas.add(sync);
    }
    final context = DbContext(
        MutableDatabaseConnection(databases.last), DbModel([type]),
        changes: feeds.last);
    try {
      final values = <List<String>>[];
      final sub = context
          .set(type)
          .query
          .watch()
          .listen((s) => values.add(s.items.map((p) => p.name).toList()));
      await context.flushReactive();
      await feeds.first.transaction(
          (tx) => tx.execute("INSERT INTO products VALUES(1,'synced',9)"));
      await replicas.first.runOnce();
      await replicas.last.runOnce();
      await context.flushReactive();
      expect(values, [
        [],
        ['synced']
      ]);
      await sub.cancel();
    } finally {
      await context.close();
      for (final db in databases) {
        await db.close();
      }
    }
  });

  test(
      'equivalent typed chains share work, failed saves emit nothing, paused close completes',
      () async {
    final db = await openInMemory();
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    try {
      await context.migrations.ensureCreated();
      final set = context.set(type);
      final values = <List<String>>[];
      final first = set.query
          .where(price.lt(20))
          .watch()
          .listen((s) => values.add(s.items.map((p) => p.name).toList()));
      final second = set.query.where(price.lt(20)).watch().listen((_) {});
      await context.flushReactive();
      expect(context.activeReactiveQueryCount, 1);
      set.add(Product(BigInt.one, 'valid', 5));
      await context.saveChanges();
      await context.flushReactive();
      final before = values.length;
      await db.execute("INSERT INTO products VALUES(2,'external',6)");
      set.add(Product(BigInt.two, 'duplicate', 6));
      await expectLater(context.saveChanges(), throwsA(isA<Exception>()));
      await context.flushReactive();
      expect(values.length, before);
      first.pause();
      second.pause();
      await context.close().timeout(const Duration(seconds: 2));
      await first.cancel();
      await second.cancel();
    } finally {
      await context.close();
      await db.close();
    }
  });
}
