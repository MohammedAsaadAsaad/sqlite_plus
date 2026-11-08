import 'dart:async';
import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';
import 'support/write_model.dart';

final class GateConnection extends OrmConnection {
  GateConnection(this.database, {this.atCommit = false});
  final MutableSqliteDatabase database;
  final bool atCommit;
  bool armed = false;
  final entered = Completer<void>(), resume = Completer<void>();
  @override
  MutableSqliteDatabase get engineDatabase => database;
  @override
  bool get inTransaction => database.inTransaction;
  @override
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      database.query(sql, parameters);
  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    if (armed && (atCommit ? sql == 'COMMIT' : sql.startsWith('UPDATE '))) {
      armed = false;
      entered.complete();
      await resume.future;
    }
    return database.execute(sql, parameters);
  }

  @override
  Future<void> close() async {}
}

final class FaultConnection extends GateConnection {
  FaultConnection(super.database, {required this.rollbackFailure});
  final bool rollbackFailure;
  final operation = const SqlException('injected write failure');
  final cleanup = StateError('injected rollback failure');
  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    if (rollbackFailure && sql.startsWith('UPDATE ')) throw operation;
    if (rollbackFailure && sql == 'ROLLBACK') throw cleanup;
    final result = await super.execute(sql, parameters);
    if (!rollbackFailure && sql == 'COMMIT') {
      throw StateError('commit acknowledgement lost');
    }
    return result;
  }
}

final class Pair {
  const Pair(this.tenant, this.code, this.value);
  final BigInt tenant;
  final String code;
  final int value;
}

final pairTenant = Column<Pair, BigInt>(
    property: 'tenant',
    codec: Codecs.bigInt,
    keyOrder: 0,
    read: (x) => x.tenant);
final pairCode = Column<Pair, String>(
    property: 'code', codec: Codecs.text, keyOrder: 1, read: (x) => x.code);
final pairValue = Column<Pair, int>(
    property: 'value', codec: Codecs.integer, read: (x) => x.value);
final pairType = EntityType<Pair>(
    tableName: 'pairs',
    columns: [pairTenant, pairCode, pairValue],
    create: (r) =>
        Pair(r.read(pairTenant), r.read(pairCode), r.read(pairValue)));

