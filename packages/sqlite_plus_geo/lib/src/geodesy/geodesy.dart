part of '../geo_engine.dart';

/// WGS84 ellipsoidal and spherical calculations.
///
/// X is longitude and Y is latitude, in degrees. A set SRID other than 0 or
/// 4326 is rejected. Metres are never computed with Euclidean distance.
abstract final class GeoGeodesy {
  /// WGS84 semi-major axis, in metres.
  static const semiMajorAxis = 6378137.0;

  /// WGS84 flattening.
  static const flattening = 1 / 298.257223563;

  /// WGS84 semi-minor axis, in metres.
  static const semiMinorAxis = 6356752.314245;

  /// Authalic sphere radius used by [distance] in [GeodesicModel.sphere], in metres.
  static const sphereRadius = 6371007.180918475;

  /// Distance between two geographic points.
  ///
  /// [DistanceUnit.meters] and [DistanceUnit.kilometers] require
  /// [GeodesicModel.sphere] or [GeodesicModel.ellipsoid]. [DistanceUnit.degrees]
  /// is the Euclidean distance in longitude and latitude and is not a ground
  /// distance.
  static double distance(
    GeoPoint start,
    GeoPoint end, {
    DistanceUnit unit = DistanceUnit.meters,
    GeodesicModel model = GeodesicModel.ellipsoid,
  }) {
    _geographic(start);
    _geographic(end);
    if (unit == DistanceUnit.degrees) {
      if (model != GeodesicModel.planar) {
        throw const GeoException(
          'degree distance is planar and is not a ground distance',
        );
      }
      final dx = start.position!.x - end.position!.x;
      final dy = start.position!.y - end.position!.y;
      return math.sqrt(dx * dx + dy * dy);
    }
    if (model == GeodesicModel.planar) {
      throw const GeoException(
        'planar distance is not metres; choose a sphere or ellipsoid model',
      );
    }
    final metres = model == GeodesicModel.sphere
        ? _haversine(start, end)
        : _vincentyInverse(start, end);
    return unit == DistanceUnit.kilometers ? metres / 1000 : metres;
  }

  /// Initial azimuth from [start] to [end], degrees clockwise from north.
  static double azimuth(GeoPoint start, GeoPoint end) {
    _geographic(start);
    _geographic(end);
    return _vincentyAzimuth(start, end);
  }

  /// Point reached by travelling [distanceMeters] on the initial [bearingDegrees].
  static GeoPoint destination(
    GeoPoint start, {
    required double bearingDegrees,
    required double distanceMeters,
  }) {
    _geographic(start);
    if (!distanceMeters.isFinite || distanceMeters < 0) {
      throw const GeoException('destination distance must be non-negative');
    }
    final result = _vincentyDirect(start, bearingDegrees, distanceMeters);
    return GeoPoint(
      longitude: result.$1,
      latitude: result.$2,
      srid: start.srid == 0 ? 4326 : start.srid,
    );
  }

  /// Sum of ellipsoidal segment lengths. Each line or ring is measured on its
  /// own, so a hole is not joined to the shell by an extra geodesic.
  static double length(GeoGeometry geometry) => switch (geometry) {
        GeoPoint _ || GeoMultiPoint _ => 0,
        GeoLineString line => _path(line.points),
        GeoPolygon polygon => _path(polygon.exterior?.points ?? const []) +
            polygon.holes
                .fold<double>(0, (sum, hole) => sum + _path(hole.points)),
        GeoMultiLineString multi =>
          multi.lines.fold<double>(0, (sum, line) => sum + length(line)),
        GeoMultiPolygon multi => multi.polygons
            .fold<double>(0, (sum, polygon) => sum + length(polygon)),
        GeoGeometryCollection collection => collection.geometries
            .fold<double>(0, (sum, child) => sum + length(child)),
      };

  static double _path(List<GeoCoordinate> points) {
    var total = 0.0;
    for (var i = 1; i < points.length; i++) {
      total += distance(
        GeoPoint(
          longitude: points[i - 1].x,
          latitude: points[i - 1].y,
          srid: 4326,
        ),
        GeoPoint(longitude: points[i].x, latitude: points[i].y, srid: 4326),
      );
    }
    return total;
  }
}

void _geographic(GeoPoint point) {
  if (point.isEmpty || point.position == null) {
    throw const GeoException('empty point has no geographic coordinate');
  }
  if (point.srid != 0 && point.srid != 4326) {
    throw GeoException(
        'geographic distance requires SRID 4326, not ${point.srid}');
  }
  final longitude = point.position!.x;
  final latitude = point.position!.y;
  if (longitude.abs() > 180 || latitude.abs() > 90) {
    throw const GeoException('coordinate is outside longitude/latitude bounds');
  }
}

double _wrapDegrees(double degrees) {
  var value = degrees % 360;
  if (value <= -180) value += 360;
  if (value > 180) value -= 360;
  return value;
}

double _haversine(GeoPoint start, GeoPoint end) {
  final lat1 = start.position!.y * math.pi / 180;
  final lat2 = end.position!.y * math.pi / 180;
  final dLat = lat2 - lat1;
  final dLon =
      _wrapDegrees(end.position!.x - start.position!.x) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * GeoGeodesy.sphereRadius * math.asin(math.min(1, math.sqrt(a)));
}

