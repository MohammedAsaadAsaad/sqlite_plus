part of '../geo_engine.dart';

/// Nine-character DE-9IM string. `F` is empty and `0`, `1`, and `2` are
/// dimensions. The matrix is interior, boundary, exterior on each axis.
String geoRelate(GeoGeometry left, GeoGeometry right) {
  _requireSameSrid(left, right);
  if (left.isEmpty || right.isEmpty) return 'FFFFFFFFF';
  final matrix = List<int>.filled(9, -1);
  matrix[8] = 2;
  _fillRelate(left, right, matrix);
  return matrix.map((value) => value < 0 ? 'F' : '$value').join();
}

/// Whether [matrix] matches an OGC pattern. `T` is 0, 1, or 2. `*` is any.
bool geoRelateMatches(String matrix, String pattern) {
  if (matrix.length != 9 || pattern.length != 9) {
    throw const GeoException('a DE-9IM pattern has 9 characters');
  }
  for (var i = 0; i < 9; i++) {
    final expected = pattern[i];
    final actual = matrix[i];
    if (expected == '*') continue;
    if (expected == 'T') {
      if (actual == 'F') return false;
      continue;
    }
    if (expected != actual) return false;
  }
  return true;
}

void _setDim(List<int> matrix, int index, int dimension) {
  if (dimension > matrix[index]) matrix[index] = dimension;
}

void _fillRelate(GeoGeometry left, GeoGeometry right, List<int> matrix) {
  if (left is GeoPolygon && right is GeoPolygon) {
    _relatePolygons(left, right, matrix);
    return;
  }
  if (left is GeoPoint && right is GeoPoint) {
    final same = left.position!.x == right.position!.x &&
        left.position!.y == right.position!.y;
    _setDim(matrix, same ? 0 : 2, 0);
    _setDim(matrix, same ? 6 : 6, same ? -1 : 0);
    if (!same) _setDim(matrix, 6, 0);
    if (same) {
      matrix[2] = -1;
      matrix[6] = -1;
    }
    return;
  }
  if (left is GeoPoint) {
    _relatePointOther(left, right, matrix, swapped: false);
    return;
  }
  if (right is GeoPoint) {
    _relatePointOther(right, left, matrix, swapped: true);
    return;
  }
  if (left is GeoLineString && right is GeoLineString) {
    _relateLines(left, right, matrix);
    return;
  }
  if (left is GeoLineString && right is GeoPolygon) {
    _relateLinePolygon(left, right, matrix, swapped: false);
    return;
  }
  if (left is GeoPolygon && right is GeoLineString) {
    _relateLinePolygon(right, left, matrix, swapped: true);
    return;
  }
  if (left is GeoMultiPolygon || right is GeoMultiPolygon) {
    _relateFlattened(left, right, matrix);
    return;
  }
  if (left is GeoGeometryCollection || right is GeoGeometryCollection) {
    _relateFlattened(left, right, matrix);
    return;
  }
  _relateByLocations(left, right, matrix);
}

void _relatePointOther(
  GeoPoint point,
  GeoGeometry other,
  List<int> matrix, {
  required bool swapped,
}) {
  final location = geoLocate(other, point.position!);
  void put(int row, int column, int dimension) {
    final index = swapped ? column * 3 + row : row * 3 + column;
    if (dimension >= 0) _setDim(matrix, index, dimension);
  }

  // Point interior/boundary/exterior against the other geometry.
  if (location == GeoLocation.interior) put(0, 0, 0);
  if (location == GeoLocation.boundary) put(0, 1, 0);
  if (location == GeoLocation.exterior) put(0, 2, 0);
  put(2, 0, other.type.topologicalDimension);
  if (other is GeoPolygon || other is GeoLineString) put(2, 1, 1);
  put(2, 2, 2);
}

