import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
// These handwritten Column descriptors (sku, stock, amount, ...) and itemType
// are declared in the imported file; they are not built-in or generated names.
// amount maps to Item.price. Generator mappings use ItemColumns.price instead.
import 'lib/direct_write_model.dart';

Future<void> main() async {
  final db = await openInMemory();
  final context = DbContext(MutableDatabaseConnection(db), DbModel([itemType]));
  try {
    await context.migrations.ensureCreated();
    final items = context.set(itemType);
    await items.upsertMany([Item('a', price: 5), Item('b', price: 8)],
        conflictOn: [tenant, sku], update: [amount]);
    final tracked = await items.query.where(sku.eq('a')).single();
    final result = await items.query
        .where(sku.eq('a') & stock.gte(3) & revision.eq(BigInt.zero))
        .update({stock: stock.subtract(3)},
            returning: [itemId, stock, revision]);
    if (result.affectedRows != 1 ||
        tracked.stock != 7 ||
        tracked.revision != BigInt.one) {
      throw StateError('Atomic update/tracking assertions');
    }
    final upsert = await items.upsert(Item('a', price: 9, stock: 999),
        conflictOn: [tenant, sku], update: [amount]);
    if (upsert.rows.single['stock'] != BigInt.from(7) ||
        tracked.price != 9 ||
        tracked.revision != BigInt.two) {
      throw StateError('Selective upsert/version assertions');
    }
    var rejected = false;
    try {
      await items.upsertMany([Item('same'), Item('same')],
          conflictOn: [tenant, sku], update: [amount], batchSize: 1);
    } on OrmStateException {
      rejected = true;
    }
    if (!rejected || await items.query.count() != BigInt.two) {
      throw StateError('Batch duplicate/rollback assertions');
    }
    print(
        'Direct writes assertions passed: update, arithmetic, upsert, versions, tracking and rollback.');
  } finally {
    await context.close();
    await db.close();
  }
}
