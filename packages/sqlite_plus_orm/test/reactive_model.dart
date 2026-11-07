import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

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
