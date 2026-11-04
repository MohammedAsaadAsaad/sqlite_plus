part of '../geo_engine.dart';

/// End cap used by a line buffer. Polygon buffers ignore it.
enum GeoCapStyle {
  /// A semicircle.
  round,

  /// The segment ends flush.
  flat,

  /// The segment ends extended by the buffer distance.
  square,
}

/// Corner style used by a polygon buffer and by a line join.
enum GeoJoinStyle {
  /// A circular arc.
  round,

  /// A sharp corner, limited by [GeoBufferParameters.mitreLimit].
  mitre,

  /// A straight cut between the offset ends.
  bevel,
}

/// Polygonal approximation settings. The result is not a true curve.
final class GeoBufferParameters {
  /// [quadrantSegments] is the number of segments in a quarter circle.
  const GeoBufferParameters({
    this.quadrantSegments = 8,
    this.cap = GeoCapStyle.round,
    this.join = GeoJoinStyle.round,
    this.mitreLimit = 5,
  });

  /// Segments used to approximate a quarter circle. Must be at least 1.
  final int quadrantSegments;

  /// Line end cap.
  final GeoCapStyle cap;

  /// Polygon corner.
  final GeoJoinStyle join;

  /// Longest mitre, as a multiple of the buffer distance.
  final double mitreLimit;
}

/// Polygonal buffer. A negative distance is implemented for polygons only.
/// The output is an approximation; it is not a circular curve.
GeoGeometry geoBuffer(
  GeoGeometry geometry,
  double distance, {
  GeoBufferParameters parameters = const GeoBufferParameters(),
}) {
  if (!distance.isFinite) {
    throw const GeoException('buffer distance is not finite');
  }
  if (parameters.quadrantSegments < 1 || parameters.quadrantSegments > 64) {
    throw const GeoException('quadrant segments must be from 1 to 64');
  }
  if (parameters.mitreLimit < 1) {
    throw const GeoException('mitre limit must be at least 1');
  }
  if (geometry.isEmpty || distance == 0) {
    return distance < 0
        ? GeoPolygon.empty(srid: geometry.srid, dimension: GeoDimension.xy)
        : geoForce2d(geometry);
  }
  if (distance < 0 && geometry is! GeoPolygon && geometry is! GeoMultiPolygon) {
    throw const GeoException('a negative buffer is implemented for polygons');
  }
  return switch (geometry) {
    GeoPoint point =>
      _bufferPoint(point.position!, distance.abs(), parameters, point.srid),
    GeoLineString line => _bufferLine(line, distance.abs(), parameters),
    GeoPolygon polygon => _bufferPolygon(polygon, distance, parameters),
    GeoMultiPoint multi => _unionAll([
        for (final point in multi.points)
          if (!point.isEmpty)
            geoBuffer(point, distance, parameters: parameters),
      ], geometry.srid),
    GeoMultiLineString multi => _unionAll([
        for (final line in multi.lines)
          geoBuffer(line, distance, parameters: parameters),
      ], geometry.srid),
    GeoMultiPolygon multi => _unionAll([
        for (final polygon in multi.polygons)
          geoBuffer(polygon, distance, parameters: parameters),
      ], geometry.srid),
    GeoGeometryCollection collection => _unionAll([
        for (final child in collection.geometries)
          geoBuffer(child, distance, parameters: parameters),
      ], geometry.srid),
  };
}

GeoGeometry _unionAll(List<GeoGeometry> parts, int srid) {
  final present = [
    for (final part in parts)
      if (!part.isEmpty) part
  ];
  if (present.isEmpty) return GeoPolygon.empty(srid: srid);
  var acc = present.first;
  for (final part in present.skip(1)) {
    acc = geoUnion(acc, part);
  }
  return acc;
}

GeoPolygon _bufferPoint(
  GeoCoordinate centre,
  double distance,
  GeoBufferParameters parameters,
  int srid,
) {
  final count = parameters.quadrantSegments * 4;
  final ring = <GeoCoordinate>[
    for (var i = 0; i < count; i++)
      GeoCoordinate(
        centre.x + distance * math.cos(2 * math.pi * i / count),
        centre.y + distance * math.sin(2 * math.pi * i / count),
      ),
  ];
  ring.add(ring.first);
  return GeoPolygon(exteriorRing: ring, srid: srid);
}

