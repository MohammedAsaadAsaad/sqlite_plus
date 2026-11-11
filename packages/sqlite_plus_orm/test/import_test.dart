import 'dart:typed_data';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class Product {
  Product(this.sku, this.title, this.price, {this.id});
  BigInt? id;
  String? sku, title;
  int price;
}

final id = Column<Product, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    keyOrder: 0,
    generated: true,
    read: (x) => x.id,
    write: (x, v) => x.id = v);
final sku = Column<Product, String?>(
    property: 'sku',
    codec: Codecs.nullable(Codecs.text),
    read: (x) => x.sku,
    write: (x, v) => x.sku = v);
final title = Column<Product, String?>(
    property: 'title',
    codec: Codecs.nullable(Codecs.text),
    read: (x) => x.title,
    write: (x, v) => x.title = v);
final price = Column<Product, int>(
    property: 'price',
    codec: Codecs.integer,
    read: (x) => x.price,
    write: (x, v) => x.price = v);
final type = EntityType<Product>(
    tableName: 'products',
    columns: [id, sku, title, price],
    create: (r) =>
        Product(r.read(sku), r.read(title), r.read(price), id: r.read(id)));

void main() {
  late MutableSqliteDatabase db;
  late DbContext context;
  late DbSet<Product> products;
  setUp(() async {
    db = await openInMemory();
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,sku TEXT COLLATE NOCASE UNIQUE,title TEXT,price INTEGER NOT NULL CHECK(price>=0))');
    context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    products = context.set(type);
    await products.upsert(Product('a', 'Original', 5),
        conflictOn: [sku], update: [title, price]);
  });
  tearDown(() async {
    await context.close();
    await db.close();
  });

  test(
      'input snapshot, input counts, one-use atomic application and clean tracking',
      () async {
    final tracked = await products.query.where(sku.eq('a')).single();
    final input = Product('a', 'New', 7);
    final future = products.prepareImport([input, Product('b', 'Second', 8)],
        conflictOn: [sku], update: [title, price]);
    input.title = 'Late';
    final plan = await future;
    expect([
      plan.inputCount,
      plan.readyCount,
      plan.rejectedCount,
      plan.droppedCount
    ], [
      2,
      2,
      0,
      0
    ]);
    expect(plan.canApply, isTrue);
    expect((await plan.apply(returning: [sku, title])).affectedRows, 2);
    expect(tracked.title, 'New');
    expect(tracked.price, 7);
    expect(input.id, isNull);
    expect(plan.canApply, isFalse);
    await expectLater(plan.apply(), throwsA(isA<OrmStateException>()));
  });

  for (final policy in OrmImportDuplicates.values) {
    test('NOCASE duplicates use actual SQL identity: $policy', () async {
      final plan = await products.prepareImport(
          [Product('b', 'first', 1), Product('B', 'last', 2)],
          conflictOn: [sku], update: [title, price], duplicates: policy);
      if (policy == OrmImportDuplicates.reject) {
        expect(plan.canApply, isFalse);
        expect(plan.rejectedCount, 2);
        await expectLater(plan.apply(), throwsA(isA<OrmStateException>()));
      } else {
        expect(plan.droppedCount, 1);
        expect(plan.readyCount, 1);
        await plan.apply();
        final item = await products.query.where(sku.eq('b')).single();
        expect(item.title,
            policy == OrmImportDuplicates.keepFirst ? 'first' : 'last');
      }
    });
  }

  for (final value in <String?>[null, '', '   ']) {
    test(
        'keepExisting handles NULL/empty text, preserves spaces and insert input: "$value"',
        () async {
      final plan = await products.prepareImport(
          [Product('a', value, 9), Product('b', value, 10)],
          conflictOn: [sku],
          update: [title, price],
          emptyValues: OrmImportEmptyValues.keepExisting);
      await plan.apply();
      expect((await products.query.where(sku.eq('a')).single()).title,
          value == null || value == '' ? 'Original' : value);
      expect((await products.query.where(sku.eq('b')).single()).title, value);
      expect((await products.query.where(sku.eq('a')).single()).price, 9);
    });
  }

  test('overwrite NULL is explicit default', () async {
    final plan = await products.prepareImport([Product('a', null, 9)],
        conflictOn: [sku], update: [title]);
    await plan.apply();
    expect((await products.query.single()).title, isNull);
  });

  test('validation/null keys/codec errors are reviewable; no partial apply',
      () async {
    final plan = await products.prepareImport([
      Product(null, 'null', 1),
      Product('c', 'bad', -1),
      Product('d', 'ok', 1),
      Product('e', 'overflow', 9007199254740992)
    ], conflictOn: [
      sku
    ], update: [
      title,
      price
    ], validate: (p) => p.price < 0 ? 'Negative price' : null);
    expect(plan.readyCount, 1);
    expect(plan.rejectedCount, 3);
    expect(plan.issues.map((i) => i.code),
        ['nullKey', 'validation', 'invalidValue']);
    await expectLater(plan.apply(), throwsA(isA<OrmStateException>()));
    expect(await products.query.count(), BigInt.one);
  });

  test('later DB error rolls back all chunks; plan remains retryable',
      () async {
    final plan = await products.prepareImport(
        [Product('a', 'Changed', 7), Product('b', 'bad', -1)],
        conflictOn: [sku], update: [title, price]);
    final before = db.exportImage();
    await expectLater(plan.apply(batchSize: 1), throwsA(anything));
    expect(db.exportImage(), before);
    expect(plan.canApply, isTrue);
  });

  test('dirty contexts reject apply, and metadata drift is rejected', () async {
    final plan = await products.prepareImport([Product('a', 'Changed', 7)],
        conflictOn: [sku], update: [title]);
    final tracked = await products.query.single();
    tracked.title = 'Local';
    await expectLater(plan.apply(), throwsA(isA<OrmStateException>()));
    tracked.title = 'Original';
    await db.execute('ALTER TABLE products RENAME TO old_products');
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,sku TEXT COLLATE BINARY UNIQUE,title TEXT,price INTEGER NOT NULL)');
    await expectLater(plan.apply(), throwsA(isA<OrmStateException>()));
  });

  test('invalid mapping and row/parameter budget fail before writes', () async {
    await expectLater(
        products.prepareImport([], conflictOn: [sku], update: [sku]),
        throwsA(isA<OrmMappingException>()));
    await expectLater(
        products.prepareImport(
            Iterable.generate(10001, (i) => Product('$i', 'x', 1)),
            conflictOn: [sku],
            update: [title]),
        throwsRangeError);
    final empty =
        await products.prepareImport([], conflictOn: [sku], update: [title]);
    expect((await empty.apply()).affectedRows, 0);
  });
  test('mixed empty fields preserve values but NUL-prefixed text is nonempty',
      () async {
    await products.upsert(Product('b', 'Keep B', 1),
        conflictOn: [sku], update: [title, price]);
    final plan = await products.prepareImport(
        [Product('a', '\u0000x', 7), Product('b', '', 9)],
        conflictOn: [sku],
        update: [title, price],
        emptyValues: OrmImportEmptyValues.keepExisting);
    await plan.apply();
    expect((await products.query.where(sku.eq('a')).single()).title, '\u0000x');
    expect((await products.query.where(sku.eq('b')).single()).title, 'Keep B');
  });
  test('RTRIM duplicate identity is resolved by database collation', () async {
    await db.execute('ALTER TABLE products RENAME TO old_products');
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,sku TEXT COLLATE RTRIM UNIQUE,title TEXT,price INTEGER NOT NULL)');
    final plan = await products.prepareImport(
        [Product('x', 'first', 1), Product('x ', 'last', 2)],
        conflictOn: [sku],
        update: [title],
        duplicates: OrmImportDuplicates.keepFirst);
    expect(plan.droppedCount, 1);
    await plan.apply();
    expect((await products.query.single()).title, 'first');
  });

  test('BLOB conflict keys use SQL identity and snapshot input bytes',
      () async {
    final other = await openInMemory();
    final key = Column<(Uint8List, int), Uint8List>(
        property: 'key', codec: Codecs.blob, keyOrder: 0, read: (r) => r.$1);
    final value = Column<(Uint8List, int), int>(
        property: 'value', codec: Codecs.integer, read: (r) => r.$2);
    final mapped = EntityType<(Uint8List, int)>(
        tableName: 'blobs',
        columns: [key, value],
        create: (r) => (r.read(key), r.read(value)));
    final owner =
        DbContext(MutableDatabaseConnection(other), DbModel([mapped]));
    try {
      await owner.migrations.ensureCreated();
      final bytes = Uint8List.fromList([1]);
      final future = owner.set(mapped).prepareImport([
        (bytes, 1),
        (Uint8List.fromList([1]), 2)
      ], conflictOn: [
        key
      ], update: [
        value
      ], duplicates: OrmImportDuplicates.keepLast);
      bytes[0] = 99;
      final plan = await future;
      expect(plan.readyCount, 1);
      expect(plan.droppedCount, 1);
      await plan.apply();
      final result = await owner.set(mapped).query.single();
      expect(result.$1, [1]);
      expect(result.$2, 2);
    } finally {
      await owner.close();
      await other.close();
    }
  });
}
