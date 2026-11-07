import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final class Item {
  Item(this.id, this.n);
  final BigInt id;
  int n;
}

final idColumn = Column<Item, BigInt>(
    property: 'id', codec: Codecs.bigInt, read: (x) => x.id, keyOrder: 0);
final nColumn = Column<Item, int>(
    property: 'n',
    codec: Codecs.integer,
    read: (x) => x.n,
    write: (x, v) => x.n = v);
final type = EntityType<Item>(
    tableName: 'items',
    columns: [idColumn, nColumn],
    create: (r) => Item(r.read(idColumn), r.read(nColumn)));
Future<void> workload(List<String> args) async {
  final count = args.isEmpty ? 100 : int.parse(args.first);
  final db = await openInMemory();
  final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
  final enabled = args.contains('--watch');
  var notifications = 0;
  final times = <String, int>{};
  Future<void> measure(String name, Future<void> Function() action) async {
    final clock = Stopwatch()..start();
    await action();
    clock.stop();
    times[name] = clock.elapsedMicroseconds;
  }

  StreamSubscription<ReactiveSnapshot<Item>>? subscription;
  try {
    await context.migrations.ensureCreated();
    subscription = enabled
        ? context
            .set(type)
            .query
            .take(20)
            .watch()
            .listen((_) => notifications++)
        : null;

    final items = context.set(type);
    if (enabled) await context.flushReactive();
    await measure('insert', () async {
      for (var i = 1; i <= count; i++) {
        items.add(Item(BigInt.from(i), i));
      }
      await context.saveChanges();
    });
    await measure('read_100', () async {
      for (var i = 0; i < 100; i++) {
        await items.query.take(20).asNoTracking().toList();
      }
    });
    final list = await items.query.toList();
    await measure('batch_update', () async {
      for (final item in list) {
        item.n += 100;
      }
      await context.saveChanges();
    });
    await measure('count_100', () async {
      for (var i = 0; i < 100; i++) {
        if (await items.query.count() != BigInt.from(count))
          throw StateError('count');
      }
    });
    if (enabled) await context.flushReactive();
    final sum = (await db.query('SELECT sum(n) FROM items')).rows.single.single;
    if (sum != BigInt.from(count * (count + 1) ~/ 2 + count * 100))
      throw StateError('checksum');
    final image = db.exportImage();
    print(jsonEncode({
      'rows': count,
      'watch_enabled': enabled,
      'notifications': notifications,
      'timings_us': times,
      'image_bytes': image.length,
      'image_sha256': sha256.convert(image).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await subscription?.cancel();
    await context.close();
    await db.close();
  }
}
