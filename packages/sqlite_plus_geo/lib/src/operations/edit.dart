part of '../geo_engine.dart';

/// Adds [dx] and [dy] in coordinate units. [dz] is ignored when Z is absent.
GeoGeometry geoTranslate(
  GeoGeometry geometry,
  double dx,
  double dy, {
  double dz = 0,
}) =>
    _mapCoordinates(geometry, (coordinate) {
      return GeoCoordinate(
        coordinate.x + dx,
        coordinate.y + dy,
        z: coordinate.z == null ? null : coordinate.z! + dz,
        m: coordinate.m,
      );
    });

/// Scales around the origin. This is not a ground-unit conversion.
GeoGeometry geoScale(GeoGeometry geometry, double sx, double sy,
        {double sz = 1}) =>
    _mapCoordinates(geometry, (coordinate) {
      return GeoCoordinate(
        coordinate.x * sx,
        coordinate.y * sy,
        z: coordinate.z == null ? null : coordinate.z! * sz,
        m: coordinate.m,
      );
    });

/// Rotates counter-clockwise around the origin, or around [origin] when set.
/// [radians] is planar. It is not a geographic bearing.
GeoGeometry geoRotate(
  GeoGeometry geometry,
  double radians, {
  GeoCoordinate? origin,
}) {
  final sine = math.sin(radians);
  final cosine = math.cos(radians);
  final ox = origin?.x ?? 0;
  final oy = origin?.y ?? 0;
  return _mapCoordinates(geometry, (coordinate) {
    final x = coordinate.x - ox;
    final y = coordinate.y - oy;
    return GeoCoordinate(
      ox + x * cosine - y * sine,
      oy + x * sine + y * cosine,
      z: coordinate.z,
      m: coordinate.m,
    );
  });
}

/// Reverses coordinate order. Polygon holes stay holes.
GeoGeometry geoReverse(GeoGeometry geometry) => switch (geometry) {
      GeoPoint point => point,
      GeoLineString line => line is GeoLinearRing
          ? GeoLinearRing(line.points.reversed.toList(), srid: line.srid)
          : GeoLineString(line.points.reversed.toList(), srid: line.srid),
      GeoPolygon polygon => GeoPolygon(
          exteriorRing: polygon.exterior?.points.reversed.toList(),
          holes: [
            for (final hole in polygon.holes) hole.points.reversed.toList(),
          ],
          srid: polygon.srid,
          dimension: polygon.dimension,
        ),
      GeoMultiPoint multi => GeoMultiPoint(
          multi.points.reversed.toList(),
          srid: multi.srid,
          dimension: multi.dimension,
        ),
      GeoMultiLineString multi => GeoMultiLineString(
          [
            for (final line in multi.lines.reversed)
              geoReverse(line) as GeoLineString
          ],
          srid: multi.srid,
          dimension: multi.dimension,
        ),
      GeoMultiPolygon multi => GeoMultiPolygon(
          [
            for (final polygon in multi.polygons.reversed)
              geoReverse(polygon) as GeoPolygon
          ],
          srid: multi.srid,
          dimension: multi.dimension,
        ),
      GeoGeometryCollection collection => GeoGeometryCollection(
          [
            for (final child in collection.geometries.reversed)
              geoReverse(child)
          ],
          srid: collection.srid,
          dimension: collection.dimension,
        ),
    };

/// Drops Z and M.
GeoGeometry geoForce2d(GeoGeometry geometry) => _mapCoordinates(
      geometry,
      (coordinate) => GeoCoordinate(coordinate.x, coordinate.y),
      dimension: GeoDimension.xy,
    );

/// Sets a missing Z to [z]. Existing Z is kept. M is dropped.
GeoGeometry geoForce3d(GeoGeometry geometry, {double z = 0}) => _mapCoordinates(
      geometry,
      (coordinate) =>
          GeoCoordinate(coordinate.x, coordinate.y, z: coordinate.z ?? z),
      dimension: GeoDimension.xyz,
    );

