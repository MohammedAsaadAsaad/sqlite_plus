import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

void main() {
  final origin = GeoPoint(longitude: 0, latitude: 0, srid: 4326);

  test('one equatorial degree is the WGS84 semi-major arc', () {
    final east = GeoPoint(longitude: 1, latitude: 0, srid: 4326);
    const expected = 6378137.0 * 3.141592653589793 / 180;
    expect(GeoGeodesy.distance(origin, east), closeTo(expected, 0.01));
    expect(
      GeoGeodesy.distance(origin, east, model: GeodesicModel.sphere),
      closeTo(GeoGeodesy.sphereRadius * 3.141592653589793 / 180, 1e-6),
    );
  });

  test('the quarter meridian is near 10001965.729 metres', () {
    final pole = GeoPoint(longitude: 0, latitude: 90, srid: 4326);
    expect(GeoGeodesy.distance(origin, pole), closeTo(10001965.729, 0.01));
  });

  test('zero, short, and near-antipodal distances stay honest', () {
    expect(GeoGeodesy.distance(origin, origin), 0);
    final near = GeoPoint(longitude: 0, latitude: 1e-6, srid: 4326);
    expect(GeoGeodesy.distance(origin, near), greaterThan(0));
    expect(GeoGeodesy.distance(origin, near), lessThan(1));
    final other = GeoPoint(longitude: 179.7, latitude: 0.5, srid: 4326);
    try {
      expect(GeoGeodesy.distance(origin, other), greaterThan(19000000));
    } on GeoException catch (error) {
      expect(error.message, contains('converge'));
    }
  });

  test(
      'azimuth is degrees from north and a polygon hole is not an extra segment',
      () {
    final east = GeoPoint(longitude: 1, latitude: 0, srid: 4326);
    expect(GeoGeodesy.azimuth(origin, east), closeTo(90, 1e-6));
    final there = GeoGeodesy.destination(
      origin,
      bearingDegrees: 90,
      distanceMeters: 111319.49079327357,
    );
    expect(there.position!.x, closeTo(1, 1e-6));
    expect(there.position!.y, closeTo(0, 1e-6));
    final polygon = GeoPolygon(
      exteriorRing: [
        GeoCoordinate(0, 0),
        GeoCoordinate(0.01, 0),
        GeoCoordinate(0.01, 0.01),
        GeoCoordinate(0, 0.01),
        GeoCoordinate(0, 0),
      ],
      holes: [
        [
          GeoCoordinate(0.004, 0.004),
          GeoCoordinate(0.006, 0.004),
          GeoCoordinate(0.006, 0.006),
          GeoCoordinate(0.004, 0.006),
          GeoCoordinate(0.004, 0.004),
        ],
      ],
      srid: 4326,
    );
    final shell = GeoGeodesy.length(
      GeoLineString(polygon.exterior!.points, srid: 4326),
    );
    final hole = GeoGeodesy.length(
      GeoLineString(polygon.holes.single.points, srid: 4326),
    );
    expect(GeoGeodesy.length(polygon), closeTo(shell + hole, 1e-6));
    expect(
      () => GeoGeodesy.distance(
        origin,
        east,
        unit: DistanceUnit.meters,
        model: GeodesicModel.planar,
      ),
      throwsA(isA<GeoException>()),
    );
  });

  test('spherical area of a small geographic square is not the shoelace', () {
    final square = GeoPolygon(
      exteriorRing: [
        GeoCoordinate(0, 0),
        GeoCoordinate(0.01, 0),
        GeoCoordinate(0.01, 0.01),
        GeoCoordinate(0, 0.01),
        GeoCoordinate(0, 0),
      ],
      srid: 4326,
    );
    expect(geoArea(square), closeTo(0.0001, 1e-12));
    expect(geoSphericalArea(square), greaterThan(1000000));
  });
}
