import 'dart:math';
import 'dart:typed_data';

import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';
import 'package:test/test.dart';

GeoPolygon? _convex(Random random) {
  final cloud = GeoMultiPoint([
    for (var i = 0; i < 8; i++)
      GeoPoint.xy(random.nextDouble() * 20, random.nextDouble() * 20),
  ]);
  final hull = geoConvexHull(cloud);
  if (hull is! GeoPolygon || !hull.isValid) return null;
  return hull;
}

void main() {
  test('random convex polygons keep the overlay and round-trip invariants', () {
    final random = Random(20261104);
    for (var i = 0; i < 12; i++) {
      final left = _convex(random);
      final right = _convex(random);
      if (left == null || right == null) continue;
      expect(
          left.envelope!.containsCoordinate(
              left.coordinates.first.x, left.coordinates.first.y),
          isTrue);
      expect(GeoGeometry.fromWkb(left.toWkb()), left);
      expect(GeoGeometry.fromWkb(left.toEwkb(endian: Endian.big)), left);
      final union = geoUnion(left, right);
      final intersection = geoIntersection(left, right);
      final reverse = geoUnion(right, left);
      expect(geoArea(union), closeTo(geoArea(reverse), 1e-6));
      expect(
        geoArea(union),
        closeTo(geoArea(left) + geoArea(right) - geoArea(intersection), 1e-3),
      );
      expect(geoDifference(left, left).isEmpty, isTrue);
      final geographic = GeoPoint(
        longitude: random.nextDouble() * 100 - 20,
        latitude: random.nextDouble() * 60 - 20,
        srid: 4326,
      );
      final round = geoTransform(
        geoTransform(geographic, targetSrid: 3857),
        targetSrid: 4326,
      ) as GeoPoint;
      expect(round.position!.x, closeTo(geographic.position!.x, 1e-8));
      expect(round.position!.y, closeTo(geographic.position!.y, 1e-8));
    }
  });
}
