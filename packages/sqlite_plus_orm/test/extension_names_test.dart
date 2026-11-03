import 'dart:typed_data';

import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

void main() {
  test('module, tokenizer, and metric constants keep their SQL spelling', () {
    expect(DbModules.fts5, 'fts5');
    expect(DbModules.rtree, 'rtree');
    expect(DbModules.vec0, 'vec0');
    expect(DbTokenizers.unicode61, 'unicode61');
    expect(DbTokenizers.porter, 'porter');
    expect(DbTokenizers.trigram, 'trigram');
    expect(DbTokenizers.ascii, 'ascii');
    expect(DbTokenizers.simple, 'simple');
    expect(DbVectorMetrics.l2, 'l2');
    expect(DbVectorMetrics.cosine, 'cosine');
    expect(DbVectorLimits.minimumDimensions, 1);
    expect(DbVectorLimits.maximumDimensions, 4096);
    expect(DbVectorLimits.maximumNeighbors, 4096);
    const entity =
        DbEntity(module: DbModules.fts5, tokenizer: DbTokenizers.porter);
    expect(entity.module, 'fts5');
    expect(entity.tokenizer, 'porter');
    const vector = DbVector(4, metric: DbVectorMetrics.cosine);
    expect(vector.dimensions, 4);
    expect(vector.metric, 'cosine');
    const custom = DbVector(8, metric: 'mine');
    expect(custom.metric, 'mine');
  });

  test('vector codec round-trips float32 and rejects bad values', () {
    final codec = Codecs.vector(3);
    final bytes = codec.encode(const [0.5, -2, 0.25]);
    expect(bytes, isA<Uint8List>());
    final blob = bytes as Uint8List;
    expect(codec.decode(blob), const [0.5, -2, 0.25]);
    expect(ByteData.sublistView(blob).getFloat32(0, Endian.little), 0.5);
    expect(() => codec.encode(const [1, 2]), throwsA(isA<OrmCodecException>()));
    expect(() => codec.encode(const [1, double.nan, 0]),
        throwsA(isA<OrmCodecException>()));
    expect(() => codec.decode(Uint8List(4)), throwsA(isA<OrmCodecException>()));
    expect(() => codec.decode('text'), throwsA(isA<OrmCodecException>()));
    expect(() => Codecs.vector(0), throwsA(isA<OrmMappingException>()));
    expect(() => Codecs.vector(4097), throwsA(isA<OrmMappingException>()));
  });

  test('nearest binds the blob and k, and a tokenizer stays on fts5', () {
    final mapping = _VectorMapping();
    final command =
        TypedQuery<_Point>(type: mapping.type, connection: _Unused())
            .nearest(const [1, 0], k: 2).toSql();
    expect(command.sql, contains('"embedding" MATCH ?'));
    expect(command.sql, contains('"k" = ?'));
    expect(command.sql, contains('ORDER BY distance'));
    expect(command.parameters[0], isA<Uint8List>());
    expect(command.parameters[1], BigInt.two);
    expect(command.sql.contains('1.0'), isFalse);
    expect(
        () => TypedQuery<_Point>(type: mapping.type, connection: _Unused())
            .nearest(const [1], k: 1),
        throwsA(isA<OrmCodecException>()));
    expect(
        () => TypedQuery<_Point>(type: mapping.type, connection: _Unused())
            .nearest(const [1, 0], k: 0),
        throwsRangeError);
    expect(
        () => TypedQuery<_Point>(type: mapping.type, connection: _Unused())
            .nearest(const [1, 0], k: 4097),
        throwsRangeError);
    expect(
        () => EntityType<_Point>(
            tableName: 'places',
            columns: [mapping.rowid, mapping.embedding],
            virtualModule: DbModules.rtree,
            tokenizer: 'arabic',
            create: mapping.type.create),
        throwsA(isA<OrmMappingException>()));
    expect(
        () => EntityType<_Point>(
            tableName: 'places',
            columns: [mapping.rowid, mapping.embedding],
            virtualModule: 'vec9',
            create: mapping.type.create),
        throwsA(isA<OrmMappingException>()));
  });
}

final class _Point {
  _Point({this.rowid, required this.embedding});
  final BigInt? rowid;
  final List<double> embedding;
}

final class _VectorMapping {
  _VectorMapping() {
    rowid = Column<_Point, BigInt?>(
        property: 'rowid',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (point) => point.rowid,
        keyOrder: 0,
        generated: true);
    embedding = Column<_Point, List<double>>(
        property: 'embedding',
        codec: Codecs.vector(2),
        read: (point) => point.embedding,
        vectorDimensions: 2);
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

final class _Unused implements OrmConnection {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
