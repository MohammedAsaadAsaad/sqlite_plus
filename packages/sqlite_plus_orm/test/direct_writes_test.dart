import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:test/test.dart';
import 'reactive_model.dart';

void main() {
  for (final captured in [false, true]) {
    test(
        'update constants/arithmetic, live tracking, returning and watches capture=$captured',
        () async {
      final db = await openInMemory();
      await db.execute('PRAGMA recursive_triggers=ON');
      final feed = captured ? await SqlitePlusChanges.open(database: db) : null;
      final context = DbContext(MutableDatabaseConnection(db), DbModel([type]),
          changes: feed);
      addTearDown(() async {
        await context.close();
        await db.close();
      });
      await context.migrations.ensureCreated();
      final products = context.set(type);
      products.add(Product(BigInt.one, 'one', 5));
      products.add(Product(BigInt.two, 'two', 8));
      await context.saveChanges();
      final first = await products.query.where(id.eq(BigInt.one)).single();
      final counts = <BigInt>[];
      final sub =
          products.query.where(price.gte(7)).watchCount().listen(counts.add);
      await context.flushReactive();
      expect(counts.last, BigInt.one);
      final result = await products.query.where(id.eq(BigInt.one)).update(
          {price: price.add(3), name: 'updated'},
          returning: [id, price]);
      expect(result.affectedRows, 1);
      expect(result.rows, [
        {'id': BigInt.one, 'price': BigInt.from(8)}
      ]);
      expect(first.price, 8);
      expect(first.name, 'updated');
      expect(context.entry(first).state, EntityState.unchanged);
      await context.flushReactive();
      expect(counts.last, BigInt.two);
      final noMatch = await products.query
          .where(price.gte(100))
          .update({price: price.subtract(2)});
      expect(noMatch.affectedRows, 0);
      expect(noMatch.rows, isEmpty);
      expect(
          (await products.query.update({price: price.subtract(1)}))
              .affectedRows,
          2);
      expect(first.price, 7);
      first.price = 20;
      await expectLater(
          products.query.update({price: 0}), throwsA(isA<OrmStateException>()));
      expect(
          BigInt.from((await products.query
                  .where(id.eq(BigInt.one))
                  .asNoTracking()
                  .single())
              .price),
          BigInt.from(7));
      await sub.cancel();
    });
    test(
        'upsert atomic insert/update, keys returned, batches rollback capture=$captured',
        () async {
      final db = await openInMemory();
      await db.execute('PRAGMA recursive_triggers=ON');
      final feed = captured ? await SqlitePlusChanges.open(database: db) : null;
      final context = DbContext(MutableDatabaseConnection(db), DbModel([type]),
          changes: feed);
      addTearDown(() async {
        await context.close();
        await db.close();
      });
      await context.migrations.ensureCreated();
      final products = context.set(type);
      final added = await products.upsert(Product(BigInt.one, 'one', 5),
          conflictOn: [id], update: [price]);
      expect(added.rows.single['id'], BigInt.one);
      final tracked = await products.query.single();
      final modified = await products.upsert(Product(BigInt.one, 'ignored', 9),
          conflictOn: [id], update: [price]);
      expect(modified.rows.single['name'], 'one');
      expect(tracked.name, 'one');
      expect(tracked.price, 9);
      final batch = await products.upsertMany([
        Product(BigInt.one, 'unused', 10),
        Product(BigInt.two, 'two', 2),
        Product(BigInt.from(3), 'three', 3)
      ], conflictOn: [
        id
      ], update: [
        price
      ], returning: [
        id
      ], batchSize: 1);
      expect(batch.affectedRows, 3);
      expect(batch.rows.length, 3);
      expect(tracked.price, 10);
      await expectLater(
          products.upsertMany([
            Product(BigInt.from(4), 'a', 4),
            Product(BigInt.from(4), 'b', 5)
          ], conflictOn: [
            id
          ], update: [
            price
          ], batchSize: 1),
          throwsA(isA<OrmStateException>()));
      expect(await products.query.count(), BigInt.from(3));
      await expectLater(
          products.upsert(Product(BigInt.from(4), 'a', 4),
              conflictOn: [name], update: [price]),
          throwsA(isA<OrmMappingException>()));
    });
  }
  test(
      'unsupported shapes/assignments and foreign mappings fail without writing',
      () async {
    final db = await openInMemory();
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    addTearDown(() async {
      await context.close();
      await db.close();
    });
    await context.migrations.ensureCreated();
    final products = context.set(type);
    for (final call in <Future<Object?> Function()>[
      () => products.query.take(1).update({price: 1}),
      () => products.query.orderBy([id.asc()]).update({price: 1}),
      () => products.query.update({id: BigInt.one}),
      () => products.query.update({}),
      () => products
          .upsert(Product(BigInt.one, 'a', 1), conflictOn: [id], update: [id]),
      () => products
          .upsertMany([], conflictOn: [id], update: [price], batchSize: 0),
      () => TypedQuery(type: type, connection: MutableDatabaseConnection(db))
          .update({price: 1}),
    ]) {
      await expectLater(call(), throwsA(anything));
    }
    expect(await products.query.count(), BigInt.zero);
  });
  test(
      'zero direct changes still invalidate BEFORE IGNORE trigger side effects',
      () async {
    final db = await openInMemory();
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    try {
      await context.migrations.ensureCreated();
      final set = context.set(type);
      await set.upsertMany(
          [Product(BigInt.one, 'one', 5), Product(BigInt.two, 'two', 8)],
          conflictOn: [id], update: [price]);
      await db.execute(
          'CREATE TRIGGER ignored BEFORE UPDATE OF price ON products WHEN new.id=1 BEGIN UPDATE products SET price=20 WHERE id=2; SELECT RAISE(IGNORE); END');
      final counts = <BigInt>[];
      final sub =
          set.query.where(price.gte(10)).watchCount().listen(counts.add);
      await context.flushReactive();
      expect(counts.last, BigInt.zero);
      final result =
          await set.query.where(id.eq(BigInt.one)).update({price: 9});
      expect(result.affectedRows, 0);
      await context.flushReactive();
      expect(counts.last, BigInt.one);
      await sub.cancel();
    } finally {
      await context.close();
      await db.close();
    }
  });
}
