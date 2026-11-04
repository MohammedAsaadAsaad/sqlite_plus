part of '../geo_engine.dart';

/// Andrew's monotone chain. Degenerate inputs become a point or a line.
GeoGeometry geoConvexHull(GeoGeometry geometry) {
  final unique = <GeoCoordinate>[];
  for (final coordinate in geometry.coordinates) {
    if (unique
        .every((item) => item.x != coordinate.x || item.y != coordinate.y)) {
      unique.add(GeoCoordinate(coordinate.x, coordinate.y));
    }
  }
  if (unique.isEmpty) return GeoPolygon.empty(srid: geometry.srid);
  if (unique.length == 1) {
    return GeoPoint.xy(unique.single.x, unique.single.y, srid: geometry.srid);
  }
  unique.sort((left, right) {
    final byX = left.x.compareTo(right.x);
    return byX != 0 ? byX : left.y.compareTo(right.y);
  });
  if (unique.length == 2) {
    return GeoLineString(unique, srid: geometry.srid);
  }
  final lower = <GeoCoordinate>[];
  for (final point in unique) {
    while (lower.length >= 2 &&
        geoOrientation(
              lower[lower.length - 2].x,
              lower[lower.length - 2].y,
              lower[lower.length - 1].x,
              lower[lower.length - 1].y,
              point.x,
              point.y,
            ) <=
            0) {
      lower.removeLast();
    }
    lower.add(point);
  }
  final upper = <GeoCoordinate>[];
  for (final point in unique.reversed) {
    while (upper.length >= 2 &&
        geoOrientation(
              upper[upper.length - 2].x,
              upper[upper.length - 2].y,
              upper[upper.length - 1].x,
              upper[upper.length - 1].y,
              point.x,
              point.y,
            ) <=
            0) {
      upper.removeLast();
    }
    upper.add(point);
  }
  lower.removeLast();
  upper.removeLast();
  final ring = [...lower, ...upper];
  if (ring.length < 3) {
    return GeoLineString([...ring, ring.first], srid: geometry.srid);
  }
  return GeoPolygon(
    exteriorRing: [...ring, ring.first],
    srid: geometry.srid,
  ).normalize();
}

/// Concave hull of a point set. [ratio] is the longest retained edge as a
/// fraction of the convex hull's longest edge. `1` returns the convex hull.
/// Only point inputs are accepted.
GeoGeometry geoConcaveHull(GeoGeometry geometry, double ratio) {
  if (ratio <= 0 || ratio > 1) {
    throw const GeoException('concave hull ratio must be in (0, 1]');
  }
  final points = geometry.coordinates
      .map((coordinate) => GeoCoordinate(coordinate.x, coordinate.y))
      .toList();
  if (geometry is! GeoPoint &&
      geometry is! GeoMultiPoint &&
      points.length > 3 &&
      geometry is! GeoGeometryCollection) {
    final onlyPoints = points.isNotEmpty &&
        (geometry is GeoMultiPoint || geometry is GeoPoint);
    if (!onlyPoints && geometry is! GeoGeometryCollection) {
      throw const GeoException('concave hull is implemented for points');
    }
  }
  if (geometry is GeoLineString ||
      geometry is GeoPolygon ||
      geometry is GeoMultiLineString ||
      geometry is GeoMultiPolygon) {
    throw const GeoException('concave hull is implemented for points');
  }
  final hull = geoConvexHull(geometry);
  if (ratio == 1 || hull is! GeoPolygon || hull.exterior == null) return hull;
  final longest = _longestEdge(hull.exterior!.points);
  final limit = longest * ratio;
  final ring = hull.exterior!.points.toList();
  final frozen = <int>{};
  var guard = 0;
  while (guard++ < points.length) {
    var index = -1;
    var length = limit;
    for (var i = 0; i < ring.length - 1; i++) {
      if (frozen.contains(i)) continue;
      final span = _hypot(ring[i], ring[i + 1]);
      if (span > length) {
        length = span;
        index = i;
      }
    }
    if (index < 0) break;
    GeoCoordinate? best;
    var bestDistance = double.infinity;
    for (final candidate in points) {
      if (ring.any((item) => item.equalsExact(candidate))) continue;
      if (_ringLocation(candidate.x, candidate.y, ring) ==
          GeoLocation.exterior) {
        continue;
      }
      final distance =
          _pointSegmentDistance(candidate, ring[index], ring[index + 1]);
      if (distance < bestDistance) {
        best = candidate;
        bestDistance = distance;
      }
    }
    if (best == null) {
      frozen.add(index);
      continue;
    }
    final inserted = [
      ...ring.sublist(0, index + 1),
      best,
      ...ring.sublist(index + 1)
    ];
    if (_ringProblem(inserted) != null) {
      frozen.add(index);
      continue;
    }
    ring
      ..clear()
      ..addAll(inserted);
    frozen.clear();
  }
  return GeoPolygon(exteriorRing: ring, srid: geometry.srid).normalize();
}

double _longestEdge(List<GeoCoordinate> ring) {
  var best = 0.0;
  for (var i = 1; i < ring.length; i++) {
    best = math.max(best, _hypot(ring[i - 1], ring[i]));
  }
  return best;
}
