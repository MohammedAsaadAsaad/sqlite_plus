part of '../geo_engine.dart';

/// Polygon overlay operation.
enum BooleanOp {
  /// Points in either geometry.
  union,

  /// Points in both geometries.
  intersection,

  /// Points in the first geometry and not the second.
  difference,

  /// Points in exactly one geometry.
  symmetric,
}

/// Planar union for the supported type pairs documented in `GEOMETRY.md`.
GeoGeometry geoUnion(GeoGeometry left, GeoGeometry right) =>
    _combine(left, right, BooleanOp.union);

/// Planar intersection for the supported type pairs.
GeoGeometry geoIntersection(GeoGeometry left, GeoGeometry right) =>
    _combine(left, right, BooleanOp.intersection);

/// Planar difference for the supported type pairs.
GeoGeometry geoDifference(GeoGeometry left, GeoGeometry right) =>
    _combine(left, right, BooleanOp.difference);

/// Planar symmetric difference for polygonal geometries.
GeoGeometry geoSymmetricDifference(GeoGeometry left, GeoGeometry right) =>
    _combine(left, right, BooleanOp.symmetric);

GeoGeometry _combine(GeoGeometry left, GeoGeometry right, BooleanOp op) {
  _requireSameSrid(left, right);
  if (left.dimension != right.dimension && !left.isEmpty && !right.isEmpty) {
    throw const GeoException('geometry dimensions differ');
  }
  if (left.isEmpty) {
    return op == BooleanOp.intersection || op == BooleanOp.symmetric
        ? (op == BooleanOp.symmetric ? right : _emptyOf(left))
        : (op == BooleanOp.difference ? _emptyOf(left) : right);
  }
  if (right.isEmpty) {
    return op == BooleanOp.intersection ? _emptyOf(right) : left;
  }
  if (_isPolygonal(left) && _isPolygonal(right)) {
    return _polygonBoolean(left, right, op);
  }
  if (op == BooleanOp.symmetric) {
    throw GeoException(
      'symmetric difference is implemented for polygonal geometries',
    );
  }
  if (op == BooleanOp.union && left is GeoPoint && right is GeoPoint) {
    return GeoMultiPoint([left, right], srid: _resultSrid(left, right));
  }
  if (op == BooleanOp.union &&
      left is GeoLineString &&
      right is GeoLineString) {
    return geoLineMerge(
      GeoMultiLineString([left, right], srid: _resultSrid(left, right)),
    );
  }
  if (left is GeoPoint || right is GeoPoint) {
    return _pointCombine(left, right, op);
  }
  if (left is GeoLineString && right is GeoPolygon) {
    return _linePolygon(left, right, op);
  }
  if (left is GeoPolygon && right is GeoLineString) {
    return _linePolygon(right, left, op, reversed: true);
  }
  if (left is GeoLineString &&
      right is GeoLineString &&
      op == BooleanOp.intersection) {
    return _intersectLines(left, right);
  }
  throw GeoException(
    '${op.name} is not implemented for ${left.type.wktName} and ${right.type.wktName}',
  );
}

GeoGeometry _pointCombine(GeoGeometry left, GeoGeometry right, BooleanOp op) {
  final point = left is GeoPoint ? left : right as GeoPoint;
  final other = identical(point, left) ? right : left;
  final covered = geoLocate(other, point.position!) != GeoLocation.exterior;
  return switch (op) {
    BooleanOp.union => covered
        ? other
        : GeoGeometryCollection(
            [other, point],
            srid: _resultSrid(left, right),
            dimension: left.dimension,
          ),
    BooleanOp.intersection => covered
        ? point
        : GeoPoint.empty(srid: point.srid, dimension: point.dimension),
    BooleanOp.difference => identical(point, left)
        ? (covered
            ? GeoPoint.empty(srid: point.srid, dimension: point.dimension)
            : point)
        : other,
    BooleanOp.symmetric => throw const GeoException(
        'symmetric difference is implemented for polygonal geometries',
      ),
  };
}

