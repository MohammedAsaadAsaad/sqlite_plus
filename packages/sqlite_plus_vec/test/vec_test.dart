import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';
import 'package:test/test.dart';

void main() {
  test('l2 and cosine distances cover equal, orthogonal, and zero vectors', () {
    expect(vecDistance(const [0, 0], const [3, 4], 'l2'), 5);
    expect(vecDistance(const [1, 0], const [1, 0], DbVectorMetrics.cosine), 0);
    expect(vecDistance(const [1, 0], const [0, 1], 'cosine'), 1);
    expect(vecDistance(const [1, 0], const [-1, 0], 'COSINE'), 2);
    expect(vecDistance(const [0, 0], const [0, 0], 'cosine'), 0);
    expect(vecDistance(const [0, 0], const [1, 0], 'cosine'), 1);
    expect(() => vecDistance(const [1], const [1, 0], 'l2'),
        throwsA(isA<SqlException>()));
    expect(
        () => vecDistance(const [1], const [1], 'hamming'),
        throwsA(predicate<SqlException>(
            (error) => error.message.contains('unknown distance metric'))));
    expect(decodeVec(encodeVec(const [0.5, -2, 0.25])), const [0.5, -2, 0.25]);
    expect(() => encodeVec(const [double.nan]), throwsA(isA<SqlException>()));
    expect(() => encodeVec(const []), throwsA(isA<SqlException>()));
  });

  test('MATCH returns the nearest k rows and rejects a bad vector', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    await expectLater(
        database.execute(
            'CREATE VIRTUAL TABLE items USING vec0(embedding float[2])'),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'No such module: vec0')));
    SqlitePlusVec.register(database);
    SqlitePlusVec.register(database);
    await database
        .execute('CREATE VIRTUAL TABLE items USING vec0(embedding float[2])');
    await database.execute(
        'INSERT INTO items(rowid, embedding) VALUES (1, ?), (2, ?), (3, ?)', [
      encodeVec(const [1, 0]),
      encodeVec(const [0, 1]),
      encodeVec(const [0.2, 0.1]),
    ]);
    final near = await database.query(
        'SELECT rowid, distance FROM items WHERE embedding MATCH ? AND k = 2', [
      encodeVec(const [0.9, 0.1])
    ]);
    expect(near.rows.map((row) => row[0]), [BigInt.one, BigInt.from(3)]);
    expect(near.rows.first[1], isA<double>());
    expect(
        (near.rows.first[1] as double) < (near.rows[1][1] as double), isTrue);
    await expectLater(
        database.query(
            'SELECT rowid FROM items WHERE embedding MATCH ? AND k = 0', [
          encodeVec(const [1, 0])
        ]),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'vec0: k is out of range')));
    await expectLater(
        database.query('SELECT rowid FROM items WHERE embedding MATCH ?', [
          encodeVec(const [1, 0])
        ]),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'vec0: k is required')));
    await database.execute('INSERT INTO items(embedding) VALUES (?)', [
      Uint8List.fromList(const [1, 2, 3, 4, 5])
    ]);
    await expectLater(
        database.query('SELECT embedding FROM items'),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'vec0 dimension mismatch')));
  });

  test('rows reopen, delete, and cosine order stays on the shadow table',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    SqlitePlusVec.register(database);
    await database.execute(
        'CREATE VIRTUAL TABLE items USING vec0(embedding float[2] distance_metric=cosine)');
    await database.execute('BEGIN');
    await database
        .execute('INSERT INTO items(rowid, embedding) VALUES (7, ?)', [
      encodeVec(const [1, 0])
    ]);
    await database.execute('ROLLBACK');
    expect((await database.query('SELECT count(*) FROM items')).rows.single,
        [BigInt.zero]);
    await database
        .execute('INSERT INTO items(rowid, embedding) VALUES (7, ?), (8, ?)', [
      encodeVec(const [1, 0]),
      encodeVec(const [0, 1])
    ]);
    final image = database.exportImage();
    final reopened = await MutableSqliteDatabase.fromImage(image);
    addTearDown(reopened.close);
    reopened.functions.virtualTables.register(Vec0Module());
    final near = await reopened
        .query('SELECT rowid FROM items WHERE embedding MATCH ? AND k = 1', [
      encodeVec(const [0, 1])
    ]);
    expect(near.rows, [
      [BigInt.from(8)]
    ]);
    await reopened.execute('DELETE FROM items WHERE rowid = 8');
    final left = await reopened.query('SELECT rowid FROM items');
    expect(left.rows, [
      [BigInt.from(7)]
    ]);
    await reopened.execute('DROP TABLE items');
    await expectLater(reopened.query('SELECT * FROM items_vec'),
        throwsA(isA<SqlException>()));
    await expectLater(
        reopened
            .execute('CREATE VIRTUAL TABLE bad USING vec0(embedding float[0])'),
        throwsA(isA<SqlException>()));
    await expectLater(
        reopened.execute(
            'CREATE VIRTUAL TABLE bad USING vec0(embedding float[2] distance_metric=hamming)'),
        throwsA(predicate<SqlException>(
            (error) => error.message.contains('unknown distance metric'))));
  });

  test('rankVec0 scores eligible rows before k and pages the shadow table',
      () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    SqlitePlusVec.register(database);
    await database.execute(
        'CREATE VIRTUAL TABLE items USING vec0(embedding float[2] distance_metric=cosine)');
    await database.execute(
        'INSERT INTO items(rowid, embedding) VALUES (1, ?), (2, ?), (3, ?)', [
      encodeVec(const [1, 0]),
      encodeVec(const [0, 1]),
      encodeVec(const [0.2, 0.1]),
    ]);
    final eligible = await rankVec0(database,
        table: 'items',
        query: const [0.9, 0.1],
        rowIds: [BigInt.two, BigInt.from(3)]);
    expect(eligible.map((score) => score.rowId), [BigInt.from(3), BigInt.two]);
    expect(eligible.first.distance < eligible.last.distance, isTrue);
    expect(
        await rankVec0(database,
            table: 'items', query: const [1, 0], rowIds: const []),
        isEmpty);
    await expectLater(
        rankVec0(database,
            table: 'items', query: const [1, 0], rowIds: [BigInt.from(99)]),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'vec0 row is missing')));
    await database
        .execute('INSERT INTO items(rowid, embedding) VALUES (9, ?)', [
      encodeVec(const [0, 0])
    ]);
    expect(
        (await rankVec0(database,
                table: 'items', query: const [1, 0], rowIds: [BigInt.from(9)]))
            .single
            .distance,
        1);
    await expectLater(
        rankVec0(database,
            table: 'items',
            query: const [1, 0],
            rowIds: [BigInt.from(9)],
            rejectZeroVectors: true),
        throwsA(predicate<SqlException>(
            (error) => error.message == 'vec0 zero vector')));
    for (var id = 10; id <= 74; id++) {
      await database
          .execute('INSERT INTO items(rowid, embedding) VALUES (?, ?)', [
        id,
        encodeVec(id == 74 ? const [1, 0] : const [0, 1])
      ]);
    }
    final paged = await rankVec0(database, table: 'items', query: const [1, 0]);
    expect(paged, hasLength(69));
    expect(paged.first.rowId, BigInt.one);
    expect(paged[1].rowId, BigInt.from(74));
    expect(paged.first.distance, 0);
    final image = database.exportImage();
    final reopened = await MutableSqliteDatabase.fromImage(image);
    addTearDown(reopened.close);
    final again = await rankVec0(reopened,
        table: 'items', query: const [0, 1], rowIds: [BigInt.two]);
    expect(again.single.distance, 0);
    expect(() => rankVec0(database, table: 'items vec', query: const [1, 0]),
        throwsArgumentError);
  });

  test('ORM nearest saves a float32 vector and returns one neighbor', () async {
    final database = await MutableSqliteDatabase.create();
    addTearDown(database.close);
    SqlitePlusVec.register(database);
    final connection = MutableDatabaseConnection(database);
    final context = DbContext(connection, DbModel([_mapping.type]));
    await context.migrations.ensureCreated();
    final notes = context.set(_mapping.type);
    notes.add(_Point(embedding: const [1, 0, 0, 0]));
    notes.add(_Point(embedding: const [0, 1, 0, 0]));
    expect(await context.saveChanges(), 2);
    final nearest =
        await notes.query.nearest(const [0.8, 0.2, 0, 0], k: 1).toList();
    expect(nearest, hasLength(1));
    expect(nearest.single.embedding[0] > 0.5, isTrue);
    expect(() => notes.query.nearest(const [1, 0], k: 1).toList(),
        throwsA(isA<OrmCodecException>()));
    expect(
        () => notes.query.nearest(const [1, 0, 0, 0], k: 0), throwsRangeError);
    final sql = await database
        .query("SELECT sql FROM sqlite_schema WHERE name = 'points'");
    expect(sql.rows.single.single,
        contains('float[4] distance_metric=${DbVectorMetrics.l2}'));
    expect((await context.migrations.plan()).isEmpty, isTrue);
  });
}

final class _Point {
  _Point({this.rowid, required this.embedding});
  BigInt? rowid;
  List<double> embedding;
}

final _mapping = _PointMapping();

final class _PointMapping {
  _PointMapping() {
    rowid = Column<_Point, BigInt?>(
        property: 'rowid',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (point) => point.rowid,
        write: (point, value) => point.rowid = value,
        keyOrder: 0,
        generated: true);
    embedding = Column<_Point, List<double>>(
        property: 'embedding',
        codec: Codecs.vector(4),
        read: (point) => point.embedding,
        write: (point, value) => point.embedding = value,
        vectorDimensions: 4,
        vectorMetric: DbVectorMetrics.l2);
    type = EntityType<_Point>(
        tableName: 'points',
        columns: [rowid, embedding],
        virtualModule: DbModules.vec0,
        create: (row) =>
            _Point(rowid: row.read(rowid), embedding: row.read(embedding)));
  }

  late final Column<_Point, BigInt?> rowid;
  late final Column<_Point, List<double>> embedding;
  late final EntityType<_Point> type;
}