/// Moves vertices of [geometry] onto vertices of [reference] within [tolerance].
/// Tolerance is planar and uses the same unit as the coordinates.
GeoGeometry geoSnap(
    GeoGeometry geometry, GeoGeometry reference, double tolerance) {
  _requireSameSrid(geometry, reference);
  if (tolerance < 0) {
    throw const GeoException('snap tolerance must be non-negative');
  }
  final targets = reference.coordinates.toList();
  if (geometry.coordinates.length * targets.length > 20000 * 20000) {
    throw const GeoException('snap vertex limit exceeded');
  }
  return _mapCoordinates(geometry, (coordinate) {
    GeoCoordinate? nearest;
    var best = tolerance;
    for (final target in targets) {
      final distance = _hypot(coordinate, target);
      if (distance <= best) {
        best = distance;
        nearest = target;
      }
    }
    if (nearest == null) return coordinate;
    return GeoCoordinate(nearest.x, nearest.y,
        z: coordinate.z, m: coordinate.m);
  });
}

/// Douglas–Peucker simplification. [tolerance] is planar.
GeoGeometry geoSimplify(GeoGeometry geometry, double tolerance) {
  if (tolerance < 0) {
    throw const GeoException('simplify tolerance must be non-negative');
  }
  return _simplify(geometry, tolerance, preserve: false);
}

/// Douglas–Peucker simplification that returns the original polygon when the
/// simplified ring is invalid.
GeoGeometry geoSimplifyPreserveTopology(
    GeoGeometry geometry, double tolerance) {
  if (tolerance < 0) {
    throw const GeoException('simplify tolerance must be non-negative');
  }
  return _simplify(geometry, tolerance, preserve: true);
}

GeoGeometry _simplify(GeoGeometry geometry, double tolerance,
    {required bool preserve}) {
  return switch (geometry) {
    GeoPoint point => point,
    GeoLineString line => GeoLineString(
        _douglas(line.points, tolerance),
        srid: line.srid,
        dimension: line.dimension,
      ),
    GeoPolygon polygon =>
      _simplifyPolygon(polygon, tolerance, preserve: preserve),
    GeoMultiPoint multi => multi,
    GeoMultiLineString multi => GeoMultiLineString(
        [
          for (final line in multi.lines)
            geoSimplify(line, tolerance) as GeoLineString,
        ],
        srid: multi.srid,
        dimension: multi.dimension,
      ),
    GeoMultiPolygon multi => GeoMultiPolygon(
        [
          for (final child in multi.polygons)
            _simplifyPolygon(child, tolerance, preserve: preserve),
        ],
        srid: multi.srid,
        dimension: multi.dimension,
      ),
    GeoGeometryCollection collection => GeoGeometryCollection(
        [
          for (final child in collection.geometries)
            _simplify(child, tolerance, preserve: preserve),
        ],
        srid: collection.srid,
        dimension: collection.dimension,
      ),
  };
}

GeoPolygon _simplifyPolygon(
  GeoPolygon polygon,
  double tolerance, {
  required bool preserve,
}) {
  if (polygon.isEmpty) return polygon;
  final simplified = GeoPolygon(
    exteriorRing: _closeSimplified(polygon.exterior!.points, tolerance),
    holes: [
      for (final hole in polygon.holes)
        _closeSimplified(hole.points, tolerance),
    ],
    srid: polygon.srid,
    dimension: polygon.dimension,
  );
  if (preserve && !simplified.isValid) return polygon;
  return simplified;
}

List<GeoCoordinate> _closeSimplified(
    List<GeoCoordinate> ring, double tolerance) {
  if (ring.length < 4) return ring;
  final open = ring.first.equalsExact(ring.last)
      ? ring.sublist(0, ring.length - 1)
      : ring;
  final simplified = _douglas(open, tolerance);
  if (simplified.length < 3) return ring;
  return [...simplified, simplified.first];
}

List<GeoCoordinate> _douglas(List<GeoCoordinate> points, double tolerance) {
  if (points.length < 3) return points;
  var farthest = 0.0;
  var index = 1;
  for (var i = 1; i < points.length - 1; i++) {
    final distance =
        _pointSegmentDistance(points[i], points.first, points.last);
    if (distance > farthest) {
      farthest = distance;
      index = i;
    }
  }
  if (farthest <= tolerance) return [points.first, points.last];
  final left = _douglas(points.sublist(0, index + 1), tolerance);
  final right = _douglas(points.sublist(index), tolerance);
  return [...left.take(left.length - 1), ...right];
}

