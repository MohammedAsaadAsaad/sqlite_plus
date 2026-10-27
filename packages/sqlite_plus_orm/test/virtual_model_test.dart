import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class _Article {
  _Article(this.rowid, this.body);
  final BigInt? rowid;
  final String body;
}

final class _Place {
  _Place(this.id, this.minX, this.maxX, this.minY, this.maxY);
  final BigInt id;
  final double minX, maxX, minY, maxY;
}

void main() {
  test('fts5 and rtree mappings save, search, and read', () async {
    final articleRowid = Column<_Article, BigInt?>(
        property: 'rowid',
        name: 'rowid',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (article) => article.rowid,
        keyOrder: 0,
        generated: true);
    final articleBody = Column<_Article, String>(
        property: 'body',
        name: 'body',
        codec: Codecs.text,
        read: (article) => article.body);
    final articleType = EntityType<_Article>(
        tableName: 'Article',
        virtualModule: 'fts5',
        columns: [articleRowid, articleBody],
        create: (row) =>
            _Article(row.read(articleRowid), row.read(articleBody)),
        applyStoreValues: (article, row) =>
            _Article(row.read(articleRowid), row.read(articleBody)));
    final placeId = Column<_Place, BigInt>(
        property: 'id',
        name: 'id',
        codec: Codecs.bigInt,
        read: (place) => place.id,
        keyOrder: 0);
    Column<_Place, double> real(String name, double Function(_Place) read) =>
        Column(property: name, name: name, codec: Codecs.real, read: read);
    final minX = real('minX', (place) => place.minX);
    final maxX = real('maxX', (place) => place.maxX);
    final minY = real('minY', (place) => place.minY);
    final maxY = real('maxY', (place) => place.maxY);
    final placeType = EntityType<_Place>(
        tableName: 'Place',
        virtualModule: 'rtree',
        columns: [placeId, minX, maxX, minY, maxY],
        create: (row) => _Place(row.read(placeId), row.read(minX),
            row.read(maxX), row.read(minY), row.read(maxY)),
        applyStoreValues: (place, row) => _Place(row.read(placeId),
            row.read(minX), row.read(maxX), row.read(minY), row.read(maxY)));
    final connection = await MutableDatabaseConnection.openMemory();
    final context = DbContext(connection, DbModel([articleType, placeType]));
    await context.migrations.ensureCreated();
    expect((await context.migrations.plan()).isEmpty, isTrue);
    final articles = context.set(articleType);
    final places = context.set(placeType);
    articles.add(_Article(null, 'alpha kept'));
    places.add(_Place(BigInt.one, 0, 1, 0, 1));
    places.add(_Place(BigInt.two, 5, 6, 5, 6));
    expect(await context.saveChanges(), 3);
    final found = await articles.query.search('kept').toList();
    final box = Bounds(minX: minX, maxX: maxX, minY: minY, maxY: maxY);
    final hits = await places.query
        .where(box.intersects(const Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
        .toList();
    expect(found.single.body, 'alpha kept');
    expect(found.single.rowid, isNotNull);
    expect(hits.single.id, BigInt.one);
    expect(hits.single.minX, 0);
    expect(hits.single.maxX, 1);
    expect((await context.migrations.plan()).isEmpty, isTrue);
    await context.close();
  });

  test('an unknown module and a virtual foreign key are rejected', () {
    final id = Column<Object, BigInt>(
        property: 'id',
        codec: Codecs.bigInt,
        read: (_) => BigInt.one,
        keyOrder: 0);
    expect(
        () => EntityType(
            tableName: 'Bad',
            virtualModule: 'fts4',
            columns: [id],
            create: (_) => Object()),
        throwsA(isA<OrmMappingException>()));
    final parent = EntityType<Object>(
        tableName: 'Parent', columns: [id], create: (_) => Object());
    final rowid = Column<Object, BigInt?>(
        property: 'rowid',
        name: 'rowid',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (_) => null,
        keyOrder: 0,
        generated: true);
    final body = Column<Object, String>(
        property: 'body', codec: Codecs.text, read: (_) => '');
    final child = EntityType<Object>(
        tableName: 'Child',
        virtualModule: 'fts5',
        columns: [rowid, body],
        create: (_) => Object());
    expect(
        () => DbModel([
              parent,
              child
            ], foreignKeys: [
              ForeignKey(
                  name: 'link',
                  child: child,
                  parent: parent,
                  columns: [rowid],
                  targetColumns: [id])
            ]),
        throwsA(isA<OrmMappingException>()));
  });
}
