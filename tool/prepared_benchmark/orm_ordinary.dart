import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final class Item {
  Item(this.id, this.price);
  final BigInt id;
  final int price;
}

final id = Column<Item, BigInt>(
    property: 'id', codec: Codecs.bigInt, keyOrder: 0, read: (v) => v.id);
final price = Column<Item, int>(
    property: 'price', codec: Codecs.integer, read: (v) => v.price);
final mapping = EntityType<Item>(
    tableName: 'items',
    columns: [id, price],
    create: (r) => Item(r.read(id), r.read(price)));
Future<void> main() async {
  final db = await openInMemory();
  final context = DbContext(MutableDatabaseConnection(db), DbModel([mapping]));
  await context.migrations.ensureCreated();
  await db.execute('INSERT INTO items VALUES ${[
    for (var i = 1; i <= 100; i++) '($i,$i)'
  ].join(',')}');
  db.exportImage();
  var checksum = 0;
  final timer = Stopwatch()..start();
  for (var i = 0; i < 3000; i++) {
    final rows = await context
        .set(mapping)
        .query
        .where(price.gte(i % 90 + 1))
        .asNoTracking()
        .toList();
    checksum += rows.length;
  }
  timer.stop();
  print(jsonEncode({
    'duration_us': timer.elapsedMicroseconds,
    'checksum': checksum,
    'image_bytes': db.exportImage().length,
    'rss': ProcessInfo.currentRss
  }));
  await context.close();
  await db.close();
}