GeoGeometry _bufferLine(
  GeoLineString line,
  double distance,
  GeoBufferParameters parameters,
) {
  if (line.points.length < 2) {
    return GeoPolygon.empty(srid: line.srid, dimension: GeoDimension.xy);
  }
  final parts = <GeoPolygon>[];
  for (var i = 0; i < line.points.length - 1; i++) {
    parts.add(_bufferSegment(
        line.points[i], line.points[i + 1], distance, parameters, line.srid));
  }
  return _unionAll(parts, line.srid);
}

GeoPolygon _bufferSegment(
  GeoCoordinate start,
  GeoCoordinate end,
  double distance,
  GeoBufferParameters parameters,
  int srid,
) {
  if (start.equalsExact(end)) {
    return _bufferPoint(start, distance, parameters, srid);
  }
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final length = math.sqrt(dx * dx + dy * dy);
  final ux = dx / length;
  final uy = dy / length;
  final rx = dy / length;
  final ry = -dx / length;
  var leftStart =
      GeoCoordinate(start.x - rx * distance, start.y - ry * distance);
  var leftEnd = GeoCoordinate(end.x - rx * distance, end.y - ry * distance);
  var rightEnd = GeoCoordinate(end.x + rx * distance, end.y + ry * distance);
  var rightStart =
      GeoCoordinate(start.x + rx * distance, start.y + ry * distance);
  if (parameters.cap == GeoCapStyle.square) {
    leftStart =
        GeoCoordinate(leftStart.x - ux * distance, leftStart.y - uy * distance);
    rightStart = GeoCoordinate(
        rightStart.x - ux * distance, rightStart.y - uy * distance);
    leftEnd =
        GeoCoordinate(leftEnd.x + ux * distance, leftEnd.y + uy * distance);
    rightEnd =
        GeoCoordinate(rightEnd.x + ux * distance, rightEnd.y + uy * distance);
  }
  final ring = <GeoCoordinate>[leftStart];
  if (parameters.cap == GeoCapStyle.round) {
    _appendArc(
      ring,
      end,
      math.atan2(leftEnd.y - end.y, leftEnd.x - end.x),
      -math.pi,
      distance,
      parameters.quadrantSegments * 2,
    );
  } else {
    ring.add(leftEnd);
    ring.add(rightEnd);
  }
  if (parameters.cap == GeoCapStyle.round) {
    _appendArc(
      ring,
      start,
      math.atan2(rightStart.y - start.y, rightStart.x - start.x),
      -math.pi,
      distance,
      parameters.quadrantSegments * 2,
    );
  } else {
    ring.add(rightStart);
  }
  ring.add(ring.first);
  return GeoPolygon(exteriorRing: ring, srid: srid);
}

void _appendArc(
  List<GeoCoordinate> ring,
  GeoCoordinate centre,
  double start,
  double sweep,
  double radius,
  int steps,
) {
  final count = math.max(1, steps);
  for (var i = 0; i <= count; i++) {
    final angle = start + sweep * i / count;
    final point = GeoCoordinate(
      centre.x + radius * math.cos(angle),
      centre.y + radius * math.sin(angle),
    );
    if (ring.isEmpty || !ring.last.equalsExact(point)) ring.add(point);
  }
}

GeoGeometry _bufferPolygon(
  GeoPolygon polygon,
  double distance,
  GeoBufferParameters parameters,
) {
  if (polygon.isEmpty || polygon.exterior == null) {
    return GeoPolygon.empty(srid: polygon.srid);
  }
  final prepared = polygon.normalize();
  if (prepared is! GeoPolygon || prepared.exterior == null) return prepared;
  polygon = prepared;
  final shell = _offsetRing(polygon.exterior!.points, distance, parameters);
  if (shell == null) return GeoPolygon.empty(srid: polygon.srid);
  final holes = <List<GeoCoordinate>>[];
  for (final hole in polygon.holes) {
    final shrunk = _offsetRing(hole.points, -distance, parameters);
    if (shrunk != null) holes.add(shrunk);
  }
  final result =
      GeoPolygon(exteriorRing: shell, holes: holes, srid: polygon.srid);
  if (!result.isValid) {
    final repaired = geoMakeValid(result);
    return repaired.isEmpty ? GeoPolygon.empty(srid: polygon.srid) : repaired;
  }
  return result.normalize();
}