void main() {
  late MutableSqliteDatabase db;
  late DbContext context;
  late DbSet<Item> items;
  setUp(() async {
    db = await openInMemory();
    context = DbContext(MutableDatabaseConnection(db), DbModel([itemType]));
    await context.migrations.ensureCreated();
    items = context.set(itemType);
  });
  tearDown(() async {
    await context.close();
    await db.close();
  });

  test('generated identities, selective conflict updates and managed revisions',
      () async {
    final input = Item('a', price: 7);
    final first =
        await items.upsert(input, conflictOn: [tenant, sku], update: [amount]);
    expect(input.id, isNull);
    expect(first.rows.single['id'], BigInt.one);
    final tracked = await items.query.single();
    final second = await items.upsert(Item('a', price: 9, stock: 999),
        conflictOn: [tenant, sku], update: [amount]);
    expect(second.rows.single['id'], BigInt.one);
    expect(tracked.price, 9);
    expect(tracked.stock, 10);
    expect(tracked.revision, BigInt.one);
    final changed = await items.query
        .where(itemId.eq(BigInt.one) & revision.eq(BigInt.one))
        .update({stock: stock.subtract(3)}, returning: [stock, revision]);
    expect(changed.rows, [
      {'stock': BigInt.from(7), 'revision': BigInt.two}
    ]);
    final stale = await items.query
        .where(itemId.eq(BigInt.one) & revision.eq(BigInt.one))
        .update({amount: 3});
    expect(stale.affectedRows, 0);
    expect(tracked.revision, BigInt.two);
    await expectLater(items.query.update({revision: BigInt.zero}),
        throwsA(isA<OrmMappingException>()));
  });

  test('a later chunk constraint failure rolls back the whole batch', () async {
    await db.execute('CREATE UNIQUE INDEX price_unique ON items(price)');
    await expectLater(
        items.upsertMany([Item('a', price: 4), Item('b', price: 4)],
            conflictOn: [tenant, sku], update: [amount], batchSize: 1),
        throwsA(isA<SqlException>()));
    expect(await items.query.count(), BigInt.zero);
    expect(db.inTransaction, isFalse);
  });

  test('NOCASE target and duplicates respect declared unique collation',
      () async {
    await context.close();
    await db.execute('DROP TABLE items');
    await db.execute(itemSchema);
    context = DbContext(MutableDatabaseConnection(db), DbModel([itemType]));
    items = context.set(itemType);
    await items.upsert(Item('abc', price: 1),
        conflictOn: [tenant, sku], update: [amount]);
    final result = await items.upsert(Item('ABC', price: 2),
        conflictOn: [tenant, sku], update: [amount]);
    expect(result.rows.single['id'], BigInt.one);
    expect(result.rows.single['sku'], 'abc');
    await expectLater(
        items.upsertMany([Item('a'), Item('A')],
            conflictOn: [tenant, sku], update: [amount], batchSize: 1),
        throwsA(isA<OrmStateException>()));
    expect(await items.query.count(), BigInt.one);
  });

  test('returning includes final AFTER-trigger effects across all chunks',
      () async {
    await db.execute(
        "CREATE TRIGGER inserted AFTER INSERT ON items WHEN new.sku='last' BEGIN UPDATE items SET stock=99 WHERE sku='first'; END");
    final result = await items.upsertMany(
        [Item('first'), Item('last', price: 2)],
        conflictOn: [tenant, sku], update: [amount], batchSize: 1);
    expect(result.rows.first['stock'], BigInt.from(99));
    await db.execute(
        'CREATE TRIGGER adjusted AFTER UPDATE OF price ON items BEGIN UPDATE items SET stock=new.price*2 WHERE id=new.id; END');
    final tracked = await items.query.where(sku.eq('first')).single();
    final update = await items.query
        .where(sku.eq('first'))
        .update({amount: 8}, returning: [stock]);
    expect(update.rows.single['stock'], BigInt.from(16));
    expect(tracked.stock, 16);
  });

  test('target deletion by trigger aborts and emits no partial store values',
      () async {
    await items.upsert(Item('a'), conflictOn: [tenant, sku], update: [amount]);
    final tracked = await items.query.single();
    await db.execute(
        'CREATE TRIGGER removed AFTER UPDATE OF price ON items BEGIN DELETE FROM items WHERE id=new.id; END');
    await expectLater(
        items.query.update({amount: 9}), throwsA(isA<OrmStateException>()));
    expect(tracked.price, 1);
    expect(await items.query.count(), BigInt.one);
  });

  test('codec overflow rolls back arithmetic and leaves context usable',
      () async {
    await items.upsert(Item('a', price: 9007199254740991),
        conflictOn: [tenant, sku], update: [amount]);
    await expectLater(items.query.update({amount: amount.add(1)}),
        throwsA(isA<OrmCodecException>()));
    expect((await items.query.single()).price, 9007199254740991);
  });

  test('result and input BLOBs are independent snapshots', () async {
    final bytes = Uint8List.fromList([1, 2]);
    final future = items.upsert(Item('a', payload: bytes),
        conflictOn: [tenant, sku], update: [amount]);
    bytes[0] = 99;
    final result = await future;
    expect(result.rows.single['payload'], [1, 2]);
    (result.rows.single['payload'] as Uint8List)[0] = 88;
    expect(result.rows.single['payload'], [1, 2]);
    expect((await items.query.single()).payload, [1, 2]);
  });

  test(
      'late field edits survive and a rejected overlap cannot unlock an active write',
      () async {
    await items.upsert(Item('a'), conflictOn: [tenant, sku], update: [amount]);
    await context.close();
    final gate = GateConnection(db);
    context = DbContext(gate, DbModel([itemType]));
    items = context.set(itemType);
    final tracked = await items.query.single();
    gate.armed = true;
    final values = <Column<Item, dynamic>, Object?>{amount: 10};
    final pending = items.query.update(values);
    await gate.entered.future;
    values[amount] = 999;
    tracked.price = 17;
    await expectLater(
        items.query.update({amount: 3}), throwsA(isA<OrmStateException>()));
    await expectLater(context.saveChanges(), throwsA(isA<OrmStateException>()));
    expect(() => items.add(Item('other')), throwsA(isA<OrmStateException>()));
    gate.resume.complete();
    await pending;
    expect(tracked.price, 17);
    expect(context.entry(tracked).state, EntityState.modified);
    expect((await items.query.asNoTracking().single()).price, 10);
    await context.saveChanges();
    expect((await items.query.asNoTracking().single()).price, 17);
  });

  test('empty batches, null conflict values and batch bounds are explicit',
      () async {
    expect(
        (await items
                .upsertMany([], conflictOn: [tenant, sku], update: [amount]))
            .affectedRows,
        0);
    await expectLater(
        items.upsert(Item('a'), conflictOn: [itemId], update: [amount]),
        throwsA(isA<OrmMappingException>()));
    await expectLater(
        items.upsertMany(List.generate(10001, (i) => Item('$i')),
            conflictOn: [tenant, sku], update: [amount]),
        throwsRangeError);
  });
  test(
      'late key mutation after commit poisons context instead of corrupting identity tracking',
      () async {
    await items.upsert(Item('a'), conflictOn: [tenant, sku], update: [amount]);
    await context.close();
    final gate = GateConnection(db, atCommit: true);
    context = DbContext(gate, DbModel([itemType]));
    items = context.set(itemType);
    final tracked = await items.query.single();
    gate.armed = true;
    final future = items.query.update({amount: 10});
    final failure = expectLater(future, throwsA(isA<OrmStateException>()));
    await gate.entered.future;
    tracked.id = BigInt.from(999);
    gate.resume.complete();
    await failure;
    await expectLater(items.query.count(), throwsA(isA<OrmStateException>()));
    expect(
        (await db.query('SELECT price FROM items WHERE id=1'))
            .rows
            .single
            .single,
        BigInt.from(10));
  });
  for (final rollbackFailure in [false, true]) {
    test(
        'direct-write transaction uncertainty poisons context rollbackFailure=$rollbackFailure',
        () async {
      await items
          .upsert(Item('a'), conflictOn: [tenant, sku], update: [amount]);
      await context.close();
      final connection = FaultConnection(db, rollbackFailure: rollbackFailure);
      context = DbContext(connection, DbModel([itemType]));
      items = context.set(itemType);
      Object? failure;
      try {
        await items.query.update({amount: 8});
      } catch (error) {
        failure = error;
      }
      expect(failure, isNotNull);
      if (rollbackFailure) {
        expect(failure, isA<OrmStateException>());
        final cause = (failure as OrmStateException).cause as ({
          Object operation,
          Object rollback
        });
        expect(cause.operation, same(connection.operation));
        expect(cause.rollback, same(connection.cleanup));
      } else {
        expect((await db.query('SELECT price FROM items')).rows.single.single,
            BigInt.from(8));
      }
      await expectLater(items.query.count(), throwsA(isA<OrmStateException>()));
    });
  }
  test('composite primary keys reconcile immutable tracked entities', () async {
    await context.close();
    context =
        DbContext(MutableDatabaseConnection(db), DbModel([itemType, pairType]));
    await context.migrations.ensureCreated();
    final pairs = context.set(pairType);
    await pairs.upsertMany([Pair(BigInt.one, 'a', 1), Pair(BigInt.one, 'b', 2)],
        conflictOn: [pairTenant, pairCode], update: [pairValue]);
    final old = await pairs.query.where(pairCode.eq('a')).single();
    final entry = context.entry(old);
    await pairs.query.where(pairCode.eq('a')).update({pairValue: 9});
    expect(entry.entity.value, 9);
    expect(identical(old, entry.entity), isFalse);
    final result = await pairs.upsert(Pair(BigInt.one, 'a', 11),
        conflictOn: [pairTenant, pairCode],
        update: [pairValue],
        returning: [pairTenant, pairCode]);
    expect(entry.entity.value, 11);
    expect(result.rows, [
      {'tenant': BigInt.one, 'code': 'a'}
    ]);
    expect(await pairs.query.count(), BigInt.two);
  });

  test(
      'RTRIM duplicates and ambiguous unique targets are rejected before source writes',
      () async {
    await context.close();
    await db.execute('DROP TABLE items');
    await db.execute(itemSchema.replaceFirst('NOCASE', 'RTRIM'));
    context = DbContext(MutableDatabaseConnection(db), DbModel([itemType]));
    items = context.set(itemType);
    await expectLater(
        items.upsertMany([Item('x'), Item('x ')],
            conflictOn: [tenant, sku], update: [amount]),
        throwsA(isA<OrmStateException>()));
    await db.execute(
        'CREATE UNIQUE INDEX second_unique ON items(tenant,sku COLLATE BINARY)');
    await expectLater(
        items.upsert(Item('x'), conflictOn: [tenant, sku], update: [amount]),
        throwsA(isA<OrmMappingException>()));
    expect(await items.query.count(), BigInt.zero);
  });
}
