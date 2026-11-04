part of '../geo_engine.dart';

const _valid = GeoValidation(true, 'Valid Geometry');
const _validationEdgeLimit = 2000;

GeoValidation _validateGeometry(GeoGeometry geometry, GeoLimits limits) {
  if (_countCoordinates(geometry) > limits.maxCoordinates) {
    return const GeoValidation(false, 'geometry exceeds the coordinate limit');
  }
  return switch (geometry) {
    GeoPoint _ => _valid,
    GeoLineString line => _validateLine(line),
    GeoPolygon polygon => _validatePolygon(polygon),
    GeoMultiPoint multi => _validateParts(multi.points),
    GeoMultiLineString multi => _validateParts(multi.lines),
    GeoMultiPolygon multi => _validateParts(multi.polygons),
    GeoGeometryCollection collection => _validateParts(collection.geometries),
  };
}

GeoValidation _validateParts(List<GeoGeometry> parts) {
  for (final part in parts) {
    final result = part.validate();
    if (!result.valid) return result;
  }
  return _valid;
}

GeoValidation _validateLine(GeoLineString line) {
  if (line.isEmpty) return _valid;
  if (line.points.length < 2) {
    return const GeoValidation(false, 'line string has fewer than 2 positions');
  }
  if (line is GeoLinearRing) {
    final problem = _ringProblem(line.points);
    if (problem != null) return GeoValidation(false, problem);
  }
  return _valid;
}

GeoValidation _validatePolygon(GeoPolygon polygon) {
  if (polygon.isEmpty) return _valid;
  final shell = polygon.exterior!;
  final shellProblem = _ringProblem(shell.points);
  if (shellProblem != null) return GeoValidation(false, shellProblem);
  final shellProbe = _interiorProbe(shell.points);
  if (shellProbe == null) {
    return const GeoValidation(
        false, 'polygon interior could not be confirmed');
  }
  for (final hole in polygon.holes) {
    final problem = _ringProblem(hole.points);
    if (problem != null) return GeoValidation(false, 'hole $problem');
    if (_ringsCross(shell.points, hole.points)) {
      return const GeoValidation(false, 'hole crosses the exterior ring');
    }
    for (final vertex in hole.points) {
      if (_ringLocation(vertex.x, vertex.y, shell.points) ==
          GeoLocation.exterior) {
        return const GeoValidation(false, 'hole is outside the exterior ring');
      }
    }
    final probe = _interiorProbe(hole.points);
    if (probe == null ||
        _ringLocation(probe.x, probe.y, shell.points) != GeoLocation.interior) {
      return const GeoValidation(false, 'hole is not inside the exterior ring');
    }
  }
  for (var i = 0; i < polygon.holes.length; i++) {
    for (var j = i + 1; j < polygon.holes.length; j++) {
      if (_ringsCross(polygon.holes[i].points, polygon.holes[j].points)) {
        return const GeoValidation(false, 'holes cross each other');
      }
      final probe = _interiorProbe(polygon.holes[i].points);
      if (probe != null &&
          _ringLocation(probe.x, probe.y, polygon.holes[j].points) ==
              GeoLocation.interior) {
        return const GeoValidation(false, 'a hole contains another hole');
      }
    }
  }
  return _valid;
}

String? _ringProblem(List<GeoCoordinate> ring) {
  if (ring.length < 4) return 'ring has fewer than 4 positions';
  if (!ring.first.equalsExact(ring.last)) return 'ring is not closed';
  for (var i = 1; i < ring.length; i++) {
    if (ring[i].equalsExact(ring[i - 1])) {
      return 'ring repeats a position';
    }
  }
  final edges = ring.length - 1;
  if (edges > _validationEdgeLimit) {
    throw const GeoException('validation edge limit exceeded');
  }
  for (var i = 0; i < edges; i++) {
    for (var j = i + 1; j < edges; j++) {
      if (j == i + 1 || (i == 0 && j == edges - 1)) continue;
      final hit = _hitRings(ring, i, ring, j);
      if (hit.intersects) return 'ring intersects itself';
    }
  }
  return null;
}