List<GeoCoordinate>? _offsetRing(
  List<GeoCoordinate> ring,
  double distance,
  GeoBufferParameters parameters,
) {
  if (ring.length < 4) return null;
  final open = ring.first.equalsExact(ring.last)
      ? ring.sublist(0, ring.length - 1)
      : List.of(ring);
  if (open.length < 3) return null;
  // Positive [distance] offsets to the right of the stored ring. Callers
  // pass a positive value for a CCW shell and a negative value to grow a CW hole.
  final signed = _signedArea(ring) >= 0 ? distance : -distance;
  final result = <GeoCoordinate>[];
  final count = open.length;
  for (var i = 0; i < count; i++) {
    final previous = open[(i - 1 + count) % count];
    final current = open[i];
    final next = open[(i + 1) % count];
    final incoming = _shift(previous, current, signed, atEnd: true);
    final outgoing = _shift(current, next, signed, atEnd: false);
    final turn = geoOrientation(
        previous.x, previous.y, current.x, current.y, next.x, next.y);
    final outwardCorner = turn > 0 && signed > 0 || turn < 0 && signed < 0;
    if (!outwardCorner) {
      final hit = _offsetCorner(previous, current, next, signed);
      result.add(hit ?? incoming);
      continue;
    }
    switch (parameters.join) {
      case GeoJoinStyle.bevel:
        result.add(incoming);
        result.add(outgoing);
      case GeoJoinStyle.mitre:
        final hit = _offsetCorner(previous, current, next, signed);
        if (hit != null &&
            _hypot(hit, current) <= parameters.mitreLimit * signed.abs()) {
          result.add(hit);
        } else {
          result.add(incoming);
          result.add(outgoing);
        }
      case GeoJoinStyle.round:
        final start =
            math.atan2(incoming.y - current.y, incoming.x - current.x);
        final end = math.atan2(outgoing.y - current.y, outgoing.x - current.x);
        var sweep = end - start;
        while (sweep <= -math.pi) {
          sweep += 2 * math.pi;
        }
        while (sweep > math.pi) {
          sweep -= 2 * math.pi;
        }
        _appendArc(
          result,
          current,
          start,
          sweep,
          signed.abs(),
          math.max(
              1,
              (sweep.abs() / (math.pi / 2) * parameters.quadrantSegments)
                  .ceil()),
        );
    }
  }
  if (result.length < 3) return null;
  result.add(result.first);
  final area = _signedArea(result);
  if (signed > 0 && area <= 0) return null;
  if (signed < 0 && area >= 0) return null;
  return result;
}

GeoCoordinate _shift(GeoCoordinate start, GeoCoordinate end, double signed,
    {required bool atEnd}) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  final length = math.sqrt(dx * dx + dy * dy);
  if (length == 0) return atEnd ? end : start;
  final rx = dy / length;
  final ry = -dx / length;
  final base = atEnd ? end : start;
  return GeoCoordinate(base.x + rx * signed, base.y + ry * signed);
}

GeoCoordinate? _offsetCorner(
  GeoCoordinate previous,
  GeoCoordinate current,
  GeoCoordinate next,
  double signed,
) {
  final inDirX = current.x - previous.x;
  final inDirY = current.y - previous.y;
  final outDirX = next.x - current.x;
  final outDirY = next.y - current.y;
  final origin = _shift(previous, current, signed, atEnd: true);
  final other = _shift(current, next, signed, atEnd: false);
  final denominator = inDirX * outDirY - inDirY * outDirX;
  if (denominator == 0) return null;
  final t = ((other.x - origin.x) * outDirY - (other.y - origin.y) * outDirX) /
      denominator;
  return GeoCoordinate(origin.x + t * inDirX, origin.y + t * inDirY);
}
