import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

GeoPolygon _box(double minX, double minY, double maxX, double maxY) =>
    GeoPolygon(
      exteriorRing: [
        GeoCoordinate(minX, minY),
        GeoCoordinate(maxX, minY),
        GeoCoordinate(maxX, maxY),
        GeoCoordinate(minX, maxY),
        GeoCoordinate(minX, minY),
      ],
    );

void main() {
  test('area, length, centroid, and distance use planar units', () {
    final square = _box(0, 0, 2, 2);
    expect(geoArea(square), 4);
    expect(geoPerimeter(square), 8);
    expect(geoLength(square), 0);
    final centre = geoCentroid(square)!;
    expect(centre.position!.x, closeTo(1, 1e-9));
    expect(centre.position!.y, closeTo(1, 1e-9));
    expect(geoDistance(GeoPoint.xy(0, 0), GeoPoint.xy(3, 4)), 5);
    expect(
      geoPointOnSurface(square)!.position,
      isNotNull,
    );
    expect(geoLocate(square, geoPointOnSurface(square)!.position!),
        isNot(GeoLocation.exterior));
  });

  test('adjacent squares dissolve and overlapping squares keep the overlap',
      () {
    final left = _box(0, 0, 1, 1);
    final right = _box(1, 0, 2, 1);
    final union = geoUnion(left, right);
    expect(geoArea(union), closeTo(2, 1e-8));
    expect(union, isA<GeoPolygon>());
    final west = _box(0, 0, 2, 2);
    final east = _box(1, 0, 3, 2);
    expect(geoArea(geoIntersection(west, east)), closeTo(2, 1e-6));
    expect(geoArea(geoUnion(west, east)), closeTo(6, 1e-6));
    expect(geoArea(geoDifference(west, east)), closeTo(2, 1e-6));
    expect(geoDifference(west, west).isEmpty, isTrue);
    expect(geoArea(geoSymmetricDifference(west, east)), closeTo(4, 1e-6));
  });

  test('a bowtie repairs into two lobes whose area is about 2', () {
    final bowtie = GeoPolygon(
      exteriorRing: [
        GeoCoordinate(0, 0),
        GeoCoordinate(2, 2),
        GeoCoordinate(0, 2),
        GeoCoordinate(2, 0),
        GeoCoordinate(0, 0),
      ],
    );
    expect(bowtie.isValid, isFalse);
    final repaired = geoMakeValid(bowtie);
    expect(repaired.isValid, isTrue);
    expect(geoArea(repaired), closeTo(2, 1e-6));
    expect(repaired.type, GeoGeometryType.multiPolygon);
  });

  test('buffer and hull stay inside their documented approximation', () {
    final point = geoBuffer(
      GeoPoint.xy(0, 0),
      1,
      parameters: const GeoBufferParameters(quadrantSegments: 8),
    );
    expect(geoArea(point), closeTo(3.141592653589793, 0.05));
    final grown = geoBuffer(
      _box(0, 0, 1, 1),
      1,
      parameters:
          const GeoBufferParameters(join: GeoJoinStyle.mitre, mitreLimit: 5),
    );
    final envelope = grown.envelope!;
    expect(envelope.minX, closeTo(-1, 1e-8));
    expect(envelope.minY, closeTo(-1, 1e-8));
    expect(envelope.maxX, closeTo(2, 1e-8));
    expect(envelope.maxY, closeTo(2, 1e-8));
    final hull = geoConvexHull(
      GeoMultiPoint([
        GeoPoint.xy(0, 0),
        GeoPoint.xy(2, 0),
        GeoPoint.xy(1, 1),
        GeoPoint.xy(1, 0.2),
      ]),
    );
    expect(hull, isA<GeoPolygon>());
    expect(geoArea(hull), closeTo(1, 1e-9));
    expect(
      () => geoConcaveHull(
        GeoLineString([GeoCoordinate(0, 0), GeoCoordinate(1, 1)]),
        1,
      ),
      throwsA(isA<GeoException>()),
    );
  });

  test('simplify, snap, translate, and line merge', () {
    final line = GeoLineString([
      GeoCoordinate(0, 0),
      GeoCoordinate(1, 0.01),
      GeoCoordinate(2, 0),
    ]);
    final simple = geoSimplify(line, 0.1) as GeoLineString;
    expect(simple.points, hasLength(2));
    final snapped =
        geoSnap(GeoPoint.xy(0.04, 0), GeoPoint.xy(0, 0), 0.1) as GeoPoint;
    expect(snapped.position, GeoCoordinate(0, 0));
    final moved = geoTranslate(GeoPoint.xy(1, 2), 3, 4) as GeoPoint;
    expect(moved.position, GeoCoordinate(4, 6));
    final merged = geoLineMerge(
      GeoMultiLineString([
        GeoLineString([GeoCoordinate(0, 0), GeoCoordinate(1, 0)]),
        GeoLineString([GeoCoordinate(1, 0), GeoCoordinate(2, 0)]),
      ]),
    );
    expect(geoLength(merged), closeTo(2, 1e-9));
  });
}
