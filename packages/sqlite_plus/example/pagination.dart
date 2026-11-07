import 'package:sqlite_plus/sqlite_plus.dart';

Future<void> main() async {
  final db = await openInMemory();
  try {
    await db.execute(
        'CREATE TABLE products(id INTEGER PRIMARY KEY,name TEXT,price INTEGER)');
    await db.execute(
        "INSERT INTO products VALUES(-9223372036854775808,'a',NULL),(2,'b',10),(3,'c',10),(9223372036854775807,'d',20)");
    final order = [PageOrder('price', nullsFirst: false)];
    final first = await db.page(
        table: 'products', keyColumns: ['id'], orderBy: order, size: 2);
    final second = await db.page(
        table: 'products',
        keyColumns: ['id'],
        orderBy: order,
        size: 2,
        after: PageCursor.parse(first.nextCursor!.encode()));
    final back = await db.page(
        table: 'products',
        keyColumns: ['id'],
        orderBy: order,
        size: 2,
        before: second.previousCursor);
    if (first.items.map((r) => r['id'].toString()).join(',') != '2,3' ||
        second.items.map((r) => r['id'].toString()).join(',') !=
            '9223372036854775807,-9223372036854775808' ||
        back.items.map((r) => r['id'].toString()).join(',') != '2,3' ||
        second.hasNextPage) {
      throw StateError('Pagination assertions failed');
    }
    var rejected = false;
    try {
      await db.page(
          table: 'products',
          keyColumns: ['id'],
          orderBy: order,
          size: 2,
          after: first.nextCursor,
          where: 'price>?',
          parameters: [15]);
    } on ArgumentError {
      rejected = true;
    }
    if (!rejected) {
      throw StateError('Wrong-query cursor accepted');
    }
    print(
        'Core pagination assertions passed: forward/back, nulls, ties, 64-bit cursor and query scope.');
  } finally {
    await db.close();
  }
}
