import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import '../../packages/sqlite_plus_orm/example/prepared.dart' as model;

Future<void> main() async {
  final db = await openInMemory();
  final context = DbContext(
      MutableDatabaseConnection(db), DbModel([model.mapping]),
      preparedQueryCacheSize: 16);
  try {
    await context.migrations.ensureCreated();
    await db.execute('INSERT INTO products VALUES ${[
      for (var i = 1; i <= 1000; i++) "($i,'p$i',${(i * 7919) % 1000})"
    ].join(',')}');
    final ordered =
        (await db.query('SELECT id FROM products ORDER BY price,id'))
            .rows
            .map((r) => r.single)
            .toList();
    final prepared = await db
        .prepare('SELECT id FROM products ORDER BY price,id LIMIT ? OFFSET ?');
    for (final k in [1, 31, 32, 33, 64, 1001]) {
      final rows =
          (await prepared.query([k, 7])).rows.map((r) => r.single).toList();
      final expected = ordered.skip(7).take(k).toList();
      if (rows.toString() != expected.toString()) {
        throw StateError('Prepared K=$k');
      }
    }
    await prepared.close();
    final query = context
        .set(model.mapping)
        .query
        .orderBy([model.price.asc(), model.id.asc()])
        .skip(7)
        .take(64)
        .asNoTracking();
    final typed = await query.prepare();
    final expected = ordered.skip(7).take(64).toList().toString();
    if ((await typed.toList()).map((p) => p.id).toList().toString() !=
        expected) {
      throw StateError('Typed');
    }
    if ((await query.toList()).map((p) => p.id).toList().toString() !=
        expected) {
      throw StateError('ORM');
    }
    await typed.close();
    print(
        'Optimizer bounded selection assertions passed: raw/prepared/ORM/cache, K/offset boundaries.');
  } finally {
    await context.close();
    await db.close();
  }
}
