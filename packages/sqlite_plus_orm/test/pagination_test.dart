import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';
import 'reactive_model.dart';

void main() {
  test('ORM page infers keys, preserves filters, tracking and portable cursors',
      () async {
    final db = await openInMemory();
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    addTearDown(() async {
      await context.close();
      await db.close();
    });
    await context.migrations.ensureCreated();
    final set = context.set(type);
    for (var i = 1; i <= 7; i++) {
      set.add(Product(BigInt.from(i), 'item$i', i ~/ 2));
    }
    await context.saveChanges();
    final q = set.query.where(price.lt(3)).orderBy([price.desc()]);
    final first = await q.page(size: 2);
    expect(first.items.map((p) => p.id), [BigInt.from(4), BigInt.from(5)]);
    expect(
        identical(first.items.first,
            await set.query.where(id.eq(BigInt.from(4))).single()),
        isTrue);
    final second = await q.page(
        size: 2, after: PageCursor.parse(first.nextCursor!.encode()));
    expect(second.items.map((p) => p.id), [BigInt.two, BigInt.from(3)]);
    final back = await q.page(size: 2, before: second.previousCursor);
    expect(back.items, first.items);
    final detached = await q.asNoTracking().page(size: 2);
    expect(identical(detached.items.first, first.items.first), isFalse);
    first.items.first.price = 99;
    expect(context.entry(first.items.first).state, EntityState.modified);
    // Boundary comes from the SQL row, even if identity-map values are dirty.
    final repeated = await q.page(size: 2);
    expect(repeated.nextCursor!.encode(), first.nextCursor!.encode());
  });

  test(
      'default primary-key order and incompatible combinations fail explicitly',
      () async {
    final db = await openInMemory();
    final context = DbContext(MutableDatabaseConnection(db), DbModel([type]));
    addTearDown(() async {
      await context.close();
      await db.close();
    });
    await context.migrations.ensureCreated();
    final q = context.set(type).query;
    expect((await q.page()).items, isEmpty);
    await expectLater(q.take(2).page(), throwsA(isA<OrmStateException>()));
    await expectLater(q.skip(1).page(), throwsA(isA<OrmStateException>()));
    await expectLater(q.search('x').page(), throwsA(isA<OrmStateException>()));
    final expression = MappedField(name).at(r'$.label');
    await expectLater(q.orderBy([expression.ascending]).page(),
        throwsA(isA<OrmStateException>()));
    final first = await q.toList();
    expect(first, isEmpty);
  });
}
