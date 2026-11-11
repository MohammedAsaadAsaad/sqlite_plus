import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';
import 'reactive_model.dart';

void main() {
  for (final cacheSize in [0, 16]) {
    test('ordered pagination is identical for ORM/prepared/cache=$cacheSize',
        () async {
      final db = await openInMemory();
      final context = DbContext(MutableDatabaseConnection(db), DbModel([type]),
          preparedQueryCacheSize: cacheSize);
      try {
        await context.migrations.ensureCreated();
        await db.execute('INSERT INTO products VALUES ${[
          for (var i = 1; i <= 350; i++) "($i,'p$i',${(i * 67) % 350})"
        ].join(',')}');
        final query = context
            .set(type)
            .query
            .orderBy([price.asc(), id.asc()])
            .skip(11)
            .take(64)
            .asNoTracking();
        final prepared = await query.prepare();
        for (final key in [1, 2]) {
          final expected =
              (await db.query('SELECT id FROM products ORDER BY price,id'))
                  .rows
                  .skip(11)
                  .take(64)
                  .map((r) => r.single)
                  .toList();
          expect((await query.toList()).map((p) => p.id).toList(), expected);
          expect((await prepared.toList()).map((p) => p.id).toList(), expected);
          await db.execute('UPDATE products SET price=-100 WHERE id=?', [key]);
        }
        await prepared.close();
      } finally {
        await context.close();
        await db.close();
      }
    });
  }
}
