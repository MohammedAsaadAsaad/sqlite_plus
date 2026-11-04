part of '../geo_engine.dart';

/// Planar length in coordinate units. This is not metres on a geographic CRS.
double geoLength(GeoGeometry geometry) => switch (geometry) {
      GeoPoint _ => 0,
      GeoLineString line => _pathLength(line.points),
      GeoPolygon _ => 0,
      GeoMultiPoint _ => 0,
      GeoMultiLineString multi =>
        multi.lines.fold<double>(0, (sum, line) => sum + geoLength(line)),
      GeoMultiPolygon _ => 0,
      GeoGeometryCollection collection => collection.geometries
          .fold<double>(0, (sum, child) => sum + geoLength(child)),
    };

/// Planar perimeter of polygon rings, in coordinate units.
double geoPerimeter(GeoGeometry geometry) => switch (geometry) {
      GeoPolygon polygon => polygon.isEmpty
          ? 0
          : _pathLength(polygon.exterior!.points) +
              polygon.holes.fold<double>(
                0,
                (sum, hole) => sum + _pathLength(hole.points),
              ),
      GeoMultiPolygon multi => multi.polygons
          .fold<double>(0, (sum, polygon) => sum + geoPerimeter(polygon)),
      GeoGeometryCollection collection => collection.geometries
          .fold<double>(0, (sum, child) => sum + geoPerimeter(child)),
      _ => geoLength(geometry),
    };

/// Signed planar area. Shells add and holes subtract. Units are square
/// coordinate units, including square degrees when the CRS is geographic.
double geoArea(GeoGeometry geometry) => switch (geometry) {
      GeoPolygon polygon => polygon.isEmpty
          ? 0
          : _signedArea(polygon.exterior!.points).abs() -
              polygon.holes.fold<double>(
                0,
                (sum, hole) => sum + _signedArea(hole.points).abs(),
              ),
      GeoMultiPolygon multi => multi.polygons
          .fold<double>(0, (sum, polygon) => sum + geoArea(polygon)),
      GeoGeometryCollection collection => collection.geometries
          .fold<double>(0, (sum, child) => sum + geoArea(child)),
      _ => 0,
    };

double _pathLength(List<GeoCoordinate> points) {
  var length = 0.0;
  for (var i = 1; i < points.length; i++) {
    length += _hypot(points[i - 1], points[i]);
  }
  return length;
}

double _hypot(GeoCoordinate left, GeoCoordinate right) {
  final dx = left.x - right.x;
  final dy = left.y - right.y;
  return math.sqrt(dx * dx + dy * dy);
}

/// Minimum planar distance. Intersecting geometries return 0.
double geoDistance(GeoGeometry left, GeoGeometry right) {
  _requireSameSrid(left, right);
  if (left.isEmpty || right.isEmpty) {
    throw const GeoException('empty geometry has no distance');
  }
  if (geoIntersects(left, right)) return 0;
  var best = double.infinity;
  for (final a in _segmentsOf(left)) {
    for (final b in _segmentsOf(right)) {
      best = math.min(best, _segmentDistance(a.$1, a.$2, b.$1, b.$2));
    }
  }
  if (best.isFinite) return best;
  final leftPoints = left.coordinates;
  final rightPoints = right.coordinates;
  for (final a in leftPoints) {
    for (final b in rightPoints) {
      best = math.min(best, _hypot(a, b));
    }
  }
  if (!best.isFinite) throw const GeoException('distance is undefined');
  return best;
}

List<(GeoCoordinate, GeoCoordinate)> _segmentsOf(GeoGeometry geometry) {
  final segments = <(GeoCoordinate, GeoCoordinate)>[];
  void add(List<GeoCoordinate> points) {
    for (var i = 1; i < points.length; i++) {
      segments.add((points[i - 1], points[i]));
    }
  }

  switch (geometry) {
    case GeoPoint point:
      if (point.position != null) {
        segments.add((point.position!, point.position!));
      }
    case GeoLineString line:
      add(line.points);
    case GeoPolygon polygon:
      if (polygon.exterior != null) add(polygon.exterior!.points);
      for (final hole in polygon.holes) {
        add(hole.points);
      }
    case GeoMultiPoint multi:
      for (final point in multi.points) {
        segments.addAll(_segmentsOf(point));
      }
    case GeoMultiLineString multi:
      for (final line in multi.lines) {
        add(line.points);
      }
    case GeoMultiPolygon multi:
      for (final polygon in multi.polygons) {
        segments.addAll(_segmentsOf(polygon));
      }
    case GeoGeometryCollection collection:
      for (final child in collection.geometries) {
        segments.addAll(_segmentsOf(child));
      }
  }
  return segments;
}