void _relateLines(GeoLineString left, GeoLineString right, List<int> matrix) {
  var interior = -1;
  for (var i = 0; i < left.points.length - 1; i++) {
    for (var j = 0; j < right.points.length - 1; j++) {
      final hit = geoSegmentHit(
        left.points[i].x,
        left.points[i].y,
        left.points[i + 1].x,
        left.points[i + 1].y,
        right.points[j].x,
        right.points[j].y,
        right.points[j + 1].x,
        right.points[j + 1].y,
      );
      if (!hit.intersects) continue;
      _setDim(matrix, 0, hit.overlap ? 1 : 0);
      interior = math.max(interior, hit.overlap ? 1 : 0);
    }
  }
  _locateEndpoints(left, right, matrix, leftRow: true);
  _locateEndpoints(right, left, matrix, leftRow: false);
  if (matrix[0] < 0) _setDim(matrix, 2, 1);
  if (matrix[6] < 0) _setDim(matrix, 6, 1);
  _setDim(matrix, 8, 2);
}

void _locateEndpoints(
  GeoLineString line,
  GeoLineString other,
  List<int> matrix, {
  required bool leftRow,
}) {
  if (line.points.length < 2 || line.isClosed) return;
  for (final endpoint in [line.points.first, line.points.last]) {
    final location = _locateLine(other, endpoint.x, endpoint.y);
    final column = switch (location) {
      GeoLocation.interior => 0,
      GeoLocation.boundary => 1,
      GeoLocation.exterior => 2,
    };
    final index = leftRow ? 3 + column : column * 3 + 1;
    _setDim(matrix, index, 0);
  }
}

void _relateLinePolygon(
  GeoLineString line,
  GeoPolygon polygon,
  List<int> matrix, {
  required bool swapped,
}) {
  void put(int lineDim, int polygonDim, int dimension) {
    final index = swapped ? polygonDim * 3 + lineDim : lineDim * 3 + polygonDim;
    if (dimension >= 0) _setDim(matrix, index, dimension);
  }

  var sawInside = false;
  var sawOutside = false;
  for (var i = 0; i < line.points.length - 1; i++) {
    final mid = GeoCoordinate(
      (line.points[i].x + line.points[i + 1].x) / 2,
      (line.points[i].y + line.points[i + 1].y) / 2,
    );
    switch (geoLocate(polygon, mid)) {
      case GeoLocation.interior:
        sawInside = true;
        put(0, 0, 1);
      case GeoLocation.boundary:
        put(0, 1, 1);
      case GeoLocation.exterior:
        sawOutside = true;
        put(0, 2, 1);
    }
    for (final ring in [
      polygon.exterior!.points,
      for (final hole in polygon.holes) hole.points,
    ]) {
      for (var j = 0; j < ring.length - 1; j++) {
        final hit = geoSegmentHit(
          line.points[i].x,
          line.points[i].y,
          line.points[i + 1].x,
          line.points[i + 1].y,
          ring[j].x,
          ring[j].y,
          ring[j + 1].x,
          ring[j + 1].y,
        );
        if (hit.intersects) put(0, 1, hit.overlap ? 1 : 0);
      }
    }
  }
  if (line.points.isNotEmpty && !line.isClosed) {
    for (final endpoint in [line.points.first, line.points.last]) {
      final location = geoLocate(polygon, endpoint);
      put(
        1,
        switch (location) {
          GeoLocation.interior => 0,
          GeoLocation.boundary => 1,
          GeoLocation.exterior => 2,
        },
        0,
      );
    }
  }
  put(2, 0, 2);
  put(2, 1, 1);
  put(2, 2, 2);
  if (!sawInside) put(0, 0, -1);
  if (!sawOutside && matrix[2] < 0) {
    // The line may lie entirely in the polygon.
  }
}

