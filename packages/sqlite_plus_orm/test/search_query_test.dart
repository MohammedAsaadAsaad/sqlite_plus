import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class _Doc {
  _Doc(this.body);
  final String body;
}

final class _DocMapping {
  _DocMapping() {
    body = Column(
        property: 'body',
        name: 'body',
        codec: Codecs.text,
        read: (doc) => doc.body,
        keyOrder: 0);
    type = EntityType(
        tableName: 'docs',
        columns: [body],
        create: (row) => _Doc(row.read(body)));
  }

  late final Column<_Doc, String> body;
  late final EntityType<_Doc> type;
}

final class _Place {
  _Place(this.id);
  final BigInt id;
}

final class _PlaceMapping {
  _PlaceMapping() {
    id = Column(
        property: 'id',
        name: 'id',
        codec: Codecs.bigInt,
        read: (place) => place.id,
        keyOrder: 0);
    minX = Column(
        property: 'minX', name: 'minX', codec: Codecs.real, read: (place) => 0);
    maxX = Column(
        property: 'maxX', name: 'maxX', codec: Codecs.real, read: (place) => 0);
    minY = Column(
        property: 'minY', name: 'minY', codec: Codecs.real, read: (place) => 0);
    maxY = Column(
        property: 'maxY', name: 'maxY', codec: Codecs.real, read: (place) => 0);
    type = EntityType(
        tableName: 'places',
        columns: [id, minX, maxX, minY, maxY],
        create: (row) => _Place(row.read(id)));
  }

  late final Column<_Place, BigInt> id;
  late final Column<_Place, double> minX;
  late final Column<_Place, double> maxX;
  late final Column<_Place, double> minY;
  late final Column<_Place, double> maxY;
  late final EntityType<_Place> type;
}

void main() {
  test('search binds the text and orders by rank', () async {
    final mapping = _DocMapping();
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final connection = MutableDatabaseConnection(db);
    await db.execute(
        'CREATE VIRTUAL TABLE ${quoteIdentifier(mapping.type.tableName)} '
        'USING fts5(${quoteIdentifier(mapping.body.sqlName)})');
    await db.execute(
        'INSERT INTO ${quoteIdentifier(mapping.type.tableName)}'
        '(${quoteIdentifier(mapping.body.sqlName)}) VALUES(?), (?)',
        ['alpha beta', 'alpha']);
    final found =
        await MappedTable(mapping.type, connection).search('alpha').toList();
    expect(found.map((doc) => doc.body), ['alpha', 'alpha beta']);
  });

  test('search SQL binds the text', () {
    final mapping = _DocMapping();
    final command =
        TypedQuery(type: mapping.type, connection: _UnusedConnection())
            .search('alpha beta')
            .toSql();
    expect(command.sql, contains('MATCH ?'));
    expect(command.sql, contains('ORDER BY rank'));
    expect(command.parameters, ['alpha beta']);
    expect(command.sql.contains('alpha beta'), isFalse);
  });

  test('intersects binds the rectangle', () async {
    final mapping = _PlaceMapping();
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final connection = MutableDatabaseConnection(db);
    await db.execute(
        'CREATE VIRTUAL TABLE ${quoteIdentifier(mapping.type.tableName)} '
        'USING rtree(${quoteIdentifier(mapping.id.sqlName)}, '
        '${quoteIdentifier(mapping.minX.sqlName)}, '
        '${quoteIdentifier(mapping.maxX.sqlName)}, '
        '${quoteIdentifier(mapping.minY.sqlName)}, '
        '${quoteIdentifier(mapping.maxY.sqlName)})');
    await db.execute(
        'INSERT INTO ${quoteIdentifier(mapping.type.tableName)} VALUES(1, 0, 1, 0, 1)');
    await db.execute(
        'INSERT INTO ${quoteIdentifier(mapping.type.tableName)} VALUES(2, 5, 6, 5, 6)');
    final bounds = Bounds(
        minX: mapping.minX,
        maxX: mapping.maxX,
        minY: mapping.minY,
        maxY: mapping.maxY);
    final hits = await TypedQuery(type: mapping.type, connection: connection)
        .where(
            bounds.intersects(const Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
        .toList();
    expect(hits.map((place) => place.id), [BigInt.one]);
  });
}

final class _UnusedConnection extends OrmConnection {
  @override
  bool get inTransaction => false;
  @override
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      throw UnimplementedError();
  @override
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {}
}
