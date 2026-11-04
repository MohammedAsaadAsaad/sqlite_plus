import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase database;

  setUp(() async {
    database = await MutableSqliteDatabase.create();
    SqlitePlusGeo.register(database);
  });

  test('parameterized constructors and predicates agree with the Dart API',
      () async {
    final polygon = GeoPolygon(
      exteriorRing: [
        GeoCoordinate(34.30, 31.35),
        GeoCoordinate(34.32, 31.35),
        GeoCoordinate(34.32, 31.37),
        GeoCoordinate(34.30, 31.37),
        GeoCoordinate(34.30, 31.35),
      ],
      srid: 4326,
    );
    final inside = await database.query(
      'SELECT ST_Intersects(ST_GeomFromText(?, ?), ?)',
      ['POINT (34.31 31.36)', BigInt.from(4326), polygon.toEwkb()],
    );
    expect(inside.rows.single.single, BigInt.one);
    final text = await database.query(
      'SELECT ST_AsText(ST_GeomFromText(?, 4326))',
      ['POINT (34.30 31.35)'],
    );
    expect(text.rows.single.single, 'POINT (34.3 31.35)');
    final tagged = await database.query(
      'SELECT ST_X(ST_SetSRID(ST_GeomFromText(?), 3857)), ST_SRID(ST_SetSRID(ST_GeomFromText(?), 3857))',
      ['POINT (1 0)', 'POINT (1 0)'],
    );
    expect(tagged.rows.single[0], 1);
    expect(tagged.rows.single[1], BigInt.from(3857));
    final moved = await database.query(
      'SELECT ST_X(ST_Transform(ST_GeomFromText(?, 4326), 3857))',
      ['POINT (1 0)'],
    );
    expect(moved.rows.single.single, closeTo(111319.49079327357, 1e-4));
  });

  test('geographic DWithin is metres and planar DWithin is CRS units',
      () async {
    final near = await database.query(
      'SELECT ST_DWithin(ST_GeomFromText(?, 4326), ST_GeomFromText(?, 4326), ?, 1)',
      ['POINT (34.30 31.35)', 'POINT (34.31 31.35)', 5000],
    );
    expect(near.rows.single.single, BigInt.one);
    final far = await database.query(
      'SELECT ST_DWithin(ST_GeomFromText(?, 4326), ST_GeomFromText(?, 4326), ?, 1)',
      ['POINT (34.30 31.35)', 'POINT (34.40 31.35)', 5000],
    );
    expect(far.rows.single.single, BigInt.zero);
    final planar = await database.query(
      'SELECT ST_DWithin(ST_GeomFromText(?), ST_GeomFromText(?), 0.02)',
      ['POINT (34.30 31.35)', 'POINT (34.31 31.35)'],
    );
    expect(planar.rows.single.single, BigInt.one);
    expect(
      () => database.query(
        'SELECT ST_DWithin(ST_GeomFromText(?), ST_GeomFromText(?), 1, 1)',
        ['LINESTRING (0 0, 1 1)', 'LINESTRING (0 1, 1 0)'],
      ),
      throwsA(isA<SqlException>()),
    );
  });

  test('nulls, aggregates, and an SRID mismatch', () async {
    final empty = await database.query(
      'SELECT ST_IsEmpty(NULL), ST_Collect(NULL)',
    );
    expect(empty.rows.single[0], isNull);
    expect(empty.rows.single[1], isNull);
    await database.execute('CREATE TABLE marks (geometry BLOB)');
    await database.execute(
      'INSERT INTO marks(geometry) VALUES (?), (?), (NULL)',
      [
        GeoPoint.xy(0, 0).toEwkb(),
        GeoPoint.xy(2, 3).toEwkb(),
      ],
    );
    final extent = await database
        .query('SELECT ST_AsText(ST_Extent(geometry)) FROM marks');
    expect(extent.rows.single.single,
        'POLYGON ((0.0 0.0, 2.0 0.0, 2.0 3.0, 0.0 3.0, 0.0 0.0))');
    final collected = await database
        .query('SELECT ST_NumGeometries(ST_Collect(geometry)) FROM marks');
    expect(collected.rows.single.single, BigInt.two);
    expect(
      () => database.query(
        "SELECT ST_DistanceSphere(ST_GeomFromText('POINT (0 0)', 3857), ST_GeomFromText('POINT (1 1)', 3857))",
      ),
      throwsA(isA<SqlException>()),
    );
  });

  test('azimuth is radians and a point buffer is a polygon', () async {
    final azimuth = await database.query(
      "SELECT ST_Azimuth(ST_GeomFromText('POINT (0 0)', 4326), ST_GeomFromText('POINT (1 0)', 4326))",
    );
    expect(azimuth.rows.single.single, closeTo(1.5707963267948966, 1e-8));
    final kind = await database.query(
      "SELECT ST_GeometryType(ST_Buffer(ST_GeomFromText('POINT (0 0)'), 1))",
    );
    expect(kind.rows.single.single, 'POLYGON');
  });
}
