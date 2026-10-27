import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart'
    show MutableSqliteDatabase, QueryResult;
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

import 'orm_smoke_model.dart';

Object? encode(Object? value) {
  if (value is BigInt) return {'integer': value.toString()};
  if (value is Uint8List) {
    return {
      'blob': value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()
    };
  }
  return value;
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map<String, Object?> record(String sql, QueryResult result) => {
      'sql': sql,
      'columns': result.columns,
      'rows': [for (final row in result.rows) row.map(encode).toList()],
    };

Future<void> export(String directory, int encoding) async {
  final db =
      await MutableSqliteDatabase.create(pageSize: 512, encoding: encoding);
  var schema = SmokeModel();
  var context = DbContext(MutableDatabaseConnection(db), schema.model);
  try {
    await db.execute('CREATE TABLE unmanaged(value TEXT)');
    await db.execute("INSERT INTO unmanaged VALUES('retained')");
    await db
        .execute('CREATE VIEW unmanaged_view AS SELECT value FROM unmanaged');
    await context.migrations.ensureCreated();
    final parent = context
        .set(schema.people)
        .add(SmokePerson("Ali's 主", avatar: Uint8List.fromList([0, 127, 255])));
    final other =
        context.set(schema.people).add(SmokePerson('عربي', active: false));
    final child =
        context.set(schema.orders).add(SmokeOrder('first order', quantity: 2));
    child.reference(schema.orderOwner).set(parent);
    require(await context.saveChanges() == 3, 'linked insert count');
    require(
        parent.entity.id != null && other.entity.id != null, 'generated keys');
    require(
        child.entity.personId == parent.entity.id, 'provisional relationship');
    parent.entity.avatar![1] = 42;
    parent.entity.name = 'updated "主"';
    require(await context.saveChanges() == 1, 'snapshot change');
    require(parent.entity.revision == BigInt.two, 'optimistic revision');
    final loaded = await child.reference(schema.orderOwner).load();
    require(identical(loaded, parent.entity), 'relationship identity');
    final rows = await context
        .set(schema.people)
        .query
        .where(schema.active.eq(true))
        .toList();
    require(rows.length == 1 && identical(rows.single, parent.entity),
        'typed query');
    await context.close();

    schema = SmokeModel(withNote: true);
    context = DbContext(MutableDatabaseConnection(db), schema.model);
    final plan = await context.migrations.plan();
    require(!plan.requiresApproval && !plan.isEmpty, 'safe nullable addition');
    await context.migrations.applySafe(plan);
    require((await context.migrations.plan()).isEmpty, 'migration idempotence');
    final migrated =
        await context.set(schema.people).find(EntityKey([BigInt.one]));
    require(
        migrated != null && migrated.note == null, 'retained mapped values');
    migrated!.note = 'safe migration';
    await context.saveChanges();
    final people = quoteIdentifier(peopleTable),
        orders = quoteIdentifier(ordersTable);
    final queries = <Map<String, Object?>>[];
    for (final sql in [
      'SELECT * FROM $people ORDER BY id',
      'SELECT * FROM $orders ORDER BY id',
      'SELECT * FROM unmanaged_view',
      'PRAGMA table_xinfo($people)',
      'PRAGMA index_list($people)',
      'PRAGMA foreign_key_list($orders)',
      'PRAGMA integrity_check',
      'PRAGMA foreign_key_check',
      'PRAGMA encoding',
    ]) {
      queries.add(record(sql, await db.query(sql)));
    }
    await File('$directory/$encoding.db').writeAsBytes(db.exportImage());
    await File('$directory/$encoding.json').writeAsString(jsonEncode({
      'queries': queries,
      'native_writes': [
        [
          'INSERT INTO $people(id,"display name",active,created,avatar,revision,note) '
              'VALUES(?,?,?,?,?,?,?)',
          [
            {'integer': '1001'},
            'native س',
            {'integer': '1'},
            '2026-10-26T12:34:56.789123Z',
            {'blob': '0102'},
            {'integer': '7'},
            'SQLite',
          ]
        ],
        [
          'INSERT INTO $orders(id,personId,description,quantity) VALUES(?,?,?,?)',
          [
            {'integer': '1002'},
            {'integer': '1001'},
            'native order',
            {'integer': '3'},
          ]
        ],
      ],
    }));
  } finally {
    await context.close();
    await db.close();
  }
}

Future<void> readNative(String directory, int encoding) async {
  final file = File('$directory/$encoding.db');
  final db = await MutableSqliteDatabase.fromImage(await file.readAsBytes());
  final schema = SmokeModel(withNote: true);
  final context = DbContext(MutableDatabaseConnection(db), schema.model);
  try {
    require(
        (await context.migrations.plan()).isEmpty, 'native schema preserved');
    final person =
        await context.set(schema.people).find(EntityKey([BigInt.from(1001)]));
    require(person != null && person.name == 'native س' && person.active,
        'native person decoded');
    require(
        person!.avatar!.length == 2 &&
            person.avatar![1] == 2 &&
            person.created.toIso8601String() == '2026-10-26T12:34:56.789123Z' &&
            person.revision == BigInt.from(7),
        'native codecs');
    final order =
        await context.set(schema.orders).find(EntityKey([BigInt.from(1002)]));
    require(
        order != null &&
            order.quantity == 3 &&
            identical(
                await context.entry(order).reference(schema.orderOwner).load(),
                person),
        'native relationship decoded');
    person.name = 'Dart after native';
    require(
        await context.saveChanges() == 1 && person.revision == BigInt.from(8),
        'native continuation update');
    await file.writeAsBytes(db.exportImage());
  } finally {
    await context.close();
    await db.close();
  }
}

Future<void> main(List<String> arguments) async {
  final directory = arguments.first;
  await Directory(directory).create(recursive: true);
  for (var encoding = 1; encoding <= 3; encoding++) {
    if (arguments.contains('--read-native')) {
      await readNative(directory, encoding);
    } else {
      await export(directory, encoding);
    }
  }
}