GeoGeometry _linePolygon(
  GeoLineString line,
  GeoPolygon polygon,
  BooleanOp op, {
  bool reversed = false,
}) {
  if (op == BooleanOp.intersection ||
      (op == BooleanOp.difference && !reversed)) {
    return _clipLine(line, polygon, keepInside: op == BooleanOp.intersection);
  }
  if (op == BooleanOp.difference && reversed) return polygon;
  if (op == BooleanOp.union) {
    final inside = _clipLine(line, polygon, keepInside: true);
    if (inside.isEmpty) {
      return GeoGeometryCollection(
        [polygon, line],
        srid: _resultSrid(line, polygon),
        dimension: line.dimension,
      );
    }
    final outside = _clipLine(line, polygon, keepInside: false);
    if (outside.isEmpty) return polygon;
    return GeoGeometryCollection(
      [polygon, outside],
      srid: _resultSrid(line, polygon),
      dimension: line.dimension,
    );
  }
  throw const GeoException('line and polygon combination is not supported');
}

bool _isPolygonal(GeoGeometry geometry) => switch (geometry) {
      GeoPolygon _ || GeoMultiPolygon _ => true,
      GeoGeometryCollection collection =>
        collection.geometries.every(_isPolygonal),
      _ => false,
    };

List<GeoPolygon> _flattenPolygons(GeoGeometry geometry) => switch (geometry) {
      GeoPolygon polygon => polygon.isEmpty ? const [] : [polygon],
      GeoMultiPolygon multi => [
          for (final polygon in multi.polygons)
            if (!polygon.isEmpty) polygon,
        ],
      GeoGeometryCollection collection => [
          for (final child in collection.geometries) ..._flattenPolygons(child),
        ],
      _ => const [],
    };

int _resultSrid(GeoGeometry left, GeoGeometry right) =>
    left.srid == 0 ? right.srid : left.srid;

GeoGeometry _emptyOf(GeoGeometry geometry) => switch (geometry.type) {
      GeoGeometryType.point || GeoGeometryType.multiPoint => GeoPoint.empty(
          srid: geometry.srid,
          dimension: geometry.dimension,
        ),
      GeoGeometryType.lineString ||
      GeoGeometryType.multiLineString =>
        GeoLineString.empty(srid: geometry.srid, dimension: geometry.dimension),
      _ => GeoPolygon.empty(srid: geometry.srid, dimension: geometry.dimension),
    };

GeoGeometry _polygonBoolean(
  GeoGeometry left,
  GeoGeometry right,
  BooleanOp op,
) {
  final srid = _resultSrid(left, right);
  final dimension = left.dimension;
  final leftParts = _flattenPolygons(left);
  final rightParts = _flattenPolygons(right);
  final segments = <_Seg>[];
  for (final polygon in [...leftParts, ...rightParts]) {
    segments.addAll(_polygonSegments(polygon));
  }
  final arrangement = _arrange(_nodeSegments(segments, GeoLimits.standard));
  final faces = arrangement.faces;
  final selected = <int>{};
  for (var i = 0; i < faces.length; i++) {
    if (faces[i].area <= 0) continue;
    final probe = _interiorProbe(faces[i].ring);
    if (probe == null) continue;
    final inLeft = _inAny(leftParts, probe);
    final inRight = _inAny(rightParts, probe);
    if (_selected(inLeft, inRight, op)) selected.add(i);
  }
  return _dissolve(arrangement, selected, srid, dimension);
}

bool _inAny(List<GeoPolygon> polygons, GeoCoordinate point) {
  for (final polygon in polygons) {
    if (geoLocate(polygon, point) == GeoLocation.interior) return true;
  }
  return false;
}

bool _selected(bool inLeft, bool inRight, BooleanOp op) => switch (op) {
      BooleanOp.union => inLeft || inRight,
      BooleanOp.intersection => inLeft && inRight,
      BooleanOp.difference => inLeft && !inRight,
      BooleanOp.symmetric => inLeft != inRight,
    };

