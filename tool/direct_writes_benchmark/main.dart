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

final id = Column<Item, BigInt>(
    property: 'id', codec: Codecs.bigInt, read: (x) => x.id, keyOrder: 0);
final n = Column<Item, int>(
    property: 'n',
    codec: Codecs.integer,
    read: (x) => x.n,
    write: (x, v) => x.n = v);
final type = EntityType<Item>(
    tableName: 'items',
    columns: [id, n],
    create: (r) => Item(r.read(id), r.read(n)));

final class CountedConnection extends OrmConnection {
  CountedConnection(this.db);
  final MutableSqliteDatabase db;
  int reads = 0, writes = 0;
  @override
  bool get inTransaction => db.inTransaction;
  @override
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    reads++;
    return db.query(sql, parameters);
  }

  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) {
    writes++;
    return db.execute(sql, parameters);
  }

  @override
  Future<void> close() async {}
}

Future<void> main(List<String> args) async {
  final mode = args.isEmpty ? 'update' : args.first;
  final count = args.length < 2 ? 100 : int.parse(args[1]);
  if (!['tracked', 'update', 'upsert'].contains(mode) ||
      ![100, 1000].contains(count)) throw ArgumentError('mode/size');
  final db = await openInMemory();
  final connection = CountedConnection(db);
  final context = DbContext(connection, DbModel([type]));
  try {
    await context.migrations.ensureCreated();
    await db.execute('INSERT INTO items VALUES ${[
      for (var i = 1; i <= count; i++) '($i,$i)'
    ].join(',')}');
    final set = context.set(type);
    connection.reads = 0;
    connection.writes = 0;
    final clock = Stopwatch()..start();
    if (mode == 'tracked') {
      final rows = await set.query.toList();
      for (final row in rows) {
        row.n++;
      }
      await context.saveChanges();
    } else if (mode == 'update') {
      final result = await set.query.update({n: n.add(1)});
      if (result.affectedRows != count) throw StateError('Update count');
    } else {
      final result = await set.upsertMany(
          [for (var i = 1; i <= count; i++) Item(BigInt.from(i), i + 1)],
          conflictOn: [id], update: [n], returning: [], batchSize: 200);
      if (result.affectedRows != count) throw StateError('Upsert count');
    }
    clock.stop();
    final actual = await db.query('SELECT id,n FROM items ORDER BY id');
    if (actual.rows.length != count) throw StateError('Row count');
    for (var i = 0; i < count; i++) {
      if (actual.rows[i][0] != BigInt.from(i + 1) ||
          actual.rows[i][1] != BigInt.from(i + 2))
        throw StateError('Row checksum');
    }
    final logical = jsonEncode(
        [for (final row in actual.rows) row.map((v) => v.toString()).toList()]);
    final image = db.exportImage();
    print(jsonEncode({
      'mode': mode,
      'rows': count,
      'duration_us': clock.elapsedMicroseconds,
      'orm_queries': connection.reads,
      'orm_executes': connection.writes,
      'image_bytes': image.length,
      'image_sha256': sha256.convert(image).toString(),
      'logical_sha256': sha256.convert(utf8.encode(logical)).toString(),
      'rss': ProcessInfo.currentRss,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await context.close();
    await db.close();
  }
}
