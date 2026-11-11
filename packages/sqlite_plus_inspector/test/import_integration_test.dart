import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_changes/sqlite_plus_changes.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_orm.dart';
import 'package:test/test.dart';
import '../example/model.dart';

void main() {
  for (final capture in [false, true]) {
    test('import tracking/Reactive/Inspector and Changes capture=$capture',
        () async {
      final db = await openInMemory();
      await db.execute('PRAGMA recursive_triggers=ON');
      final feed = capture ? await SqlitePlusChanges.open(database: db) : null;
      final inspector = SqlInspector();
      final context = DbContext(
          inspector.ormConnection(MutableDatabaseConnection(db), changes: feed),
          DbModel([type]));
      try {
        await context.migrations.ensureCreated();
        final products = context.set(type);
        products.add(Product(BigInt.one, 'Original', 5));
        await context.saveChanges();
        final tracked = await products.query.single();
        final counts = <BigInt>[];
        final sub =
            products.query.where(price.gte(7)).watchCount().listen(counts.add);
        await context.flushReactive();
        expect(counts.last, BigInt.zero);
        final plan = await products.prepareImport(
            [Product(BigInt.one, '', 9), Product(BigInt.two, 'Second', 8)],
            conflictOn: [id],
            update: [name, price],
            emptyValues: OrmImportEmptyValues.keepExisting);
        expect(plan.canApply, isTrue);
        inspector.clear();
        await plan.apply(batchSize: 1);
        await context.flushReactive();
        expect(tracked.name, 'Original');
        expect(tracked.price, 9);
        expect(counts.last, BigInt.two);
        expect(
            inspector.snapshot().records.any((r) => r.sql.contains('INSERT')),
            isTrue);
        await sub.cancel();
      } finally {
        await context.close();
        inspector.close();
        await db.close();
      }
    });
  }
}