final class _Seg {
  _Seg(this.start, this.end);
  final GeoCoordinate start;
  final GeoCoordinate end;
}

final class _FaceRing {
  _FaceRing(this.ring, this.area, this.edges);
  final List<GeoCoordinate> ring;
  final double area;
  final List<int> edges;
}

List<_Seg> _polygonSegments(GeoPolygon polygon) {
  final segments = <_Seg>[];
  void add(List<GeoCoordinate> ring) {
    for (var i = 0; i < ring.length - 1; i++) {
      if (!ring[i].equalsExact(ring[i + 1])) {
        segments.add(_Seg(ring[i], ring[i + 1]));
      }
    }
  }

  if (polygon.exterior != null) add(polygon.exterior!.points);
  for (final hole in polygon.holes) {
    add(hole.points);
  }
  return segments;
}

List<_Seg> _nodeSegments(List<_Seg> input, GeoLimits limits) {
  if (input.length > limits.maxOverlayEdges) {
    throw const GeoException('overlay edge limit exceeded');
  }
  final splits = [
    for (final segment in input) <GeoCoordinate>[segment.start, segment.end],
  ];
  for (var i = 0; i < input.length; i++) {
    for (var j = i + 1; j < input.length; j++) {
      final hit = geoSegmentHit(
        input[i].start.x,
        input[i].start.y,
        input[i].end.x,
        input[i].end.y,
        input[j].start.x,
        input[j].start.y,
        input[j].end.x,
        input[j].end.y,
      );
      if (!hit.intersects || hit.point == null) continue;
      splits[i].add(hit.point!);
      splits[j].add(hit.point!);
      if (hit.overlapEnd != null) {
        splits[i].add(hit.overlapEnd!);
        splits[j].add(hit.overlapEnd!);
      }
    }
  }
  final result = <_Seg>[];
  final seen = <String>{};
  for (var i = 0; i < input.length; i++) {
    final points = splits[i];
    points.sort(
      (left, right) => _segmentParameter(input[i].start, input[i].end, left)
          .compareTo(_segmentParameter(input[i].start, input[i].end, right)),
    );
    for (var k = 0; k < points.length - 1; k++) {
      if (points[k].equalsExact(points[k + 1])) continue;
      final key = _undirectedKey(points[k], points[k + 1]);
      if (!seen.add(key)) continue;
      result.add(_Seg(points[k], points[k + 1]));
    }
  }
  if (result.length > limits.maxOverlayEdges) {
    throw const GeoException('overlay edge limit exceeded');
  }
  return result;
}

String _undirectedKey(GeoCoordinate left, GeoCoordinate right) {
  final a = _vertexKey(left);
  final b = _vertexKey(right);
  return a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
}

String _vertexKey(GeoCoordinate coordinate) {
  final data = ByteData(16)
    ..setFloat64(0, coordinate.x)
    ..setFloat64(8, coordinate.y);
  return '${data.getUint64(0)}:${data.getUint64(8)}';
}

final class _HalfEdge {
  _HalfEdge(this.from, this.to, this.x, this.y, this.targetX, this.targetY);
  final int from;
  final int to;
  final double x;
  final double y;
  final double targetX;
  final double targetY;
}

final class _GraphVertex {
  _GraphVertex(this.x, this.y);
  final double x;
  final double y;
  final List<int> outgoing = [];
}

final class _Graph {
  _Graph(this.vertices, this.edges);
  final List<_GraphVertex> vertices;
  final List<_HalfEdge> edges;
}