bool _ringsCross(List<GeoCoordinate> left, List<GeoCoordinate> right) {
  final leftEdges = left.length - 1;
  final rightEdges = right.length - 1;
  if (leftEdges > _validationEdgeLimit || rightEdges > _validationEdgeLimit) {
    throw const GeoException('validation edge limit exceeded');
  }
  for (var i = 0; i < leftEdges; i++) {
    for (var j = 0; j < rightEdges; j++) {
      final hit = _hitRings(left, i, right, j);
      if (hit.proper || hit.overlap) return true;
    }
  }
  return false;
}

SegmentHit _hitRings(
    List<GeoCoordinate> left, int i, List<GeoCoordinate> right, int j) {
  final a = left[i];
  final b = left[i + 1];
  final c = right[j];
  final d = right[j + 1];
  return geoSegmentHit(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y);
}

/// Whether [geometry] has no self-intersection. An invalid polygon is not simple.
bool geoIsSimple(GeoGeometry geometry) {
  if (!geometry.isValid) return false;
  return switch (geometry) {
    GeoPoint _ => true,
    GeoLineString line => _lineIsSimple(line),
    GeoPolygon _ => true,
    GeoMultiPoint _ => true,
    GeoMultiLineString multi => multi.lines.every(_lineIsSimple),
    GeoMultiPolygon _ => true,
    GeoGeometryCollection collection =>
      collection.geometries.every(geoIsSimple),
  };
}

bool _lineIsSimple(GeoLineString line) {
  if (line.points.length < 2) return line.isEmpty;
  final edges = line.points.length - 1;
  if (edges > _validationEdgeLimit) {
    throw const GeoException('validation edge limit exceeded');
  }
  for (var i = 0; i < edges; i++) {
    for (var j = i + 1; j < edges; j++) {
      if (j == i + 1) continue;
      if (line.isClosed && i == 0 && j == edges - 1) continue;
      final a = line.points[i];
      final b = line.points[i + 1];
      final c = line.points[j];
      final d = line.points[j + 1];
      if (geoSegmentHit(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y).intersects) {
        return false;
      }
    }
  }
  return true;
}

GeoGeometry _normalizeGeometry(GeoGeometry geometry) => switch (geometry) {
      GeoPoint point => point,
      GeoLineString line => line,
      GeoPolygon polygon => _orientPolygon(polygon),
      GeoMultiPoint multi => multi,
      GeoMultiLineString multi => multi,
      GeoMultiPolygon multi => GeoMultiPolygon(
          [for (final polygon in multi.polygons) _orientPolygon(polygon)],
          srid: multi.srid,
          dimension: multi.dimension,
        ),
      GeoGeometryCollection collection => GeoGeometryCollection(
          [for (final child in collection.geometries) child.normalize()],
          srid: collection.srid,
          dimension: collection.dimension,
        ),
    };

GeoPolygon _orientPolygon(GeoPolygon polygon) {
  if (polygon.exterior == null) return polygon;
  return GeoPolygon(
    exteriorRing: _oriented(polygon.exterior!.points, counterClockwise: true),
    holes: [
      for (final hole in polygon.holes)
        _oriented(hole.points, counterClockwise: false),
    ],
    srid: polygon.srid,
    dimension: polygon.dimension,
  );
}

List<GeoCoordinate> _oriented(
  List<GeoCoordinate> ring, {
  required bool counterClockwise,
}) {
  if (ring.length < 4 || !ring.first.equalsExact(ring.last)) return ring;
  final counter = _signedArea(ring) > 0;
  if (counter == counterClockwise) return ring;
  final reversed = ring.reversed.toList();
  return reversed;
}

