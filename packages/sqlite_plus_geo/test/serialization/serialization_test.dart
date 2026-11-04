import 'dart:typed_data';

import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

void main() {
  final point = GeoPoint(longitude: 34.30, latitude: 31.35, srid: 4326);

  test('WKT and EWKB round-trip a point', () {
    expect(point.toWkt(), 'POINT (34.3 31.35)');
    expect(point.toEwkt(), 'SRID=4326;POINT (34.3 31.35)');
    expect(GeoGeometry.fromWkt('POINT (34.30 31.35)', srid: 4326), point);
    expect(GeoGeometry.fromWkb(point.toEwkb()), point);
    expect(GeoGeometry.fromWkb(point.toWkb(endian: Endian.big), srid: 4326),
        point);
  });

  test('an empty point is a header and cannot sit inside a collection', () {
    final empty = GeoPoint.empty(srid: 4326);
    expect(empty.toWkt(), 'POINT EMPTY');
    expect(empty.toWkb(), hasLength(5));
    expect(empty.toEwkb(), hasLength(9));
    expect(GeoGeometry.fromWkb(empty.toEwkb()), empty);
    expect(
      () => GeoGeometryCollection([empty], srid: 4326).toWkb(),
      throwsA(isA<GeoException>()),
    );
  });

  test('malformed text, NaN, and a foreign GeoJSON crs are rejected', () {
    expect(() => GeoGeometry.fromWkt('POINT ('),
        throwsA(isA<GeoParseException>()));
    expect(
      () => GeoGeometry.fromWkt('POINT (1 nan)'),
      throwsA(isA<GeoException>()),
    );
    expect(
      () => GeoGeometry.fromGeoJson({
        'type': 'Point',
        'coordinates': [34.3, 31.35],
        'crs': {
          'type': 'name',
          'properties': {'name': 'EPSG:4326'},
        },
      }),
      throwsA(isA<GeoParseException>()),
    );
  });

  test('CRS84 is accepted without reordering longitude and latitude', () {
    final geometry = GeoGeometry.fromGeoJson(
      {
        'type': 'Point',
        'coordinates': [34.3, 31.35],
        'crs': {
          'type': 'name',
          'properties': {'name': 'CRS84'},
        },
      },
      options: const GeoParseOptions(allowLegacyCrs: true),
    ) as GeoPoint;
    expect(geometry.position!.x, 34.3);
    expect(geometry.position!.y, 31.35);
    expect(geometry.toGeoJson().containsKey('crs'), isFalse);
    expect(
      () => GeoPoint.empty().toGeoJson(),
      throwsA(isA<GeoException>()),
    );
  });

  test('a polygon with a hole survives WKB and GeoJSON', () {
    final polygon = GeoPolygon(
      exteriorRing: [
        GeoCoordinate(0, 0),
        GeoCoordinate(4, 0),
        GeoCoordinate(4, 4),
        GeoCoordinate(0, 4),
        GeoCoordinate(0, 0),
      ],
      holes: [
        [
          GeoCoordinate(1, 1),
          GeoCoordinate(2, 1),
          GeoCoordinate(2, 2),
          GeoCoordinate(1, 2),
          GeoCoordinate(1, 1),
        ],
      ],
      srid: 4326,
    );
    expect(GeoGeometry.fromWkb(polygon.toEwkb()), polygon);
    final json = polygon.toGeoJson();
    expect(json['type'], 'Polygon');
    expect(GeoGeometry.fromGeoJson(json), polygon);
  });

  test('a coordinate cap stops a huge line', () {
    expect(
      () => GeoGeometry.fromWkt(
        'LINESTRING (${List.filled(5, '0 0').join(', ')})',
        options: const GeoParseOptions(limits: GeoLimits(maxCoordinates: 4)),
      ),
      throwsA(isA<GeoParseException>()),
    );
  });
}