double _segmentDistance(
  GeoCoordinate a,
  GeoCoordinate b,
  GeoCoordinate c,
  GeoCoordinate d,
) {
  if (geoSegmentHit(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y).intersects) {
    return 0;
  }
  return math.min(
    math.min(_pointSegmentDistance(a, c, d), _pointSegmentDistance(b, c, d)),
    math.min(_pointSegmentDistance(c, a, b), _pointSegmentDistance(d, a, b)),
  );
}

double _pointSegmentDistance(
  GeoCoordinate point,
  GeoCoordinate start,
  GeoCoordinate end,
) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final length = dx * dx + dy * dy;
  if (length == 0) return _hypot(point, start);
  final t = (((point.x - start.x) * dx + (point.y - start.y) * dy) / length)
      .clamp(0.0, 1.0);
  return _hypot(
    point,
    GeoCoordinate(start.x + t * dx, start.y + t * dy),
  );
}

/// Area-weighted or length-weighted centre. An empty geometry returns null.
GeoPoint? geoCentroid(GeoGeometry geometry) {
  if (geometry.isEmpty) return null;
  return switch (geometry) {
    GeoPoint point => point,
    GeoMultiPoint multi => _average(multi.coordinates, geometry.srid),
    GeoLineString line => _lineCentroid(line.points, geometry.srid),
    GeoMultiLineString multi => _weighted(
        [for (final line in multi.lines) geoCentroid(line)],
        [for (final line in multi.lines) geoLength(line)],
        geometry.srid,
      ),
    GeoPolygon polygon => _polygonCentroid(polygon),
    GeoMultiPolygon multi => _weighted(
        [for (final polygon in multi.polygons) geoCentroid(polygon)],
        [for (final polygon in multi.polygons) geoArea(polygon)],
        geometry.srid,
      ),
    GeoGeometryCollection collection => geoCentroid(
        collection.geometries.firstWhere((child) => !child.isEmpty),
      ),
  };
}

GeoPoint? _average(Iterable<GeoCoordinate> coordinates, int srid) {
  var count = 0;
  var x = 0.0;
  var y = 0.0;
  for (final coordinate in coordinates) {
    x += coordinate.x;
    y += coordinate.y;
    count++;
  }
  if (count == 0) return null;
  return GeoPoint.xy(x / count, y / count, srid: srid);
}

GeoPoint? _lineCentroid(List<GeoCoordinate> points, int srid) {
  var length = 0.0;
  var x = 0.0;
  var y = 0.0;
  for (var i = 1; i < points.length; i++) {
    final span = _hypot(points[i - 1], points[i]);
    length += span;
    x += (points[i - 1].x + points[i].x) / 2 * span;
    y += (points[i - 1].y + points[i].y) / 2 * span;
  }
  if (length == 0) return _average(points, srid);
  return GeoPoint.xy(x / length, y / length, srid: srid);
}

GeoPoint? _polygonCentroid(GeoPolygon polygon) {
  if (polygon.isEmpty) return null;
  final shell = _ringCentroid(polygon.exterior!.points);
  if (shell == null) return _average(polygon.exterior!.points, polygon.srid);
  if (polygon.holes.isEmpty) {
    return GeoPoint.xy(shell.x, shell.y, srid: polygon.srid);
  }
  var area = _signedArea(polygon.exterior!.points).abs();
  var x = shell.x * area;
  var y = shell.y * area;
  for (final hole in polygon.holes) {
    final centre = _ringCentroid(hole.points);
    final holeArea = _signedArea(hole.points).abs();
    if (centre == null) continue;
    area -= holeArea;
    x -= centre.x * holeArea;
    y -= centre.y * holeArea;
  }
  if (area == 0) return GeoPoint.xy(shell.x, shell.y, srid: polygon.srid);
  return GeoPoint.xy(x / area, y / area, srid: polygon.srid);
}

GeoPoint? _weighted(List<GeoPoint?> centres, List<double> weights, int srid) {
  var weight = 0.0;
  var x = 0.0;
  var y = 0.0;
  for (var i = 0; i < centres.length; i++) {
    final centre = centres[i];
    if (centre == null || centre.isEmpty) continue;
    weight += weights[i];
    x += centre.position!.x * weights[i];
    y += centre.position!.y * weights[i];
  }
  if (weight == 0) return centres.whereType<GeoPoint>().firstOrNull;
  return GeoPoint.xy(x / weight, y / weight, srid: srid);
}