_Graph _buildGraph(List<_Seg> segments) {
  final index = <String, int>{};
  final vertices = <_GraphVertex>[];
  int add(GeoCoordinate coordinate) {
    final key = _vertexKey(coordinate);
    return index.putIfAbsent(key, () {
      vertices.add(_GraphVertex(coordinate.x, coordinate.y));
      return vertices.length - 1;
    });
  }

  final edges = <_HalfEdge>[];
  for (final segment in segments) {
    final from = add(segment.start);
    final to = add(segment.end);
    if (from == to) continue;
    final start = vertices[from];
    final end = vertices[to];
    final forward = edges.length;
    edges.add(_HalfEdge(from, to, start.x, start.y, end.x, end.y));
    edges.add(_HalfEdge(to, from, end.x, end.y, start.x, start.y));
    vertices[from].outgoing.add(forward);
    vertices[to].outgoing.add(forward + 1);
  }
  for (final vertex in vertices) {
    vertex.outgoing.sort((left, right) {
      final a = edges[left];
      final b = edges[right];
      return _angleCompare(
          vertex.x, vertex.y, a.targetX, a.targetY, b.targetX, b.targetY);
    });
  }
  return _Graph(vertices, edges);
}

int _angleCompare(
  double originX,
  double originY,
  double ax,
  double ay,
  double bx,
  double by,
) {
  // atan2 is a total order around the vertex. Exact orientation is not a
  // valid sort comparator once a vertex has edges in more than one half-plane.
  final left = math.atan2(ay - originY, ax - originX);
  final right = math.atan2(by - originY, bx - originX);
  return left.compareTo(right);
}

final class _Arrangement {
  _Arrangement(this.graph, this.faces);
  final _Graph graph;
  final List<_FaceRing> faces;
}

_Arrangement _arrange(List<_Seg> segments) {
  final graph = _buildGraph(segments);
  int nextOf(int edge) {
    final head = graph.vertices[graph.edges[edge].to];
    final twin = edge ^ 1;
    final at = head.outgoing.indexOf(twin);
    if (at < 0) throw const GeoException('overlay vertex is disconnected');
    return head
        .outgoing[(at - 1 + head.outgoing.length) % head.outgoing.length];
  }

  final used = List<bool>.filled(graph.edges.length, false);
  final faces = <_FaceRing>[];
  for (var start = 0; start < graph.edges.length; start++) {
    if (used[start]) continue;
    final ring = <GeoCoordinate>[];
    final edges = <int>[];
    var edge = start;
    var guard = 0;
    while (guard++ <= graph.edges.length) {
      if (used[edge] && edge != start) break;
      used[edge] = true;
      edges.add(edge);
      final half = graph.edges[edge];
      ring.add(GeoCoordinate(half.x, half.y));
      edge = nextOf(edge);
      if (edge == start) break;
    }
    if (edge != start || ring.length < 3) {
      throw const GeoException('overlay face did not close');
    }
    ring.add(GeoCoordinate(ring.first.x, ring.first.y));
    final area = _signedArea(ring);
    if (area == 0) continue;
    faces.add(_FaceRing(ring, area, edges));
  }
  return _Arrangement(graph, faces);
}

GeoGeometry _dissolve(
  _Arrangement arrangement,
  Set<int> selected,
  int srid,
  GeoDimension dimension,
) {
  if (selected.isEmpty) {
    return GeoPolygon.empty(srid: srid, dimension: dimension);
  }
  final graph = arrangement.graph;
  final faces = arrangement.faces;
  final faceOf = List<int>.filled(graph.edges.length, -1);
  for (var i = 0; i < faces.length; i++) {
    if (faces[i].area <= 0) continue;
    for (final edge in faces[i].edges) {
      if (edge < faceOf.length) faceOf[edge] = i;
    }
  }
  bool boundary(int edge) {
    if (edge < 0 || edge >= faceOf.length) return false;
    final left = faceOf[edge];
    final right = edge ^ 1 < faceOf.length ? faceOf[edge ^ 1] : -1;
    final leftOn = left >= 0 && selected.contains(left);
    final rightOn = right >= 0 && selected.contains(right);
    return leftOn && !rightOn;
  }

  int continuation(int edge) {
    final head = graph.vertices[graph.edges[edge].to];
    final twin = edge ^ 1;
    final at = head.outgoing.indexOf(twin);
    if (at < 0) throw const GeoException('overlay boundary is disconnected');
    for (var step = 1; step <= head.outgoing.length; step++) {
      final candidate = head
          .outgoing[(at - step + head.outgoing.length) % head.outgoing.length];
      if (boundary(candidate)) return candidate;
    }
    throw const GeoException('overlay boundary did not continue');
  }

  final used = <int>{};
  final rings = <List<GeoCoordinate>>[];
  for (var start = 0; start < graph.edges.length; start++) {
    if (!boundary(start) || used.contains(start)) continue;
    final ring = <GeoCoordinate>[];
    var edge = start;
    var guard = 0;
    while (guard++ <= graph.edges.length) {
      if (!used.add(edge)) break;
      final half = graph.edges[edge];
      ring.add(GeoCoordinate(half.x, half.y));
      edge = continuation(edge);
      if (edge == start) break;
    }
    if (edge != start || ring.length < 3) {
      throw const GeoException('overlay result ring did not close');
    }
    ring.add(ring.first);
    rings.add(_withoutConsecutiveDuplicates(ring));
  }
  return _polygonsFromRings(rings, srid, dimension);
}