double _vincentyInverse(GeoPoint start, GeoPoint end) {
  const a = GeoGeodesy.semiMajorAxis;
  const f = GeoGeodesy.flattening;
  const b = GeoGeodesy.semiMinorAxis;
  final lat1 = start.position!.y * math.pi / 180;
  final lat2 = end.position!.y * math.pi / 180;
  final deltaLon =
      _wrapDegrees(end.position!.x - start.position!.x) * math.pi / 180;
  if (deltaLon == 0 && lat1 == lat2) return 0;
  final u1 = math.atan((1 - f) * math.tan(lat1));
  final u2 = math.atan((1 - f) * math.tan(lat2));
  final sinU1 = math.sin(u1);
  final cosU1 = math.cos(u1);
  final sinU2 = math.sin(u2);
  final cosU2 = math.cos(u2);
  var lambda = deltaLon;
  var sigma = 0.0;
  var cos2Alpha = 0.0;
  var cos2SigmaM = 0.0;
  var sinSigma = 0.0;
  var cosSigma = 0.0;
  var converged = false;
  for (var i = 0; i < 100; i++) {
    final sinLambda = math.sin(lambda);
    final cosLambda = math.cos(lambda);
    final y = math.sqrt(
      math.pow(cosU2 * sinLambda, 2) +
          math.pow(cosU1 * sinU2 - sinU1 * cosU2 * cosLambda, 2),
    );
    if (y == 0) return 0;
    sinSigma = y;
    cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda;
    sigma = math.atan2(sinSigma, cosSigma);
    final sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma;
    cos2Alpha = 1 - sinAlpha * sinAlpha;
    cos2SigmaM = cos2Alpha == 0 ? 0 : cosSigma - 2 * sinU1 * sinU2 / cos2Alpha;
    final c = f / 16 * cos2Alpha * (2 + f * (4 - 3 * cos2Alpha));
    final next = deltaLon +
        (1 - c) *
            f *
            sinAlpha *
            (sigma +
                c *
                    sinSigma *
                    (cos2SigmaM +
                        c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));
    if ((next - lambda).abs() < 1e-12) {
      lambda = next;
      converged = true;
      break;
    }
    lambda = next;
  }
  if (!converged) {
    throw const GeoException(
      'ellipsoidal distance did not converge; the points may be nearly antipodal',
    );
  }
  final uSquared = cos2Alpha * (a * a - b * b) / (b * b);
  final bigA = 1 +
      uSquared /
          16384 *
          (4096 + uSquared * (-768 + uSquared * (320 - 175 * uSquared)));
  final bigB = uSquared /
      1024 *
      (256 + uSquared * (-128 + uSquared * (74 - 47 * uSquared)));
  final deltaSigma = bigB *
      sinSigma *
      (cos2SigmaM +
          bigB /
              4 *
              (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
                  bigB /
                      6 *
                      cos2SigmaM *
                      (-3 + 4 * sinSigma * sinSigma) *
                      (-3 + 4 * cos2SigmaM * cos2SigmaM)));
  return b * bigA * (sigma - deltaSigma);
}

double _vincentyAzimuth(GeoPoint start, GeoPoint end) {
  const f = GeoGeodesy.flattening;
  final lat1 = start.position!.y * math.pi / 180;
  final lat2 = end.position!.y * math.pi / 180;
  final deltaLon =
      _wrapDegrees(end.position!.x - start.position!.x) * math.pi / 180;
  final u1 = math.atan((1 - f) * math.tan(lat1));
  final u2 = math.atan((1 - f) * math.tan(lat2));
  var lambda = deltaLon;
  var sinSigma = 0.0;
  var cosSigma = 0.0;
  var cos2SigmaM = 0.0;
  var converged = false;
  for (var i = 0; i < 100; i++) {
    final sinLambda = math.sin(lambda);
    final cosLambda = math.cos(lambda);
    sinSigma = math.sqrt(
      math.pow(math.cos(u2) * sinLambda, 2) +
          math.pow(
            math.cos(u1) * math.sin(u2) -
                math.sin(u1) * math.cos(u2) * cosLambda,
            2,
          ),
    );
    if (sinSigma == 0) return 0;
    cosSigma =
        math.sin(u1) * math.sin(u2) + math.cos(u1) * math.cos(u2) * cosLambda;
    final sinAlpha = math.cos(u1) * math.cos(u2) * sinLambda / sinSigma;
    final cos2Alpha = 1 - sinAlpha * sinAlpha;
    cos2SigmaM = cos2Alpha == 0
        ? 0
        : cosSigma - 2 * math.sin(u1) * math.sin(u2) / cos2Alpha;
    final c = f / 16 * cos2Alpha * (2 + f * (4 - 3 * cos2Alpha));
    final next = deltaLon +
        (1 - c) *
            f *
            sinAlpha *
            (math.atan2(sinSigma, cosSigma) +
                c *
                    sinSigma *
                    (cos2SigmaM +
                        c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));
    if ((next - lambda).abs() < 1e-12) {
      lambda = next;
      converged = true;
      break;
    }
    lambda = next;
  }
  if (!converged) {
    throw const GeoException(
      'ellipsoidal azimuth did not converge; the points may be nearly antipodal',
    );
  }
  final azimuth = math.atan2(
    math.cos(u2) * math.sin(lambda),
    math.cos(u1) * math.sin(u2) -
        math.sin(u1) * math.cos(u2) * math.cos(lambda),
  );
  return (_toDegrees(azimuth) + 360) % 360;
}