/// Joins line strings that share an exact endpoint.
GeoGeometry geoLineMerge(GeoGeometry geometry) {
  final lines = <List<GeoCoordinate>>[];
  void take(GeoGeometry child) {
    switch (child) {
      case GeoLineString line:
        if (line.points.length >= 2) lines.add(List.of(line.points));
      case GeoMultiLineString multi:
        for (final line in multi.lines) {
          take(line);
        }
      case GeoGeometryCollection collection:
        for (final part in collection.geometries) {
          take(part);
        }
      default:
        break;
    }
  }

  take(geometry);
  var changed = true;
  while (changed) {
    changed = false;
    for (var i = 0; i < lines.length && !changed; i++) {
      for (var j = i + 1; j < lines.length; j++) {
        final merged = _joinLines(lines[i], lines[j]);
        if (merged == null) continue;
        lines[i] = merged;
        lines.removeAt(j);
        changed = true;
        break;
      }
    }
  }
  if (lines.isEmpty) {
    return GeoLineString.empty(
        srid: geometry.srid, dimension: geometry.dimension);
  }
  final built = [
    for (final line in lines)
      GeoLineString(line, srid: geometry.srid, dimension: geometry.dimension),
  ];
  if (built.length == 1) return built.single;
  return GeoMultiLineString(built,
      srid: geometry.srid, dimension: geometry.dimension);
}

List<GeoCoordinate>? _joinLines(
    List<GeoCoordinate> left, List<GeoCoordinate> right) {
  if (left.last.equalsExact(right.first)) return [...left, ...right.skip(1)];
  if (left.last.equalsExact(right.last)) {
    return [...left, ...right.reversed.skip(1)];
  }
  if (left.first.equalsExact(right.last)) return [...right, ...left.skip(1)];
  if (left.first.equalsExact(right.first)) {
    return [...right.reversed, ...left.skip(1)];
  }
  return null;
}

GeoGeometry _mapCoordinates(
  GeoGeometry geometry,
  GeoCoordinate Function(GeoCoordinate coordinate) map, {
  GeoDimension? dimension,
}) {
  GeoCoordinate convert(GeoCoordinate coordinate) => map(coordinate);
  List<GeoCoordinate> convertAll(List<GeoCoordinate> points) =>
      [for (final point in points) convert(point)];
  return switch (geometry) {
    GeoPoint point => point.isEmpty
        ? GeoPoint.empty(
            srid: point.srid,
            dimension: dimension ?? point.dimension,
          )
        : GeoPoint.xy(
            convert(point.position!).x,
            convert(point.position!).y,
            z: convert(point.position!).z,
            m: convert(point.position!).m,
            srid: point.srid,
          ),
    GeoLineString line => line is GeoLinearRing
        ? GeoLinearRing(convertAll(line.points), srid: line.srid)
        : GeoLineString(convertAll(line.points), srid: line.srid),
    GeoPolygon polygon => GeoPolygon(
        exteriorRing: polygon.exterior == null
            ? null
            : convertAll(polygon.exterior!.points),
        holes: [for (final hole in polygon.holes) convertAll(hole.points)],
        srid: polygon.srid,
      ),
    GeoMultiPoint multi => GeoMultiPoint(
        [
          for (final point in multi.points)
            _mapCoordinates(point, map) as GeoPoint
        ],
        srid: multi.srid,
      ),
    GeoMultiLineString multi => GeoMultiLineString(
        [
          for (final line in multi.lines)
            _mapCoordinates(line, map) as GeoLineString,
        ],
        srid: multi.srid,
      ),
    GeoMultiPolygon multi => GeoMultiPolygon(
        [
          for (final polygon in multi.polygons)
            _mapCoordinates(polygon, map) as GeoPolygon,
        ],
        srid: multi.srid,
      ),
    GeoGeometryCollection collection => GeoGeometryCollection(
        [
          for (final child in collection.geometries) _mapCoordinates(child, map)
        ],
        srid: collection.srid,
      ),
  };
}
