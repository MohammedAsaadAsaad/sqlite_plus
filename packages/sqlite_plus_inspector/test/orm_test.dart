import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_orm.dart';
import 'package:test/test.dart';
import '../example/model.dart';

void main() {
  for (final captured in [false, true]) {
    test('ORM saves, scopes, pagination and reactive reads capture=$captured',
        () async {
      final engine = await openInMemory();
      await engine.execute('PRAGMA recursive_triggers=ON');
      final changes =
          captured ? await SqlitePlusChanges.open(database: engine) : null;
      final inspector =
          SqlInspector(options: InspectorOptions(repeatedReadThreshold: 2));
      final connection = inspector
          .ormConnection(MutableDatabaseConnection(engine), changes: changes);
      if (changes != null) {
        expect(() => inspector.ormConnection(connection, changes: changes),
            throwsArgumentError);
      }
      final context = DbContext(connection, DbModel([type]));
      addTearDown(() async {
        await context.close();
        await engine.close();
      });
      await context.migrations.ensureCreated();
      final products = context.set(type);
      final snapshots = <List<String>>[];
      final sub = products.query
          .watch()
          .listen((s) => snapshots.add(s.items.map((p) => p.name).toList()));
      await context.flushReactive();
      inspector.clear();
      await inspector.scope('load-and-save', () async {
        products.add(Product(BigInt.one, 'private-name', 7));
        products.add(Product(BigInt.two, 'second', 8));
        await context.saveChanges();
        await products.query.where(id.eq(BigInt.one)).toList();
        await products.query.where(id.eq(BigInt.two)).toList();
        final page = await products.query.orderBy([price.asc()]).page(size: 1);
        expect(page.items.single.id, BigInt.one);
      });
      await context.flushReactive();
      final report = inspector.snapshot();
      expect(report.executeCount, greaterThan(0));
      expect(report.queryCount, greaterThanOrEqualTo(3));
      expect(report.scopes.single.repeatedReads, isNotEmpty);
      expect(report.toJsonString(), isNot(contains('private-name')));
      expect(snapshots.last, ['private-name', 'second']);
      if (captured) {
        expect(connection.changeFeed, same(changes));
        await changes!.transaction(
            (tx) => tx.execute("UPDATE products SET name='remote' WHERE id=1"));
        await context.flushReactive();
        expect(snapshots.last, ['remote', 'second']);
      } else {
        expect(report.records.where((r) => r.sql == 'BEGIN'), isNotEmpty);
        expect(report.records.where((r) => r.sql == 'COMMIT'), isNotEmpty);
      }
      await sub.cancel();
    });

    test(
        'rollback errors and dirty tracked values remain intact capture=$captured',
        () async {
      final engine = await openInMemory();
      await engine.execute('PRAGMA recursive_triggers=ON');
      final changes =
          captured ? await SqlitePlusChanges.open(database: engine) : null;
      final inspector = SqlInspector();
      final context = DbContext(
          inspector.ormConnection(MutableDatabaseConnection(engine),
              changes: changes),
          DbModel([type]));
      addTearDown(() async {
        await context.close();
        await engine.close();
      });
      await context.migrations.ensureCreated();
      final set = context.set(type);
      set.add(Product(BigInt.one, 'kept', 1));
      await context.saveChanges();
      if (changes != null) {
        await context.enableReactive();
        await changes.transaction(
            (tx) => tx.execute("INSERT INTO products VALUES(2,'stored',2)"));
      } else {
        await engine.execute("INSERT INTO products VALUES(2,'stored',2)");
      }
      final tracked = await set.query.where(id.eq(BigInt.one)).single();
      tracked.name = 'unsaved';
      set.add(Product(BigInt.two, 'duplicate', 3));
      inspector.clear();
      await expectLater(context.saveChanges(), throwsA(isA<SqlException>()));
      expect(engine.inTransaction, isFalse);
      expect(tracked.name, 'unsaved');
      expect(context.entry(tracked).state, EntityState.modified);
      expect(
          (await engine.query('SELECT name FROM products WHERE id=1'))
              .rows
              .single
              .single,
          'kept');
      expect(inspector.snapshot().failures, greaterThan(0));
    });
  }

  test(
      'ownership leases, custom scalars and close preserve the underlying contract',
      () async {
    final engine = await openInMemory();
    addTearDown(engine.close);
    final inspector = SqlInspector();
    final scalarType = EntityType<Product>(
        tableName: 'products',
        columns: [id, name, price],
        create: type.create,
        scalars: [
          EntityScalar<Product>(
              name: 'double_price',
              columns: [price],
              deterministic: true,
              apply: (args) => (args.single as BigInt) * BigInt.two)
        ]);
    final base = MutableDatabaseConnection(engine);
    final wrapped = inspector.ormConnection(base);
    final context = DbContext(wrapped, DbModel([scalarType]));
    expect(
        () =>
            DbContext(MutableDatabaseConnection(engine), DbModel([scalarType])),
        throwsA(isA<OrmStateException>()));
    expect(() => DbContext(wrapped, DbModel([scalarType])),
        throwsA(isA<OrmStateException>()));
    await context.migrations.ensureCreated();
    context.set(scalarType).add(Product(BigInt.one, 'one', 4));
    await context.saveChanges();
    expect(
        (await wrapped.query('SELECT double_price(price) FROM products'))
            .rows
            .single
            .single,
        BigInt.from(8));
    final plan =
        await wrapped.explain('SELECT * FROM products WHERE id=?', [1]);
    expect(plan.hasRowidBound, isTrue);
    await context.close();
    final next =
        DbContext(MutableDatabaseConnection(engine), DbModel([scalarType]));
    expect(await next.set(scalarType).query.count(), BigInt.one);
    await next.close();
    expect(() => inspector.ormConnection(wrapped), throwsArgumentError);
  });

  test('browser adapter saves and flushes through inspection', () async {
    final store = MemoryBrowserByteStore();
    final opened =
        await openBrowserStorage(name: 'inspector', probe: () async => store);
    final inspector = SqlInspector();
    final context = DbContext(
        inspector.ormConnection(await BrowserDatabaseConnection.open(opened)),
        DbModel([type]));
    await context.migrations.ensureCreated();
    context.set(type).add(Product(BigInt.one, 'browser', 4));
    await context.saveChanges();
    await context.close();
    final again =
        await openBrowserStorage(name: 'inspector', probe: () async => store);
    final reopened =
        DbContext(await BrowserDatabaseConnection.open(again), DbModel([type]));
    expect((await reopened.set(type).query.single()).name, 'browser');
    await reopened.close();
    expect(inspector.snapshot().statementCount, greaterThan(0));
  });
  test('direct update and upsert are visible through the observing ORM adapter',
      () async {
    final engine = await openInMemory();
    final inspector = SqlInspector();
    final context = DbContext(
        inspector.ormConnection(MutableDatabaseConnection(engine)),
        DbModel([type]));
    try {
      await context.migrations.ensureCreated();
      inspector.clear();
      await inspector.scope('direct-write', () async {
        await context.set(type).upsert(Product(BigInt.one, 'one', 4),
            conflictOn: [id], update: [price]);
        await context.set(type).query.update({price: price.add(2)});
      });
      final records = inspector.snapshot().records;
      expect(records.any((r) => r.sql.startsWith('INSERT')), isTrue);
      expect(records.any((r) => r.sql.startsWith('UPDATE')), isTrue);
      expect(inspector.snapshot().failures, 0);
      expect((await context.set(type).query.single()).price, 6);
    } finally {
      await context.close();
      await engine.close();
    }
  });
}
