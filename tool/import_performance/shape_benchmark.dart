import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final class Product {
  Product(this.sku, this.name, this.price, {this.id});
  BigInt? id;
  String sku, name;
  int price;
}

final id = Column<Product, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    keyOrder: 0,
    generated: true,
    read: (r) => r.id,
    write: (r, v) => r.id = v);
final sku = Column<Product, String>(
    property: 'sku',
    codec: Codecs.text,
    read: (r) => r.sku,
    write: (r, v) => r.sku = v);
final name = Column<Product, String>(
    property: 'name',
    codec: Codecs.text,
    read: (r) => r.name,
    write: (r, v) => r.name = v);
final price = Column<Product, int>(
    property: 'price',
    codec: Codecs.integer,
    read: (r) => r.price,
    write: (r, v) => r.price = v);
final type = EntityType<Product>(
    tableName: 'products',
    columns: [id, sku, name, price],
    create: (r) =>
        Product(r.read(sku), r.read(name), r.read(price), id: r.read(id)));

Future<void> main(List<String> args) async {
  final count = int.parse(args[0]), mode = args[1];
  if (!['insert', 'update', 'mixed'].contains(mode)) {
    throw ArgumentError('mode');
  }
  final db = await openInMemory();
  final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
  try {
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,sku TEXT COLLATE NOCASE NOT NULL UNIQUE,name TEXT NOT NULL,price INTEGER NOT NULL CHECK(price>=0))');
    final existing = mode == 'insert'
        ? 0
        : mode == 'update'
            ? count
            : count ~/ 2;
    if (existing > 0) {
      await db.execute('INSERT INTO products VALUES ${[
        for (var i = 0; i < existing; i++) "(${i + 1},'sku$i','Original$i',5)"
      ].join(',')}');
    }
    final clock = Stopwatch()..start();
    final plan = await context.set(type).prepareImport(
        [for (var i = 0; i < count; i++) Product('SKU$i', 'Changed$i', i)],
        conflictOn: [sku], update: [name, price]);
    final prepare = clock.elapsedMicroseconds;
    clock
      ..reset()
      ..start();
    final applied = await plan.apply();
    clock.stop();
    if (applied.affectedRows != count) throw StateError('Affected count');
    final rows =
        (await db.query('SELECT id,sku,name,price FROM products ORDER BY id'))
            .rows;
    if (rows.length != count) throw StateError('Final count');
    for (var i = 0; i < count; i++) {
      if (rows[i][0] != BigInt.from(i + 1) ||
          rows[i][1] != (i < existing ? 'sku$i' : 'SKU$i') ||
          rows[i][2] != 'Changed$i' ||
          rows[i][3] != BigInt.from(i)) {
        throw StateError('Final data');
      }
    }
    final image = db.exportImage();
    final logical = jsonEncode(
        rows.map((r) => r.map((v) => v.toString()).toList()).toList());
    print(jsonEncode({
      'rows': count,
      'mode': mode,
      'prepare_us': prepare,
      'apply_us': clock.elapsedMicroseconds,
      'image_bytes': image.length,
      'logical_sha256': sha256.convert(utf8.encode(logical)).toString(),
      'image_sha256': sha256.convert(image).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await context.close();
    await db.close();
  }
}