GeoGeometry _polygonsFromRings(
  List<List<GeoCoordinate>> rings,
  int srid,
  GeoDimension dimension,
) {
  final areas = [for (final ring in rings) _signedArea(ring)];
  final shells = <int>[];
  final holes = <int>[];
  for (var i = 0; i < rings.length; i++) {
    if (areas[i] > 0) shells.add(i);
    if (areas[i] < 0) holes.add(i);
  }
  final attached = <int, List<List<GeoCoordinate>>>{};
  for (final hole in holes) {
    final probe = _interiorProbe(rings[hole]);
    if (probe == null) continue;
    var parent = -1;
    var parentArea = double.infinity;
    for (final shell in shells) {
      if (_ringLocation(probe.x, probe.y, rings[shell]) !=
          GeoLocation.interior) {
        continue;
      }
      final area = areas[shell].abs();
      if (area < parentArea) {
        parent = shell;
        parentArea = area;
      }
    }
    if (parent >= 0) {
      attached.putIfAbsent(parent, () => []).add(rings[hole]);
    }
  }
  final polygons = <GeoPolygon>[
    for (final shell in shells)
      if (rings[shell].length >= 4)
        GeoPolygon(
          exteriorRing: rings[shell],
          holes: attached[shell] ?? const [],
          srid: srid,
          dimension: dimension,
        ),
  ];
  if (polygons.isEmpty) {
    return GeoPolygon.empty(srid: srid, dimension: dimension);
  }
  if (polygons.length == 1) return polygons.single.normalize();
  return GeoMultiPolygon(polygons, srid: srid, dimension: dimension)
      .normalize();
}

List<GeoPolygon> _extractWindingFaces(
  List<List<GeoCoordinate>> rings,
  int srid,
  GeoDimension dimension,
) {
  final segments = <_Seg>[];
  for (final ring in rings) {
    for (var i = 0; i < ring.length - 1; i++) {
      if (!ring[i].equalsExact(ring[i + 1])) {
        segments.add(_Seg(ring[i], ring[i + 1]));
      }
    }
  }
  final faces = _arrange(_nodeSegments(segments, GeoLimits.standard)).faces;
  final polygons = <GeoPolygon>[];
  for (final face in faces) {
    if (face.area <= 0) continue;
    final probe = _interiorProbe(face.ring);
    if (probe == null) continue;
    if (_windingNumber(rings, probe.x, probe.y) == 0) continue;
    final normalized = GeoPolygon(
      exteriorRing: face.ring,
      srid: srid,
      dimension: dimension,
    ).normalize();
    if (normalized is GeoPolygon) polygons.add(normalized);
  }
  return polygons;
}

int _windingNumber(List<List<GeoCoordinate>> rings, double x, double y) {
  var winding = 0;
  for (final ring in rings) {
    for (var i = 0; i < ring.length - 1; i++) {
      final start = ring[i];
      final end = ring[i + 1];
      if (start.y <= y) {
        if (end.y > y &&
            geoOrientation(start.x, start.y, end.x, end.y, x, y) > 0) {
          winding++;
        }
      } else if (end.y <= y &&
          geoOrientation(start.x, start.y, end.x, end.y, x, y) < 0) {
        winding--;
      }
    }
  }
  return winding;
}

