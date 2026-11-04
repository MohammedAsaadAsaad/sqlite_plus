part of '../geo_engine.dart';

/// Where [point] sits on [geometry]. SRIDs must match or either SRID is 0.
GeoLocation geoLocate(GeoGeometry geometry, GeoCoordinate point) =>
    geoLocateXY(geometry, point.x, point.y);

/// Where ([x], [y]) sits on [geometry].
GeoLocation geoLocateXY(GeoGeometry geometry, double x, double y) {
  if (!x.isFinite || !y.isFinite) {
    throw const GeoException('coordinate is not finite');
  }
  return switch (geometry) {
    GeoPoint point => _locatePoint(point, x, y),
    GeoLineString line => _locateLine(line, x, y),
    GeoPolygon polygon => _locatePolygon(polygon, x, y),
    GeoMultiPoint multi => _locateCombined(multi.points, x, y),
    GeoMultiLineString multi => _locateCombined(multi.lines, x, y),
    GeoMultiPolygon multi => _locateCombined(multi.polygons, x, y),
    GeoGeometryCollection collection =>
      _locateCombined(collection.geometries, x, y),
  };
}

GeoLocation _locateCombined(List<GeoGeometry> parts, double x, double y) {
  var boundary = false;
  for (final part in parts) {
    final location = geoLocateXY(part, x, y);
    if (location == GeoLocation.interior) return GeoLocation.interior;
    if (location == GeoLocation.boundary) boundary = true;
  }
  return boundary ? GeoLocation.boundary : GeoLocation.exterior;
}

GeoLocation _locatePoint(GeoPoint point, double x, double y) {
  if (point.position == null) return GeoLocation.exterior;
  if (point.position!.x == x && point.position!.y == y) {
    return GeoLocation.interior;
  }
  return GeoLocation.exterior;
}

GeoLocation _locateLine(GeoLineString line, double x, double y) {
  if (line.points.length < 2) return GeoLocation.exterior;
  var boundary = false;
  for (var i = 0; i < line.points.length - 1; i++) {
    final start = line.points[i];
    final end = line.points[i + 1];
    if (!geoPointOnSegment(start.x, start.y, end.x, end.y, x, y)) continue;
    final atStart = start.x == x && start.y == y;
    final atEnd = end.x == x && end.y == y;
    if (!atStart && !atEnd) return GeoLocation.interior;
    boundary = true;
    if (i > 0 && atStart) return GeoLocation.interior;
    if (i < line.points.length - 2 && atEnd) return GeoLocation.interior;
  }
  if (!boundary) return GeoLocation.exterior;
  return line.isClosed ? GeoLocation.interior : GeoLocation.boundary;
}

GeoLocation _locatePolygon(GeoPolygon polygon, double x, double y) {
  if (polygon.exterior == null) return GeoLocation.exterior;
  final shell = _ringLocation(x, y, polygon.exterior!.points);
  if (shell != GeoLocation.interior) return shell;
  for (final hole in polygon.holes) {
    final location = _ringLocation(x, y, hole.points);
    if (location == GeoLocation.boundary) return GeoLocation.boundary;
    if (location == GeoLocation.interior) return GeoLocation.exterior;
  }
  return GeoLocation.interior;
}

/// Even-odd location against one ring. The ring may be open; only drawn
/// segments are tested.
GeoLocation _ringLocation(double x, double y, List<GeoCoordinate> ring) {
  if (ring.length < 2) return GeoLocation.exterior;
  var inside = false;
  for (var i = 0; i < ring.length - 1; i++) {
    final start = ring[i];
    final end = ring[i + 1];
    if (geoPointOnSegment(start.x, start.y, end.x, end.y, x, y)) {
      return GeoLocation.boundary;
    }
    if (_rayCrosses(start, end, x, y)) inside = !inside;
  }
  return inside ? GeoLocation.interior : GeoLocation.exterior;
}

bool _rayCrosses(GeoCoordinate start, GeoCoordinate end, double x, double y) {
  if ((start.y > y) == (end.y > y)) return false;
  final expr = (_Dyadic.of(start.x) - _Dyadic.of(x)) *
          (_Dyadic.of(end.y) - _Dyadic.of(start.y)) +
      (_Dyadic.of(y) - _Dyadic.of(start.y)) *
          (_Dyadic.of(end.x) - _Dyadic.of(start.x));
  if (expr.mag == BigInt.zero) return false;
  final direction = (_Dyadic.of(end.y) - _Dyadic.of(start.y)).mag.sign;
  return expr.mag.sign * direction > 0;
}

void _requireSameSrid(GeoGeometry left, GeoGeometry right) {
  if (left.srid == 0 || right.srid == 0 || left.srid == right.srid) return;
  throw GeoException('SRID mismatch ${left.srid} and ${right.srid}');
}

/// A point strictly inside [ring], or null when none of the probes landed.
GeoCoordinate? _interiorProbe(List<GeoCoordinate> ring) {
  if (ring.length < 4) return null;
  final centroid = _ringCentroid(ring);
  if (centroid != null &&
      _ringLocation(centroid.x, centroid.y, ring) == GeoLocation.interior) {
    return centroid;
  }
  for (var i = 0; i < ring.length - 1; i++) {
    final start = ring[i];
    final end = ring[i + 1];
    final dx = end.x - start.x;
    final dy = end.y - start.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) continue;
    final leftX = -dy / length;
    final leftY = dx / length;
    final step = math.max(length * 1e-8, 1e-12);
    final midX = (start.x + end.x) / 2;
    final midY = (start.y + end.y) / 2;
    for (final sign in const [1.0, -1.0]) {
      final x = midX + leftX * step * sign;
      final y = midY + leftY * step * sign;
      if (_ringLocation(x, y, ring) == GeoLocation.interior) {
        return GeoCoordinate(x, y);
      }
    }
  }
  return null;
}

GeoCoordinate? _ringCentroid(List<GeoCoordinate> ring) {
  var twice = 0.0;
  var cx = 0.0;
  var cy = 0.0;
  for (var i = 0; i < ring.length - 1; i++) {
    final cross = ring[i].x * ring[i + 1].y - ring[i + 1].x * ring[i].y;
    twice += cross;
    cx += (ring[i].x + ring[i + 1].x) * cross;
    cy += (ring[i].y + ring[i + 1].y) * cross;
  }
  if (twice == 0) return null;
  return GeoCoordinate(cx / (3 * twice), cy / (3 * twice));
}
