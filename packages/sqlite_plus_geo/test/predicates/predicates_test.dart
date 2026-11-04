import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

GeoPolygon _square(double x, double y, double size) => GeoPolygon(
      exteriorRing: [
        GeoCoordinate(x, y),
        GeoCoordinate(x + size, y),
        GeoCoordinate(x + size, y + size),
        GeoCoordinate(x, y + size),
        GeoCoordinate(x, y),
      ],
    );

void main() {
  final park = _square(0, 0, 4);

  test('interior, boundary, and exterior points follow DE-9IM', () {
    final inside = GeoPoint.xy(1, 1);
    final edge = GeoPoint.xy(0, 2);
    final outside = GeoPoint.xy(9, 9);
    expect(geoLocate(park, inside.position!), GeoLocation.interior);
    expect(geoContains(park, inside), isTrue);
    expect(geoWithin(inside, park), isTrue);
    expect(geoContains(inside, park), isFalse);
    expect(geoTouches(park, inside), isFalse);
    expect(geoLocate(park, edge.position!), GeoLocation.boundary);
    expect(geoContains(park, edge), isFalse);
    expect(geoCovers(park, edge), isTrue);
    expect(geoCoveredBy(edge, park), isTrue);
    expect(geoTouches(park, edge), isTrue);
    expect(geoIntersects(park, edge), isTrue);
    expect(geoDisjoint(park, outside), isTrue);
    expect(geoIntersects(park, outside), isFalse);
    expect(geoRelate(park, inside), hasLength(9));
    expect(geoRelateMatches(geoRelate(park, inside), 'T********'), isTrue);
  });

  test('a hole is outside the polygon and predicates are symmetric', () {
    final holed = GeoPolygon(
      exteriorRing: park.exterior!.points,
      holes: [
        [
          GeoCoordinate(1, 1),
          GeoCoordinate(2, 1),
          GeoCoordinate(2, 2),
          GeoCoordinate(1, 2),
          GeoCoordinate(1, 1),
        ],
      ],
    );
    expect(geoLocate(holed, GeoCoordinate(1.5, 1.5)), GeoLocation.exterior);
    expect(geoLocate(holed, GeoCoordinate(3, 3)), GeoLocation.interior);
    final other = _square(3, 3, 4);
    expect(geoIntersects(park, other), geoIntersects(other, park));
    expect(geoWithin(park, other), geoContains(other, park));
    expect(geoDisjoint(park, other), !geoIntersects(park, other));
    expect(geoOverlaps(park, other), isTrue);
  });

  test('empty geometries do not intersect, including empty with empty', () {
    final empty = GeoPolygon.empty();
    expect(geoIntersects(empty, empty), isFalse);
    expect(geoIntersects(park, empty), isFalse);
    expect(geoDWithin(GeoPoint.xy(0, 0), GeoPoint.xy(3, 4), 5), isTrue);
    expect(geoDWithin(GeoPoint.xy(0, 0), GeoPoint.xy(3, 4), 4.9), isFalse);
  });

  test('crossing lines and a shared polygon edge', () {
    final left = GeoLineString([GeoCoordinate(0, 0), GeoCoordinate(2, 2)]);
    final right = GeoLineString([GeoCoordinate(0, 2), GeoCoordinate(2, 0)]);
    expect(geoCrosses(left, right), isTrue);
    expect(geoTouches(_square(0, 0, 1), _square(1, 0, 1)), isTrue);
    expect(geoOverlaps(_square(0, 0, 1), _square(1, 0, 1)), isFalse);
  });
}