void _relatePolygons(GeoPolygon left, GeoPolygon right, List<int> matrix) {
  final leftEdges = _ringEdges(left);
  final rightEdges = _ringEdges(right);
  if (leftEdges.length * rightEdges.length > _validationEdgeLimit * 8) {
    throw const GeoException('relate edge limit exceeded');
  }
  for (final a in leftEdges) {
    final mid = GeoCoordinate((a.$1.x + a.$2.x) / 2, (a.$1.y + a.$2.y) / 2);
    switch (geoLocate(right, mid)) {
      case GeoLocation.interior:
        _setDim(matrix, 3, 1);
      case GeoLocation.boundary:
        _setDim(matrix, 4, 0);
      case GeoLocation.exterior:
        _setDim(matrix, 5, 1);
    }
    for (final b in rightEdges) {
      final hit = geoSegmentHit(
          a.$1.x, a.$1.y, a.$2.x, a.$2.y, b.$1.x, b.$1.y, b.$2.x, b.$2.y);
      if (!hit.intersects) continue;
      _setDim(matrix, 4, hit.overlap ? 1 : 0);
      if (hit.proper) _setDim(matrix, 0, 2);
    }
  }
  for (final b in rightEdges) {
    final mid = GeoCoordinate((b.$1.x + b.$2.x) / 2, (b.$1.y + b.$2.y) / 2);
    switch (geoLocate(left, mid)) {
      case GeoLocation.interior:
        _setDim(matrix, 1, 1);
      case GeoLocation.exterior:
        _setDim(matrix, 7, 1);
      case GeoLocation.boundary:
        _setDim(matrix, 4, 0);
    }
  }
  final leftProbe = _interiorProbe(left.exterior!.points);
  final rightProbe = _interiorProbe(right.exterior!.points);
  if (leftProbe != null) {
    switch (geoLocate(right, leftProbe)) {
      case GeoLocation.interior:
        _setDim(matrix, 0, 2);
      case GeoLocation.exterior:
        _setDim(matrix, 2, 2);
      case GeoLocation.boundary:
        _setDim(matrix, 1, 2);
    }
  }
  if (rightProbe != null) {
    switch (geoLocate(left, rightProbe)) {
      case GeoLocation.interior:
        _setDim(matrix, 0, 2);
      case GeoLocation.exterior:
        _setDim(matrix, 6, 2);
      case GeoLocation.boundary:
        _setDim(matrix, 3, 2);
    }
  }
  _setDim(matrix, 8, 2);
}

List<(GeoCoordinate, GeoCoordinate)> _ringEdges(GeoPolygon polygon) {
  final edges = <(GeoCoordinate, GeoCoordinate)>[];
  void add(List<GeoCoordinate> ring) {
    for (var i = 0; i < ring.length - 1; i++) {
      edges.add((ring[i], ring[i + 1]));
    }
  }

  if (polygon.exterior != null) add(polygon.exterior!.points);
  for (final hole in polygon.holes) {
    add(hole.points);
  }
  return edges;
}

void _relateFlattened(GeoGeometry left, GeoGeometry right, List<int> matrix) {
  final leftParts = _atomic(left);
  final rightParts = _atomic(right);
  if (leftParts.isEmpty || rightParts.isEmpty) return;
  for (final a in leftParts) {
    for (final b in rightParts) {
      final child = List<int>.filled(9, -1);
      child[8] = 2;
      _fillRelate(a, b, child);
      for (var i = 0; i < 9; i++) {
        if (child[i] > matrix[i]) matrix[i] = child[i];
      }
    }
  }
}

void _relateByLocations(GeoGeometry left, GeoGeometry right, List<int> matrix) {
  for (final coordinate in left.coordinates) {
    final location = geoLocate(right, coordinate);
    final column = switch (location) {
      GeoLocation.interior => 0,
      GeoLocation.boundary => 1,
      GeoLocation.exterior => 2,
    };
    _setDim(matrix, column, 0);
  }
  _setDim(matrix, 8, 2);
}

List<GeoGeometry> _atomic(GeoGeometry geometry) => switch (geometry) {
      GeoMultiPoint multi => multi.points,
      GeoMultiLineString multi => multi.lines,
      GeoMultiPolygon multi => multi.polygons,
      GeoGeometryCollection collection => [
          for (final child in collection.geometries) ..._atomic(child),
        ],
      _ => [geometry],
    };

/// Exact predicate wrappers. Bounding boxes are only a rejection test.
bool geoIntersects(GeoGeometry left, GeoGeometry right) {
  if (!_boxesMayMeet(left, right)) return false;
  final matrix = geoRelate(left, right);
  return geoRelateMatches(matrix, 'T********') ||
      geoRelateMatches(matrix, '*T*******') ||
      geoRelateMatches(matrix, '***T*****') ||
      geoRelateMatches(matrix, '****T****');
}