double _signedArea(List<GeoCoordinate> ring) {
  var sum = 0.0;
  for (var i = 0; i < ring.length - 1; i++) {
    sum += ring[i].x * ring[i + 1].y - ring[i + 1].x * ring[i].y;
  }
  return sum / 2;
}

/// Closes rings, drops an unconfirmed self-intersection into the overlaid
/// faces, and may change a polygon into a multi-polygon.
GeoGeometry geoMakeValid(GeoGeometry geometry) {
  final repaired = switch (geometry) {
    GeoPoint point => point,
    GeoLineString line => _repairLine(line),
    GeoPolygon polygon => _repairPolygon(polygon),
    GeoMultiPoint multi => GeoMultiPoint(
        [for (final point in multi.points) point],
        srid: multi.srid,
        dimension: multi.dimension,
      ),
    GeoMultiLineString multi => GeoMultiLineString(
        [for (final line in multi.lines) _repairLine(line)],
        srid: multi.srid,
        dimension: multi.dimension,
      ),
    GeoMultiPolygon multi => _repairMulti(multi),
    GeoGeometryCollection collection => GeoGeometryCollection(
        [for (final child in collection.geometries) geoMakeValid(child)],
        srid: collection.srid,
        dimension: collection.dimension,
      ),
  };
  return repaired;
}

GeoLineString _repairLine(GeoLineString line) {
  final points = _withoutConsecutiveDuplicates(line.points);
  if (points.length == 1) {
    return GeoLineString.empty(srid: line.srid, dimension: line.dimension);
  }
  return GeoLineString(points, srid: line.srid, dimension: line.dimension);
}

GeoGeometry _repairPolygon(GeoPolygon polygon) {
  if (polygon.isEmpty) return polygon;
  final shell =
      _closed(_withoutConsecutiveDuplicates(polygon.exterior!.points));
  final holes = [
    for (final hole in polygon.holes)
      _closed(_withoutConsecutiveDuplicates(hole.points)),
  ];
  final candidate = GeoPolygon(
    exteriorRing: shell,
    holes: holes,
    srid: polygon.srid,
    dimension: polygon.dimension,
  );
  if (candidate.isValid) return candidate.normalize();
  return _repairByWinding(candidate);
}

GeoGeometry _repairMulti(GeoMultiPolygon multi) {
  final parts = <GeoPolygon>[];
  for (final polygon in multi.polygons) {
    final repaired = _repairPolygon(polygon);
    if (repaired is GeoPolygon && !repaired.isEmpty) parts.add(repaired);
    if (repaired is GeoMultiPolygon) parts.addAll(repaired.polygons);
  }
  if (parts.isEmpty) {
    return GeoPolygon.empty(srid: multi.srid, dimension: multi.dimension);
  }
  if (parts.length == 1) return parts.single;
  return GeoMultiPolygon(parts, srid: multi.srid, dimension: multi.dimension);
}

List<GeoCoordinate> _withoutConsecutiveDuplicates(List<GeoCoordinate> points) {
  final result = <GeoCoordinate>[];
  for (final point in points) {
    if (result.isEmpty || !result.last.equalsExact(point)) result.add(point);
  }
  return result;
}

List<GeoCoordinate> _closed(List<GeoCoordinate> points) {
  if (points.length < 3) return points;
  if (points.first.equalsExact(points.last)) return points;
  return [...points, points.first];
}

GeoGeometry _repairByWinding(GeoPolygon polygon) {
  final rings = [
    polygon.exterior!.points,
    for (final hole in polygon.holes) hole.points,
  ];
  final faces = _extractWindingFaces(rings, polygon.srid, polygon.dimension);
  if (faces.isEmpty) {
    return GeoPolygon.empty(srid: polygon.srid, dimension: polygon.dimension);
  }
  if (faces.length == 1) return faces.single.normalize();
  return GeoMultiPolygon(faces,
          srid: polygon.srid, dimension: polygon.dimension)
      .normalize();
}
