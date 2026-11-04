part of '../geo_engine.dart';

/// Signed magnitude times a power of two. The value is [mag] * 2^[exp].
final class _Dyadic {
  const _Dyadic(this.mag, this.exp);

  final BigInt mag;
  final int exp;

  static _Dyadic of(double value) {
    if (value == 0) return _Dyadic(BigInt.zero, 0);
    final data = ByteData(8)..setFloat64(0, value);
    final bits = data.getUint64(0);
    final sign = (bits >> 63) == 0 ? BigInt.one : -BigInt.one;
    final biased = (bits >> 52) & 0x7ff;
    final fraction = bits & 0xfffffffffffff;
    if (biased == 0x7ff) {
      throw const GeoException('coordinate is not finite');
    }
    if (biased == 0) {
      return _Dyadic(sign * BigInt.from(fraction), 1 - 1023 - 52);
    }
    return _Dyadic(
      sign * ((BigInt.one << 52) + BigInt.from(fraction)),
      biased - 1023 - 52,
    );
  }

  _Dyadic operator +(_Dyadic other) {
    if (mag == BigInt.zero) return other;
    if (other.mag == BigInt.zero) return this;
    if (exp == other.exp) return _Dyadic(mag + other.mag, exp);
    if (exp > other.exp) {
      return _Dyadic((mag << (exp - other.exp)) + other.mag, other.exp);
    }
    return _Dyadic(mag + (other.mag << (other.exp - exp)), exp);
  }

  _Dyadic operator -(_Dyadic other) => this + _Dyadic(-other.mag, other.exp);

  _Dyadic operator *(_Dyadic other) =>
      _Dyadic(mag * other.mag, exp + other.exp);
}

/// Exact sign of the 2D cross product `(b - a) × (c - a)`.
///
/// Positive is counter-clockwise, negative is clockwise, and zero is collinear.
/// The sign is computed from the IEEE-754 values as dyadic rationals, so a
/// near-zero double cross product is not treated as zero.
int geoOrientation(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
) {
  final exact =
      (_Dyadic.of(bx) - _Dyadic.of(ax)) * (_Dyadic.of(cy) - _Dyadic.of(ay)) -
          (_Dyadic.of(by) - _Dyadic.of(ay)) * (_Dyadic.of(cx) - _Dyadic.of(ax));
  return exact.mag.sign;
}

/// Whether [px], [py] lies on the closed segment from [ax], [ay] to [bx], [by].
bool geoPointOnSegment(
  double ax,
  double ay,
  double bx,
  double by,
  double px,
  double py,
) {
  if (geoOrientation(ax, ay, bx, by, px, py) != 0) return false;
  final minX = math.min(ax, bx);
  final maxX = math.max(ax, bx);
  final minY = math.min(ay, by);
  final maxY = math.max(ay, by);
  return px >= minX && px <= maxX && py >= minY && py <= maxY;
}

/// Intersection of two closed segments.
final class SegmentHit {
  /// [proper] is an interior crossing. [overlap] is a collinear shared span.
  const SegmentHit({
    required this.intersects,
    required this.proper,
    required this.overlap,
    this.point,
    this.overlapEnd,
  });

  /// No shared point.
  static const none =
      SegmentHit(intersects: false, proper: false, overlap: false);

  /// Whether the closed segments share a point.
  final bool intersects;

  /// Whether the open segments cross.
  final bool proper;

  /// Whether the segments overlap on more than one point.
  final bool overlap;

  /// One shared point, when there is one.
  final GeoCoordinate? point;

  /// The other end of a collinear overlap.
  final GeoCoordinate? overlapEnd;
}

/// Exact segment relation. A touch at an endpoint counts as an intersection.
SegmentHit geoSegmentHit(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double dx,
  double dy,
) {
  final o1 = geoOrientation(ax, ay, bx, by, cx, cy);
  final o2 = geoOrientation(ax, ay, bx, by, dx, dy);
  final o3 = geoOrientation(cx, cy, dx, dy, ax, ay);
  final o4 = geoOrientation(cx, cy, dx, dy, bx, by);
  if (o1 == 0 && o2 == 0 && o3 == 0 && o4 == 0) {
    return _collinearHit(ax, ay, bx, by, cx, cy, dx, dy);
  }
  if (o1 * o2 < 0 && o3 * o4 < 0) {
    return SegmentHit(
      intersects: true,
      proper: true,
      overlap: false,
      point: _properIntersection(ax, ay, bx, by, cx, cy, dx, dy),
    );
  }
  final touches = <GeoCoordinate>[];
  if (o1 == 0 && geoPointOnSegment(ax, ay, bx, by, cx, cy)) {
    touches.add(GeoCoordinate(cx, cy));
  }
  if (o2 == 0 && geoPointOnSegment(ax, ay, bx, by, dx, dy)) {
    touches.add(GeoCoordinate(dx, dy));
  }
  if (o3 == 0 && geoPointOnSegment(cx, cy, dx, dy, ax, ay)) {
    touches.add(GeoCoordinate(ax, ay));
  }
  if (o4 == 0 && geoPointOnSegment(cx, cy, dx, dy, bx, by)) {
    touches.add(GeoCoordinate(bx, by));
  }
  if (touches.isEmpty) return SegmentHit.none;
  return SegmentHit(
    intersects: true,
    proper: false,
    overlap: false,
    point: touches.first,
  );
}

SegmentHit _collinearHit(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double dx,
  double dy,
) {
  final points = <GeoCoordinate>[];
  void add(double x, double y) {
    final coordinate = GeoCoordinate(x, y);
    if (points.every((item) => !item.equalsExact(coordinate))) {
      points.add(coordinate);
    }
  }

  if (geoPointOnSegment(ax, ay, bx, by, cx, cy)) add(cx, cy);
  if (geoPointOnSegment(ax, ay, bx, by, dx, dy)) add(dx, dy);
  if (geoPointOnSegment(cx, cy, dx, dy, ax, ay)) add(ax, ay);
  if (geoPointOnSegment(cx, cy, dx, dy, bx, by)) add(bx, by);
  if (points.isEmpty) return SegmentHit.none;
  if (points.length == 1) {
    return SegmentHit(
      intersects: true,
      proper: false,
      overlap: false,
      point: points.first,
    );
  }
  return SegmentHit(
    intersects: true,
    proper: false,
    overlap: true,
    point: points.first,
    overlapEnd: points[1],
  );
}

GeoCoordinate _properIntersection(
  double ax,
  double ay,
  double bx,
  double by,
  double cx,
  double cy,
  double dx,
  double dy,
) {
  final d1x = bx - ax;
  final d1y = by - ay;
  final d2x = dx - cx;
  final d2y = dy - cy;
  final denominator = d1x * d2y - d1y * d2x;
  if (denominator == 0) {
    throw const GeoException('segment intersection is undefined');
  }
  final t = ((cx - ax) * d2y - (cy - ay) * d2x) / denominator;
  return GeoCoordinate(ax + t * d1x, ay + t * d1y);
}

/// Parameter of [point] along the segment, using the longer axis.
double _segmentParameter(
  GeoCoordinate start,
  GeoCoordinate end,
  GeoCoordinate point,
) {
  final dx = end.x - start.x;
  final dy = end.y - start.y;
  if (dx.abs() >= dy.abs()) {
    if (dx == 0) return 0;
    return (point.x - start.x) / dx;
  }
  return (point.y - start.y) / dy;
}
