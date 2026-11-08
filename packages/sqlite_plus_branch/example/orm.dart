import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch_orm.dart';

final class Product {
  Product(this.sku, this.price, this.stock);
  final String sku;
  int price, stock;
}

// These descriptors and the mapping are HANDWRITTEN here. With the generator,
// use ProductColumns.sku/price/stock and ProductMapping.instance instead.
final skuColumn = Column<Product, String>(
    property: 'sku', codec: Codecs.text, keyOrder: 0, read: (p) => p.sku);
final priceColumn = Column<Product, int>(
    property: 'price',
    codec: Codecs.integer,
    read: (p) => p.price,
    write: (p, v) => p.price = v);
final stockColumn = Column<Product, int>(
    property: 'stock',
    codec: Codecs.integer,
    read: (p) => p.stock,
    write: (p, v) => p.stock = v);
final productType = EntityType<Product>(
    tableName: 'products',
    columns: [skuColumn, priceColumn, stockColumn],
    create: (r) =>
        Product(r.read(skuColumn), r.read(priceColumn), r.read(stockColumn)));

Future<void> main() async {
  final db = await openInMemory();
  final source =
      DbContext(MutableDatabaseConnection(db), DbModel([productType]));
  await source.migrations.ensureCreated();
  await source.set(productType).upsert(Product('BISCUIT-001', 500, 100),
      conflictOn: [skuColumn], update: [priceColumn]);
  // Release source tracking/connection before the branch manager uses the engine.
  await source.close();
  final draft = await SqlitePlusBranches(database: db, sourceId: 'catalog')
      .create(name: 'prices');
  try {
    final context = DbContext(draft.ormConnection, DbModel([productType]));
    try {
      await context
          .set(productType)
          .query
          .where(skuColumn.eq('BISCUIT-001'))
          .update({priceColumn: 550});
    } finally {
      await context.close();
    }
    await db.execute('UPDATE products SET stock=97');
    await draft.merge();
    // A fresh main context reads merged values. Existing tracked entities and
    // Reactive registries are not refreshed by a raw branch merge in v1.
    final merged =
        DbContext(MutableDatabaseConnection(db), DbModel([productType]));
    try {
      final product = await merged.set(productType).query.single();
      if (product.price != 550 || product.stock != 97) {
        throw StateError('ORM branch merge');
      }
      print('ORM branch: price=${product.price}, stock=${product.stock}');
    } finally {
      await merged.close();
    }
  } finally {
    await draft.close();
    await db.close();
  }
}
