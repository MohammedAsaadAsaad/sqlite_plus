import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_branch/sqlite_plus_branch.dart';

final class Product {
  Product(this.sku, this.name, this.price);
  final String sku;
  String? name;
  int price;
}

// These Columns and EntityType are HANDWRITTEN declarations. A generator model
// instead supplies ProductColumns.sku/name/price and ProductMapping.instance.
final skuColumn = Column<Product, String>(
    property: 'sku', codec: Codecs.text, keyOrder: 0, read: (p) => p.sku);
final nameColumn = Column<Product, String?>(
    property: 'name',
    codec: Codecs.nullable(Codecs.text),
    read: (p) => p.name,
    write: (p, v) => p.name = v);
final priceColumn = Column<Product, int>(
    property: 'price',
    codec: Codecs.integer,
    read: (p) => p.price,
    write: (p, v) => p.price = v);
final productType = EntityType<Product>(
    tableName: 'products',
    columns: [skuColumn, nameColumn, priceColumn],
    create: (r) =>
        Product(r.read(skuColumn), r.read(nameColumn), r.read(priceColumn)));

Future<void> main() async {
  final db = await openInMemory();
  final source =
      DbContext(MutableDatabaseConnection(db), DbModel([productType]));
  try {
    await source.migrations.ensureCreated();
    await source.set(productType).upsert(Product('A', 'Original', 500),
        conflictOn: [skuColumn], update: [nameColumn, priceColumn]);
  } finally {
    await source.close();
  }
  final rows = [
    Product('A', '', 550),
    Product('B', 'Second', 200),
    Product('B', 'Corrected second', 250)
  ];
  final branches = SqlitePlusBranches(database: db, sourceId: 'catalog');
  final preview = await branches.preview((draft) async {
    final context =
        DbContext(MutableDatabaseConnection(draft), DbModel([productType]));
    try {
      final plan = await context.set(productType).prepareImport(rows,
          conflictOn: [skuColumn],
          update: [nameColumn, priceColumn],
          duplicates: OrmImportDuplicates.keepLast,
          emptyValues: OrmImportEmptyValues.keepExisting,
          validate: (p) => p.price < 0 ? 'Negative price' : null);
      if (!plan.canApply || plan.readyCount != 2 || plan.droppedCount != 1) {
        throw StateError('Import preparation');
      }
      return await plan.apply();
    } finally {
      await context.close();
    }
  }, name: 'catalog-import');
  try {
    if (preview.value.affectedRows != 2 || preview.changes.length != 2) {
      throw StateError('Expected two actual row changes');
    }
    final before =
        (await db.query('SELECT price FROM products')).rows.single.single;
    if (before != BigInt.from(500)) throw StateError('Preview changed source');
    print(
        'Review: ${preview.changes.map((c) => '${c.kind} ${c.key}').join(', ')}');
    await preview
        .merge(); // Explicit acceptance; the import callback is not rerun.
    final merged =
        DbContext(MutableDatabaseConnection(db), DbModel([productType]));
    try {
      final products = merged.set(productType);
      final a = await products.query.where(skuColumn.eq('A')).single();
      final b = await products.query.where(skuColumn.eq('B')).single();
      if (a.price != 550 || a.name != 'Original' || b.price != 250) {
        throw StateError('Merged import');
      }
      print('Import preview assertions passed.');
    } finally {
      await merged.close();
    }
  } finally {
    await preview.close();
    await db.close();
  }
}