/// The complement of [geoIntersects] for supported geometries.
bool geoDisjoint(GeoGeometry left, GeoGeometry right) =>
    !geoIntersects(left, right);

/// Interiors meet and neither geometry extends outside the other.
bool geoEqualsTopologically(GeoGeometry left, GeoGeometry right) =>
    geoRelateMatches(geoRelate(left, right), 'T*F**FFF*');

/// Every point of [right] is in the interior or boundary of [left], and the
/// interiors meet.
bool geoContains(GeoGeometry left, GeoGeometry right) =>
    geoRelateMatches(geoRelate(left, right), 'T*****FF*');

/// [geoContains] with the arguments swapped.
bool geoWithin(GeoGeometry left, GeoGeometry right) => geoContains(right, left);

/// No point of [right] is outside [left], and the geometries are not disjoint.
bool geoCovers(GeoGeometry left, GeoGeometry right) {
  final matrix = geoRelate(left, right);
  if (geoDisjoint(left, right)) return false;
  return matrix[6] == 'F' && matrix[7] == 'F';
}

/// [geoCovers] with the arguments swapped.
bool geoCoveredBy(GeoGeometry left, GeoGeometry right) =>
    geoCovers(right, left);

/// Boundaries meet and interiors do not.
bool geoTouches(GeoGeometry left, GeoGeometry right) {
  final matrix = geoRelate(left, right);
  if (matrix[0] != 'F') return false;
  return matrix[1] != 'F' || matrix[3] != 'F' || matrix[4] != 'F';
}

/// OGC crosses for lines and for a line against a polygon.
bool geoCrosses(GeoGeometry left, GeoGeometry right) {
  final matrix = geoRelate(left, right);
  final leftDim = _maxDim(left);
  final rightDim = _maxDim(right);
  if (leftDim == 1 && rightDim == 1) return matrix[0] == '0';
  if (leftDim == 1 && rightDim == 2) {
    return matrix[0] != 'F' && matrix[2] != 'F';
  }
  if (leftDim == 2 && rightDim == 1) {
    return matrix[0] != 'F' && matrix[6] != 'F';
  }
  return false;
}

/// Same-dimension partial overlap.
bool geoOverlaps(GeoGeometry left, GeoGeometry right) {
  final matrix = geoRelate(left, right);
  final leftDim = _maxDim(left);
  final rightDim = _maxDim(right);
  if (leftDim != rightDim || leftDim == 0) return false;
  if (leftDim == 2) {
    return matrix[0] == '2' && matrix[2] == '2' && matrix[6] == '2';
  }
  return matrix[0] == '1' && matrix[2] == '1' && matrix[6] == '1';
}

int _maxDim(GeoGeometry geometry) => switch (geometry) {
      GeoGeometryCollection collection => collection.geometries.fold<int>(
          0,
          (dim, child) => math.max(dim, _maxDim(child)),
        ),
      GeoMultiPolygon _ => 2,
      GeoPolygon _ => 2,
      GeoMultiLineString _ || GeoLineString _ => 1,
      _ => geometry.type.topologicalDimension < 0
          ? 0
          : geometry.type.topologicalDimension,
    };

bool _boxesMayMeet(GeoGeometry left, GeoGeometry right) {
  final a = left.envelope;
  final b = right.envelope;
  if (a == null || b == null) return false;
  return a.intersects(b);
}

/// Whether the planar distance is less than or equal to [distance].
bool geoDWithin(GeoGeometry left, GeoGeometry right, double distance) {
  if (distance < 0) throw const GeoException('distance must be non-negative');
  if (left.isEmpty || right.isEmpty) return false;
  final a = left.envelope;
  final b = right.envelope;
  if (a != null && b != null) {
    final expanded = GeoEnvelope(
      minX: b.minX - distance,
      minY: b.minY - distance,
      maxX: b.maxX + distance,
      maxY: b.maxY + distance,
    );
    if (!a.intersects(expanded)) return false;
  }
  return geoDistance(left, right) <= distance;
}