(double, double) _vincentyDirect(
    GeoPoint start, double bearingDegrees, double distance) {
  const a = GeoGeodesy.semiMajorAxis;
  const f = GeoGeodesy.flattening;
  const b = GeoGeodesy.semiMinorAxis;
  final lat1 = start.position!.y * math.pi / 180;
  final lon1 = start.position!.x * math.pi / 180;
  final alpha1 = bearingDegrees * math.pi / 180;
  final tanU1 = (1 - f) * math.tan(lat1);
  final cosU1 = 1 / math.sqrt(1 + tanU1 * tanU1);
  final sinU1 = tanU1 * cosU1;
  final sigma1 = math.atan2(tanU1, math.cos(alpha1));
  final sinAlpha = cosU1 * math.sin(alpha1);
  final cos2Alpha = 1 - sinAlpha * sinAlpha;
  final uSquared = cos2Alpha * (a * a - b * b) / (b * b);
  final bigA = 1 +
      uSquared /
          16384 *
          (4096 + uSquared * (-768 + uSquared * (320 - 175 * uSquared)));
  final bigB = uSquared /
      1024 *
      (256 + uSquared * (-128 + uSquared * (74 - 47 * uSquared)));
  var sigma = distance / (b * bigA);
  var cos2SigmaM = 0.0;
  var converged = false;
  for (var i = 0; i < 100; i++) {
    cos2SigmaM = math.cos(2 * sigma1 + sigma);
    final sinSigma = math.sin(sigma);
    final cosSigma = math.cos(sigma);
    final deltaSigma = bigB *
        sinSigma *
        (cos2SigmaM +
            bigB /
                4 *
                (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM) -
                    bigB /
                        6 *
                        cos2SigmaM *
                        (-3 + 4 * sinSigma * sinSigma) *
                        (-3 + 4 * cos2SigmaM * cos2SigmaM)));
    final next = distance / (b * bigA) + deltaSigma;
    if ((next - sigma).abs() < 1e-12) {
      sigma = next;
      converged = true;
      break;
    }
    sigma = next;
  }
  if (!converged) {
    throw const GeoException('ellipsoidal destination did not converge');
  }
  final sinSigma = math.sin(sigma);
  final cosSigma = math.cos(sigma);
  final lat2 = math.atan2(
    sinU1 * cosSigma + cosU1 * sinSigma * math.cos(alpha1),
    (1 - f) *
        math.sqrt(
          sinAlpha * sinAlpha +
              math.pow(
                  sinU1 * sinSigma - cosU1 * cosSigma * math.cos(alpha1), 2),
        ),
  );
  final lambda = math.atan2(
    sinSigma * math.sin(alpha1),
    cosU1 * cosSigma - sinU1 * sinSigma * math.cos(alpha1),
  );
  final c = f / 16 * cos2Alpha * (2 + f * (4 - 3 * cos2Alpha));
  final lon = lon1 +
      lambda -
      (1 - c) *
          f *
          sinAlpha *
          (sigma +
              c *
                  sinSigma *
                  (cos2SigmaM +
                      c * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)));
  return (_wrapDegrees(_toDegrees(lon)), _toDegrees(lat2));
}

double _toDegrees(double radians) => radians * 180 / math.pi;

/// Spherical polygon area on [GeoGeodesy.sphereRadius]. This is not an
/// ellipsoidal area. Holes are subtracted. The longitude delta is wrapped, so
/// a ring that crosses the antimeridian uses the short edge.
double geoSphericalArea(GeoGeometry geometry) {
  double ringArea(List<GeoCoordinate> ring) {
    var total = 0.0;
    for (var i = 0; i < ring.length - 1; i++) {
      final lat1 = ring[i].y * math.pi / 180;
      final lat2 = ring[i + 1].y * math.pi / 180;
      final dLon = _wrapDegrees(ring[i + 1].x - ring[i].x) * math.pi / 180;
      total += dLon * (math.sin(lat1) + math.sin(lat2));
    }
    return total.abs() * GeoGeodesy.sphereRadius * GeoGeodesy.sphereRadius / 2;
  }

  return switch (geometry) {
    GeoPolygon polygon => polygon.isEmpty
        ? 0
        : ringArea(polygon.exterior!.points) -
            polygon.holes
                .fold<double>(0, (sum, hole) => sum + ringArea(hole.points)),
    GeoMultiPolygon multi => multi.polygons
        .fold<double>(0, (sum, polygon) => sum + geoSphericalArea(polygon)),
    _ => throw const GeoException('spherical area is implemented for polygons'),
  };
}
