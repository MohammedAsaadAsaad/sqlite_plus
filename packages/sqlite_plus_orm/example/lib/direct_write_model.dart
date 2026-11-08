import 'dart:typed_data';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final class Item {
  Item(this.sku,
      {this.id,
      this.tenant = 1,
      this.price = 1,
      this.stock = 10,
      BigInt? revision,
      Uint8List? payload})
      : revision = revision ?? BigInt.zero,
        payload = payload ?? Uint8List(0);
  BigInt? id;
  int tenant, price, stock;
  String sku;
  BigInt revision;
  Uint8List payload;
}

final itemId = Column<Item, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    keyOrder: 0,
    generated: true,
    read: (x) => x.id,
    write: (x, v) => x.id = v);
final tenant = Column<Item, int>(
    property: 'tenant',
    codec: Codecs.integer,
    read: (x) => x.tenant,
    write: (x, v) => x.tenant = v);
final sku = Column<Item, String>(
    property: 'sku',
    codec: Codecs.text,
    read: (x) => x.sku,
    write: (x, v) => x.sku = v);
final amount = Column<Item, int>(
    property: 'price',
    codec: Codecs.integer,
    read: (x) => x.price,
    write: (x, v) => x.price = v);
final stock = Column<Item, int>(
    property: 'stock',
    codec: Codecs.integer,
    read: (x) => x.stock,
    write: (x, v) => x.stock = v);
final revision = Column<Item, BigInt>(
    property: 'revision',
    codec: Codecs.bigInt,
    version: true,
    read: (x) => x.revision,
    write: (x, v) => x.revision = v);
final payload = Column<Item, Uint8List>(
    property: 'payload',
    codec: Codecs.blob,
    read: (x) => x.payload,
    write: (x, v) => x.payload = v);
final itemType = EntityType<Item>(
    tableName: 'items',
    columns: [itemId, tenant, sku, amount, stock, revision, payload],
    indexes: [
      OrmIndex(name: 'item_sku', columns: [tenant, sku], unique: true)
    ],
    create: (r) => Item(r.read(sku),
        id: r.read(itemId),
        tenant: r.read(tenant),
        price: r.read(amount),
        stock: r.read(stock),
        revision: r.read(revision),
        payload: r.read(payload)));
const itemSchema =
    'CREATE TABLE items(id INTEGER PRIMARY KEY,tenant INTEGER NOT NULL,sku TEXT COLLATE NOCASE NOT NULL,price INTEGER NOT NULL,stock INTEGER NOT NULL,revision INTEGER NOT NULL,payload BLOB NOT NULL,UNIQUE(tenant,sku))';
