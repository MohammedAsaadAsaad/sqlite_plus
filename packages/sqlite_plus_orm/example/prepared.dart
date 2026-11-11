import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final class Product {
  Product(this.id, this.name, this.price);
  final BigInt id;
  String name;
  int price;
}

// Handwritten metadata in this example. A generated model supplies the same
// Column/EntityType descriptors; these columns do not appear from SQL magically.
final id = Column<Product, BigInt>(
    property: 'id', codec: Codecs.bigInt, keyOrder: 0, read: (p) => p.id);
final name = Column<Product, String>(
    property: 'name',
    codec: Codecs.text,
    read: (p) => p.name,
    write: (p, v) => p.name = v);
final price = Column<Product, int>(
    property: 'price',
    codec: Codecs.integer,
    read: (p) => p.price,
    write: (p, v) => p.price = v);
final mapping = EntityType<Product>(
    tableName: 'products',
    columns: [id, name, price],
    create: (r) => Product(r.read(id), r.read(name), r.read(price)));

Future<void> main() async {
  final db = await openInMemory();
  final context = DbContext(MutableDatabaseConnection(db), DbModel([mapping]),
      preparedQueryCacheSize: 16);
  try {
    await context.migrations.ensureCreated();
    final products = context.set(mapping);
    products.add(Product(BigInt.one, 'Tea', 10));
    products.add(Product(BigInt.two, 'Coffee', 20));
    await context.saveChanges();
    final minimum = QueryParameter<int>('minimum');
    final read = await products.query
        .where(price.gteParameter(minimum))
        .asNoTracking()
        .prepare();
    if (!read.usesEnginePreparation) {
      throw StateError('Expected direct engine preparation');
    }
    if ((await read.toList(parameters: {minimum: 15})).single.name !=
        'Coffee') {
      throw StateError('Read');
    }
    final key = QueryParameter<BigInt>('id'),
        amount = QueryParameter<int>('price');
    final update = await products.query
        .where(id.eqParameter(key))
        .prepareUpdate({price: amount}, returning: [id, price]);
    if ((await update.execute(parameters: {key: BigInt.one, amount: 25}))
            .affectedRows !=
        1) {
      throw StateError('Update');
    }
    if ((await read.toList(parameters: {minimum: 15})).length != 2) {
      throw StateError('Fresh rows');
    }
    await read.close();
    await update.close();
    // Existing query APIs also reuse eligible command shapes when opted in.
    await products.query.where(price.gte(10)).toList();
    await products.query.where(price.gte(20)).toList();
    if (context.preparedQueryCacheEntries != 1) {
      throw StateError('Bounded cache');
    }
    print(
        'Prepared ORM assertions passed: typed bindings, current rows, updates, cache and lifetime.');
  } finally {
    await context.close();
    await db.close();
  }
}
