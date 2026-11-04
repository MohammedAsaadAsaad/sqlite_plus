import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

void main() {
  test('point axes stay longitude then latitude', () {
    final point = GeoPoint(longitude: 34.30, latitude: 31.35, srid: 4326);
    expect(point.position!.x, 34.30);
    expect(point.position!.y, 31.35);
    expect(point.srid, 4326);
    expect(point.type, GeoGeometryType.point);
    expect(point.dimension, GeoDimension.xy);
    expect(point.isEmpty, isFalse);
    expect(point.envelope!.minX, 34.30);
    expect(point.toMapPosition().longitude, 34.30);
    expect(
      () => GeoPoint(x: 1, longitude: 2, y: 3),
      throwsA(isA<GeoException>()),
    );
  });

  test('empty points compare exactly and reject non-finite numbers', () {
    final empty = GeoPoint.empty(srid: 4326);
    expect(empty.isEmpty, isTrue);
    expect(empty.envelope, isNull);
    expect(empty.equalsExactly(GeoPoint.empty(srid: 4326)), isTrue);
    expect(geoEqualsTopologically(empty, GeoPoint.empty(srid: 4326)), isFalse);
    expect(() => GeoCoordinate(double.nan, 1), throwsA(isA<GeoException>()));
    expect(
        () => GeoCoordinate(1, double.infinity), throwsA(isA<GeoException>()));
    expect(GeoCoordinate(-0.0, -0.0).x, 0);
  });

  test('polygon normalization turns the shell counter-clockwise', () {
    final clockwise = GeoPolygon(
      exteriorRing: [
        GeoCoordinate(0, 0),
        GeoCoordinate(0, 1),
        GeoCoordinate(1, 1),
        GeoCoordinate(1, 0),
        GeoCoordinate(0, 0),
      ],
    );
    expect(clockwise.isValid, isTrue);
    final normal = clockwise.normalize() as GeoPolygon;
    final ring = normal.exterior!.points;
    expect(
      geoOrientation(
          ring[0].x, ring[0].y, ring[1].x, ring[1].y, ring[2].x, ring[2].y),
      greaterThan(0),
    );
    expect(geoArea(clockwise), 1);
  });

  test('a linear ring is not equal to a line with the same positions', () {
    final points = [
      GeoCoordinate(0, 0),
      GeoCoordinate(1, 0),
      GeoCoordinate(0, 0),
    ];
    expect(GeoLinearRing(points) == GeoLineString(points), isFalse);
  });

  test('XYZ and XYM stay distinct', () {
    final elevated = GeoPoint.xy(1, 2, z: 3, srid: 4326);
    expect(elevated.dimension, GeoDimension.xyz);
    expect(elevated.position!.z, 3);
    expect(
      () => GeoLineString([
        GeoCoordinate(0, 0, z: 1),
        GeoCoordinate(1, 1),
      ]),
      throwsA(isA<GeoException>()),
    );
    final measured = GeoPoint.xy(1, 2, m: 4);
    expect(measured.dimension, GeoDimension.xym);
    expect(measured.position!.m, 4);
  });
}
