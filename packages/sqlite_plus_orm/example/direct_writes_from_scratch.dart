import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

// MANUAL MAPPING EXAMPLE: every Column and EntityType below is handwritten.
// skuColumn/priceColumn/stockColumn are local names chosen by this example;
// importing sqlite_plus_orm does not create them.
//
// With sqlite_plus_generator, an annotated Product model instead gets:
//   ProductColumns.sku / ProductColumns.price / ProductColumns.stock
//   ProductMapping.instance
// Use those generated members in the same queries; do not duplicate the manual
// mapping below. See ../doc/DIRECT_WRITES.md (from the example directory).
//
// 1. Application data. Store prices in the smallest currency unit: 500 = 5.00.
final class Product {
  Product(this.sku, {required this.price, required this.stock});
  final String sku;
  int price;
  int stock;
}

// 2. Handwritten mapping descriptors. Each `final ... = Column(...)` below
// DECLARES the name used later in the queries. product.stock is an int value;
// stockColumn is a Column<Product, int> descriptor, not a stored stock value.
final skuColumn = Column<Product, String>(
  property: 'sku',
  codec: Codecs.text,
  keyOrder: 0,
  read: (product) => product.sku,
);
final priceColumn = Column<Product, int>(
  property: 'price',
  codec: Codecs.integer,
  read: (product) => product.price,
  write: (product, value) => product.price = value,
);
final stockColumn = Column<Product, int>(
  property: 'stock',
  codec: Codecs.integer,
  read: (product) => product.stock,
  write: (product, value) => product.stock = value,
);

// 3. Handwritten table mapping and factory for materializing rows as objects.
// In the generator alternative, ProductMapping.instance supplies this mapping.
final productType = EntityType<Product>(
  tableName: 'products',
  columns: [skuColumn, priceColumn, stockColumn],
  create: (row) => Product(
    row.read(skuColumn),
    price: row.read(priceColumn),
    stock: row.read(stockColumn),
  ),
);

Future<void> main() async {
  // 4. Open the database, register the model, then create its schema.
  final db = await openInMemory();
  final context = DbContext(
    MutableDatabaseConnection(db),
    DbModel([productType]),
  );
  try {
    await context.migrations.ensureCreated();
    // productType is declared above; products is the DbSet returned here.
    // Generator alternative: context.set(ProductMapping.instance).
    final products = context.set(productType);

    // 5. First call inserts; a later matching SKU updates only price.
    await products.upsert(
      Product('BISCUIT-001', price: 500, stock: 10),
      conflictOn: [skuColumn],
      update: [priceColumn],
    );
    final product =
        await products.query.where(skuColumn.eq('BISCUIT-001')).single();
    print('Before: price=${product.price}, stock=${product.stock}');

    // 6. Filter and arithmetic run in one UPDATE; no saveChanges is needed.
    const quantity = 3;
    final result = await products.query
        .where(skuColumn.eq('BISCUIT-001') & stockColumn.gte(quantity))
        .update(
      {stockColumn: stockColumn.subtract(quantity)},
      returning: [skuColumn, stockColumn],
    );
    print('Changed: ${result.affectedRows}, rows: ${result.rows}');
    if (result.affectedRows != 1 || product.stock != 7) {
      throw StateError('Atomic update and tracked stock should agree');
    }

    // 7. Conflict updates price to 650, preserving the stored stock of 7.
    await products.upsert(
      Product('BISCUIT-001', price: 650, stock: 999),
      conflictOn: [skuColumn],
      update: [priceColumn],
    );
    print('After: price=${product.price}, stock=${product.stock}');
    if (product.price != 650 || product.stock != 7) {
      throw StateError('Selective upsert should preserve stock');
    }
  } finally {
    await context.close();
    await db.close();
  }
}
