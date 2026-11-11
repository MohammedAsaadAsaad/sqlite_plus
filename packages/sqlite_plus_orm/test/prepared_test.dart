import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:test/test.dart';
import 'reactive_model.dart';

final class ObservedConnection extends OrmConnection {
  ObservedConnection(this.db);
  final MutableSqliteDatabase db;
  int reads = 0, writes = 0;
  @override
  MutableSqliteDatabase get engineDatabase => db;
  @override
  bool get inTransaction => db.inTransaction;
  @override
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    reads++;
    return db.query(sql, parameters);
  }

  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) {
    writes++;
    return db.execute(sql, parameters);
  }

  @override
  Future<void> close() async {}
}

void main() {
  test('adapter fallback preserves interception and unsupported SELECT works',
      () async {
    final db = await openInMemory();
    final adapter = ObservedConnection(db);
    try {
      await db.execute('CREATE TABLE t(n INTEGER)');
      await db.execute('INSERT INTO t VALUES(1),(2)');
      final write = await adapter.prepareCommand('UPDATE t SET n=? WHERE n=?');
      expect(write.usesEnginePreparation, false);
      await write.execute([3, 1]);
      expect(adapter.writes, 1);
      final read = await adapter.prepareCommand('SELECT n FROM t WHERE n=?');
      expect(read.usesEnginePreparation, false);
      expect((await read.query([3])).rows.single.single, BigInt.from(3));
      expect(adapter.reads, 1);
      final aggregate = await MutableDatabaseConnection(db)
          .prepareCommand('SELECT sum(n) FROM t');
      expect(aggregate.usesEnginePreparation, false);
      expect((await aggregate.query([])).rows.single.single, BigInt.from(5));
      await aggregate.close();
      await read.close();
      await write.close();
      expect(() => read.query([3]), throwsA(isA<OrmStateException>()));
    } finally {
      await db.close();
    }
  });
  test('typed nullable equality uses SQL NULL semantics', () async {
    final db = await openInMemory();
    final nullable = Column<Product, String?>(
        property: 'name',
        codec: Codecs.nullable(Codecs.text),
        read: (p) => p.name);
    final mapped = EntityType<Product>(
        tableName: 'products',
        columns: [id, nullable, price],
        create: (r) =>
            Product(r.read(id), r.read(nullable) ?? '', r.read(price)));
    final context = DbContext(MutableDatabaseConnection(db), DbModel([mapped]));
    try {
      await context.migrations.ensureCreated();
      await db.execute('INSERT INTO products VALUES(1,NULL,10)');
      final p = QueryParameter<String?>('name');
      final equal = await context
          .set(mapped)
          .query
          .where(nullable.eqParameter(p))
          .prepare();
      final safe = await context
          .set(mapped)
          .query
          .where(nullable.isParameter(p))
          .prepare();
      expect(await equal.toList(parameters: {p: null}), isEmpty);
      expect((await safe.toList(parameters: {p: null})).length, 1);
    } finally {
      await context.close();
      await db.close();
    }
  });
  test(
      'typed prepared reads bind codecs, preserve tracking and close with context',
      () async {
    final db = await openInMemory();
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    try {
      await context.migrations.ensureCreated();
      await db.execute("INSERT INTO products VALUES(1,'a',10),(2,'b',20)");
      final p = QueryParameter<int>('price');
      final query = await context
          .set(type)
          .query
          .where(price.gteParameter(p))
          .orderBy([id.asc()]).prepare();
      expect(query.usesEnginePreparation, true);
      final first = await query.toList(parameters: {p: 10});
      expect(first.length, 2);
      final second = await query.toList(parameters: {p: 20});
      expect(second.length, 1);
      expect(identical(first.last, second.single), true);
      await expectLater(
          query.toList(parameters: {}), throwsA(isA<OrmStateException>()));
      await expectLater(query.toList(parameters: {p: 'bad'}),
          throwsA(isA<OrmCodecException>()));
      final fresh = await context
          .set(type)
          .query
          .where(id.eq(BigInt.one))
          .asNoTracking()
          .prepare();
      await db.execute('UPDATE products SET price=30 WHERE id=1');
      expect((await fresh.toList()).single.price, 30);
      await context.close();
      expect(query.isClosed, true);
      expect(fresh.isClosed, true);
      await expectLater(
          query.toList(parameters: {p: 10}), throwsA(isA<OrmStateException>()));
    } finally {
      await context.close();
      await db.close();
    }
  });
  test('optional normal-query LRU is bounded, opt-in and schema aware',
      () async {
    final db = await openInMemory();
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]),
        preparedQueryCacheSize: 2);
    try {
      await context.migrations.ensureCreated();
      await db.execute("INSERT INTO products VALUES(1,'a',10),(2,'b',20)");
      final set = context.set(type);
      await set.query.where(price.gte(5)).toList();
      await set.query.where(price.gte(15)).toList();
      expect(context.preparedQueryCacheEntries, 1);
      await set.query.where(id.eq(BigInt.one)).toList();
      await set.query.where(name.eq('a')).toList();
      expect(context.preparedQueryCacheEntries, 2);
      await db.execute('ALTER TABLE products ADD COLUMN extra TEXT');
      expect((await set.query.where(name.eq('b')).toList()).length, 1);
      await context.clearPreparedQueries();
      expect(context.preparedQueryCacheEntries, 0);
    } finally {
      await context.close();
      await db.close();
    }
  });
  for (final captured in [false, true]) {
    test(
        'prepared update preserves direct-write tracking/reactive/capture capture=$captured',
        () async {
      final db = await openInMemory();
      await db.execute('PRAGMA recursive_triggers=ON');
      final feed = captured ? await SqlitePlusChanges.open(database: db) : null;
      final context = DbContext(MutableDatabaseConnection(db), DbModel([type]),
          changes: feed);
      try {
        await context.migrations.ensureCreated();
        final set = context.set(type);
        set.add(Product(BigInt.one, 'a', 10));
        await context.saveChanges();
        final tracked = await set.query.single();
        final counts = <BigInt>[];
        final sub =
            set.query.where(price.gte(15)).watchCount().listen(counts.add);
        await context.flushReactive();
        final key = QueryParameter<BigInt>('id'),
            value = QueryParameter<int>('price');
        final update = await set.query
            .where(id.eqParameter(key))
            .prepareUpdate({price: value}, returning: [id, price]);
        expect(update.usesEnginePreparation, !captured);
        final result =
            await update.execute(parameters: {key: BigInt.one, value: 20});
        expect(result.affectedRows, 1);
        expect(result.rows, [
          {'id': BigInt.one, 'price': BigInt.from(20)}
        ]);
        expect(tracked.price, 20);
        expect(context.entry(tracked).state, EntityState.unchanged);
        await context.flushReactive();
        expect(counts.last, BigInt.one);
        final read = await set.query.where(id.eqParameter(key)).prepare();
        expect(read.usesEnginePreparation, true);
        expect((await read.toList(parameters: {key: BigInt.one})).single.price,
            20);
        tracked.price = 99;
        await expectLater(
            update.execute(parameters: {key: BigInt.one, value: 30}),
            throwsA(isA<OrmStateException>()));
        await sub.cancel();
        await update.close();
        await read.close();
      } finally {
        await context.close();
        await db.close();
      }
    });
  }
  test('prepared update follows triggers, constraints and managed versions',
      () async {
    final db = await openInMemory();
    final ver = Column<Product, int>(
        property: 'ver', codec: Codecs.integer, version: true, read: (_) => 1);
    final versioned = EntityType<Product>(
        tableName: 'products',
        columns: [id, name, price, ver],
        create: (r) => Product(r.read(id), r.read(name), r.read(price)));
    final context =
        DbContext(MutableDatabaseConnection(db), DbModel([versioned]));
    try {
      await db.execute(
          'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT,price INTEGER CHECK(price>=0),ver INTEGER)');
      await db.execute("INSERT INTO products VALUES(1,'a',10,1)");
      await db.execute(
          'CREATE TRIGGER bump AFTER UPDATE OF price ON products BEGIN UPDATE products SET price=price+1 WHERE id=new.id; END');
      final key = QueryParameter<BigInt>('id'),
          value = QueryParameter<int>('price');
      final update = await context
          .set(versioned)
          .query
          .where(id.eqParameter(key))
          .prepareUpdate({price: value}, returning: [price, ver]);
      expect(
          (await update.execute(parameters: {key: BigInt.one, value: 20})).rows,
          [
            {'price': BigInt.from(21), 'ver': BigInt.two}
          ]);
      final before = db.exportImage();
      await expectLater(
          update.execute(parameters: {key: BigInt.one, value: -1}),
          throwsA(isA<SqlException>()));
      expect(db.exportImage(), before);
      expect(
          (await update.execute(parameters: {key: BigInt.one, value: 30}))
              .rows
              .single['ver'],
          BigInt.from(3));
      await update.close();
    } finally {
      await context.close();
      await db.close();
    }
  });
}