GeoGeometry _clipLine(
  GeoLineString line,
  GeoPolygon polygon, {
  required bool keepInside,
}) {
  final kept = <GeoCoordinate>[];
  final lines = <GeoLineString>[];
  void flush() {
    if (kept.length >= 2) {
      lines.add(GeoLineString(List.of(kept),
          srid: line.srid, dimension: line.dimension));
    }
    kept.clear();
  }

  for (var i = 0; i < line.points.length - 1; i++) {
    final start = line.points[i];
    final end = line.points[i + 1];
    final cuts = <GeoCoordinate>[start, end];
    void consider(List<GeoCoordinate> ring) {
      for (var j = 0; j < ring.length - 1; j++) {
        final hit = geoSegmentHit(
          start.x,
          start.y,
          end.x,
          end.y,
          ring[j].x,
          ring[j].y,
          ring[j + 1].x,
          ring[j + 1].y,
        );
        if (hit.point != null) cuts.add(hit.point!);
        if (hit.overlapEnd != null) cuts.add(hit.overlapEnd!);
      }
    }

    if (polygon.exterior != null) consider(polygon.exterior!.points);
    for (final hole in polygon.holes) {
      consider(hole.points);
    }
    cuts.sort(
      (left, right) => _segmentParameter(start, end, left)
          .compareTo(_segmentParameter(start, end, right)),
    );
    for (var j = 0; j < cuts.length - 1; j++) {
      if (cuts[j].equalsExact(cuts[j + 1])) continue;
      final mid = GeoCoordinate(
        (cuts[j].x + cuts[j + 1].x) / 2,
        (cuts[j].y + cuts[j + 1].y) / 2,
      );
      final inside = geoLocate(polygon, mid) != GeoLocation.exterior;
      if (inside != keepInside) {
        flush();
        continue;
      }
      if (kept.isEmpty || !kept.last.equalsExact(cuts[j])) kept.add(cuts[j]);
      kept.add(cuts[j + 1]);
    }
  }
  flush();
  if (lines.isEmpty) {
    return GeoLineString.empty(srid: line.srid, dimension: line.dimension);
  }
  if (lines.length == 1) return lines.single;
  return GeoMultiLineString(lines, srid: line.srid, dimension: line.dimension);
}

GeoGeometry _intersectLines(GeoLineString left, GeoLineString right) {
  final points = <GeoCoordinate>[];
  final overlaps = <GeoLineString>[];
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
      if (!hit.intersects || hit.point == null) continue;
      if (hit.overlap && hit.overlapEnd != null) {
        overlaps.add(GeoLineString(
          [hit.point!, hit.overlapEnd!],
          srid: _resultSrid(left, right),
          dimension: left.dimension,
        ));
      } else if (points.every((point) => !point.equalsExact(hit.point!))) {
        points.add(hit.point!);
      }
    }
  }
  if (overlaps.isEmpty && points.isEmpty) {
    return GeoLineString.empty(srid: left.srid, dimension: left.dimension);
  }
  if (overlaps.isEmpty && points.length == 1) {
    return GeoPoint.xy(points.single.x, points.single.y,
        srid: _resultSrid(left, right));
  }
  if (overlaps.isEmpty) {
    return GeoMultiPoint(
      [for (final point in points) GeoPoint.xy(point.x, point.y)],
      srid: _resultSrid(left, right),
    );
  }
  if (points.isEmpty && overlaps.length == 1) return overlaps.single;
  return GeoGeometryCollection(
    [
      ...overlaps,
      if (points.isNotEmpty)
        GeoMultiPoint(
          [for (final point in points) GeoPoint.xy(point.x, point.y)],
        )
    ],
    srid: _resultSrid(left, right),
    dimension: left.dimension,
  );
}
