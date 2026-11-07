import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'reactive.dart' show Product, type, id, price;

Future<void> main() async {
  final db = await openInMemory();
  final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
  try {
    await context.migrations.ensureCreated();
    final products = context.set(type);
    for (var i = 1; i <= 6; i++) {
      products.add(Product(BigInt.from(i), 'item$i', i ~/ 2));
    }
    await context.saveChanges();
    final query =
        products.query.where(price.lt(3)).orderBy([price.desc(), id.asc()]);
    final first = await query.page(size: 2);
    final second = await query.page(
        size: 2, after: PageCursor.parse(first.nextCursor!.encode()));
    final back = await query.page(size: 2, before: second.previousCursor);
    if (first.items.map((p) => p.id.toString()).join(',') != '4,5' ||
        second.items.map((p) => p.id.toString()).join(',') != '2,3' ||
        !identical(first.items.first, back.items.first)) {
      throw StateError('ORM pagination assertions failed');
    }
    print(
        'ORM pagination assertions passed: filter, ordering, automatic keys and identity map.');
  } finally {
    await context.close();
    await db.close();
  }
}
