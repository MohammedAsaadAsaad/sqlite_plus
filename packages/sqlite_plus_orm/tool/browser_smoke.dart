import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart' show MutableSqliteDatabase;
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

import 'orm_smoke_model.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final engine = await MutableSqliteDatabase.create(pageSize: 512);
  final schema = SmokeModel(withNote: true);
  final context = DbContext(MutableDatabaseConnection(engine), schema.model);
  try {
    await context.migrations.ensureCreated();
    final exact = BigInt.parse('9223372036854775807');
    final parent = context.set(schema.people).add(SmokePerson('JavaScript 主',
        id: exact, avatar: Uint8List.fromList([0, 127, 255]), note: 'browser'));
    final child = context.set(schema.orders).add(SmokeOrder('typed relation'));
    child.reference(schema.orderOwner).set(parent);
    require(await context.saveChanges() == 2, 'unit of work');
    require(child.entity.personId == exact, 'signed64 FK precision');
    final rows = await context
        .set(schema.people)
        .query
        .where(schema.personId.eq(exact) & schema.active.eq(true))
        .toList();
    require(
        rows.length == 1 && identical(rows.single, parent.entity), 'identity');
    parent.entity.avatar![0] = 42;
    parent.entity.name = 'updated 主';
    require(await context.saveChanges() == 1, 'snapshot update');
    require(parent.entity.revision == BigInt.two, 'revision');
    final loaded = await child.reference(schema.orderOwner).load();
    require(identical(loaded, parent.entity), 'reference load');
    require(
        (await context
                    .entry(parent.entity)
                    .collection(schema.orderOwner)
                    .load())
                .length ==
            1,
        'collection load');
    require(
        Codecs.bigInt.decode(Codecs.bigInt.encode(-exact - BigInt.one)) ==
            -exact - BigInt.one,
        'signed64 codec minimum');
    print('Pure Dart ORM JavaScript smoke passed');
  } finally {
    await context.close();
    await engine.close();
  }
}