/// A point on the geometry. For a polygon it is strictly interior when a
/// probe exists.
GeoPoint? geoPointOnSurface(GeoGeometry geometry) {
  if (geometry.isEmpty) return null;
  return switch (geometry) {
    GeoPoint point => point,
    GeoLineString line => _lineCentroid(line.points, line.srid) ??
        GeoPoint.xy(line.points.first.x, line.points.first.y, srid: line.srid),
    GeoPolygon polygon => _polygonSurface(polygon),
    GeoMultiPoint multi => geoPointOnSurface(
        multi.points.firstWhere((point) => !point.isEmpty),
      ),
    GeoMultiLineString multi => geoPointOnSurface(
        multi.lines.firstWhere((line) => !line.isEmpty),
      ),
    GeoMultiPolygon multi => geoPointOnSurface(
        multi.polygons.firstWhere((polygon) => !polygon.isEmpty),
      ),
    GeoGeometryCollection collection => geoPointOnSurface(
        collection.geometries.firstWhere((child) => !child.isEmpty),
      ),
  };
}

GeoPoint _polygonSurface(GeoPolygon polygon) {
  final probe = _interiorProbe(polygon.exterior!.points);
  if (probe != null && geoLocate(polygon, probe) == GeoLocation.interior) {
    return GeoPoint.xy(probe.x, probe.y, srid: polygon.srid);
  }
  for (var i = 0; i < polygon.exterior!.points.length - 1; i++) {
    final start = polygon.exterior!.points[i];
    final end = polygon.exterior!.points[i + 1];
    final mid = GeoCoordinate((start.x + end.x) / 2, (start.y + end.y) / 2);
    if (geoLocate(polygon, mid) != GeoLocation.exterior) {
      return GeoPoint.xy(mid.x, mid.y, srid: polygon.srid);
    }
  }
  final first = polygon.exterior!.points.first;
  return GeoPoint.xy(first.x, first.y, srid: polygon.srid);
}

/// OGC boundary. A point's boundary is an empty collection.
GeoGeometry geoBoundary(GeoGeometry geometry) => switch (geometry) {
      GeoPoint point => GeoGeometryCollection(
          const [],
          srid: point.srid,
          dimension: point.dimension,
        ),
      GeoLineString line => _lineBoundary(line),
      GeoPolygon polygon => _polygonBoundary(polygon),
      GeoMultiPoint multi => GeoGeometryCollection(
          const [],
          srid: multi.srid,
          dimension: multi.dimension,
        ),
      GeoMultiLineString multi => GeoGeometryCollection(
          [for (final line in multi.lines) _lineBoundary(line)],
          srid: multi.srid,
          dimension: multi.dimension,
        ),
      GeoMultiPolygon multi => GeoMultiLineString(
          [
            for (final polygon in multi.polygons)
              if (_polygonBoundary(polygon) case GeoMultiLineString lines)
                ...lines.lines
              else if (_polygonBoundary(polygon) case GeoLineString line)
                line,
          ],
          srid: multi.srid,
          dimension: multi.dimension,
        ),
      GeoGeometryCollection collection => GeoGeometryCollection(
          [for (final child in collection.geometries) geoBoundary(child)],
          srid: collection.srid,
          dimension: collection.dimension,
        ),
    };

GeoGeometry _lineBoundary(GeoLineString line) {
  if (line.points.length < 2 || line.isClosed) {
    return GeoMultiPoint(const [], srid: line.srid, dimension: line.dimension);
  }
  final start = line.points.first;
  final end = line.points.last;
  if (start.equalsExact(end)) {
    return GeoPoint.xy(start.x, start.y,
        z: start.z, m: start.m, srid: line.srid);
  }
  return GeoMultiPoint(
    [
      GeoPoint.xy(start.x, start.y, z: start.z, m: start.m, srid: line.srid),
      GeoPoint.xy(end.x, end.y, z: end.z, m: end.m, srid: line.srid),
    ],
    srid: line.srid,
    dimension: line.dimension,
  );
}

GeoGeometry _polygonBoundary(GeoPolygon polygon) {
  if (polygon.isEmpty) {
    return GeoMultiLineString(const [],
        srid: polygon.srid, dimension: polygon.dimension);
  }
  final lines = <GeoLineString>[
    GeoLineString(polygon.exterior!.points,
        srid: polygon.srid, dimension: polygon.dimension),
    for (final hole in polygon.holes)
      GeoLineString(hole.points,
          srid: polygon.srid, dimension: polygon.dimension),
  ];
  if (lines.length == 1) return lines.single;
  return GeoMultiLineString(lines,
      srid: polygon.srid, dimension: polygon.dimension);
}
