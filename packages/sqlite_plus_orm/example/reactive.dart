import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

final class Product {
  Product(this.id, this.name, this.price);
  final BigInt id;
  String name;
  int price;
}

final id = Column<Product, BigInt>(
    property: 'id', codec: Codecs.bigInt, read: (x) => x.id, keyOrder: 0);
final name = Column<Product, String>(
    property: 'name',
    codec: Codecs.text,
    read: (x) => x.name,
    write: (x, v) => x.name = v);
final price = Column<Product, int>(
    property: 'price',
    codec: Codecs.integer,
    read: (x) => x.price,
    write: (x, v) => x.price = v);
final type = EntityType<Product>(
    tableName: 'products',
    columns: [id, name, price],
    create: (r) => Product(r.read(id), r.read(name), r.read(price)));

Future<void> main() async {
  final db = await openInMemory();
  final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
  await context.migrations.ensureCreated();
  final products = context.set(type);
  final snapshots = <ReactiveSnapshot<Product>>[];
  final subscription = products.query
      .where(price.lt(20))
      .orderBy([price.asc(), id.asc()])
      .watch()
      .listen(snapshots.add);
  try {
    await context.flushReactive();
    products.add(Product(BigInt.one, 'حليب', 10));
    await context.saveChanges();
    await context.flushReactive();
    if (snapshots.length != 2 || snapshots.last.items.single.name != 'حليب') {
      throw StateError('ORM reactive assertion failed');
    }
    final tracked = await products.query.single();
    tracked.name = 'unsaved';
    snapshots.last.items.single.name = 'independent';
    if (tracked.name != 'unsaved')
      throw StateError('Tracked entity was overwritten');
    print('ORM reactive assertions passed; tracked edits remain independent.');
  } finally {
    await subscription.cancel();
    await context.close();
    await db.close();
  }
}
