part of '../geo_engine.dart';

/// A coordinate reference system this package can transform.
final class GeoCrs {
  /// Built-in definitions only. This is not a complete EPSG database.
  const GeoCrs({
    required this.srid,
    required this.name,
    required this.datum,
    required this.ellipsoid,
    required this.axes,
    required this.units,
    required this.areaOfUse,
    required this.projection,
  });

  /// EPSG code.
  final int srid;

  /// English name.
  final String name;

  /// Datum name. Transformations here stay on WGS84.
  final String datum;

  /// Ellipsoid name.
  final String ellipsoid;

  /// Axis order and direction.
  final String axes;

  /// Coordinate unit.
  final String units;

  /// Where the definition is intended to be used.
  final String areaOfUse;

  /// Projection parameters. Geographic CRS use an empty map.
  final Map<String, Object> projection;

  /// Whether coordinates are longitude and latitude in degrees.
  bool get geographic => units == 'degree';
}

/// Built-in CRS lookup. Unsupported codes throw [GeoException].
GeoCrs geoCrs(int srid) {
  if (srid == 4326) return _wgs84;
  if (srid == 3857) return _webMercator;
  if (srid >= 32601 && srid <= 32660) {
    return _utm(srid - 32600, north: true, srid: srid);
  }
  if (srid >= 32701 && srid <= 32760) {
    return _utm(srid - 32700, north: false, srid: srid);
  }
  throw GeoException('CRS $srid is not available');
}

const _wgs84 = GeoCrs(
  srid: 4326,
  name: 'WGS 84',
  datum: 'WGS84',
  ellipsoid: 'WGS84',
  axes: 'longitude, latitude',
  units: 'degree',
  areaOfUse: 'World',
  projection: <String, Object>{},
);

const _webMercator = GeoCrs(
  srid: 3857,
  name: 'WGS 84 / Pseudo-Mercator',
  datum: 'WGS84',
  ellipsoid: 'WGS84 sphere radius 6378137 m',
  axes: 'easting, northing',
  units: 'metre',
  areaOfUse: 'World between about 85.06 degrees south and north',
  projection: <String, Object>{'method': 'web-mercator'},
);

GeoCrs _utm(int zone, {required bool north, required int srid}) {
  final central = (zone - 1) * 6 - 180 + 3;
  return GeoCrs(
    srid: srid,
    name: 'WGS 84 / UTM zone $zone${north ? 'N' : 'S'}',
    datum: 'WGS84',
    ellipsoid: 'WGS84',
    axes: 'easting, northing',
    units: 'metre',
    areaOfUse:
        'Zone $zone, ${central - 3} to ${central + 3} degrees, ${north ? 'northern' : 'southern'} hemisphere. Norway and Svalbard exceptions are not applied.',
    projection: {
      'method': 'transverse-mercator',
      'zone': zone,
      'north': north,
      'latitudeOfOrigin': 0,
      'centralMeridian': central,
      'scaleFactor': 0.9996,
      'falseEasting': 500000,
      'falseNorthing': north ? 0 : 10000000,
    },
  );
}

/// Transforms coordinates. [ST_SetSRID] is not this function: the SRID of the
/// result is [targetSrid] because the numbers changed.
GeoGeometry geoTransform(GeoGeometry geometry, {required int targetSrid}) {
  if (geometry.srid == 0) {
    throw const GeoException('ST_Transform requires a source SRID');
  }
  if (geometry.srid == targetSrid) return geometry;
  final source = geoCrs(geometry.srid);
  final target = geoCrs(targetSrid);
  if (source.datum != 'WGS84' || target.datum != 'WGS84') {
    throw const GeoException('datum transformation is unavailable');
  }
  return _mapTransform(geometry, (coordinate) {
    final geographic =
        source.geographic ? coordinate : _toGeographic(coordinate, source);
    final projected =
        target.geographic ? geographic : _fromGeographic(geographic, target);
    return GeoCoordinate(
      _normalizeAxis(projected.x, target),
      projected.y,
      z: coordinate.z,
      m: coordinate.m,
    );
  }, targetSrid);
}

double _normalizeAxis(double x, GeoCrs crs) =>
    crs.geographic ? _wrapDegrees(x) : x;

GeoCoordinate _toGeographic(GeoCoordinate coordinate, GeoCrs crs) {
  final method = crs.projection['method'];
  if (method == 'web-mercator') return _webMercatorInverse(coordinate);
  if (method == 'transverse-mercator') return _utmInverse(coordinate, crs);
  throw GeoException('inverse projection ${crs.srid} is unavailable');
}

GeoCoordinate _fromGeographic(GeoCoordinate coordinate, GeoCrs crs) {
  final method = crs.projection['method'];
  if (method == 'web-mercator') return _webMercatorForward(coordinate);
  if (method == 'transverse-mercator') return _utmForward(coordinate, crs);
  throw GeoException('forward projection ${crs.srid} is unavailable');
}

const _mercatorLimit = 85.05112877980659;

GeoCoordinate _webMercatorForward(GeoCoordinate coordinate) {
  if (coordinate.y.abs() > _mercatorLimit) {
    throw const GeoException('latitude is outside Web Mercator');
  }
  const radius = 6378137.0;
  final x = coordinate.x * math.pi / 180 * radius;
  final lat = coordinate.y * math.pi / 180;
  final y = radius * math.log(math.tan(math.pi / 4 + lat / 2));
  return GeoCoordinate(x, y);
}

GeoCoordinate _webMercatorInverse(GeoCoordinate coordinate) {
  const radius = 6378137.0;
  final longitude = coordinate.x / radius * 180 / math.pi;
  final latitude =
      (2 * math.atan(math.exp(coordinate.y / radius)) - math.pi / 2) *
          180 /
          math.pi;
  return GeoCoordinate(longitude, latitude);
}

GeoCoordinate _utmForward(GeoCoordinate coordinate, GeoCrs crs) {
  final zone = crs.projection['zone']! as int;
  final north = crs.projection['north']! as bool;
  final lon0 = ((zone - 1) * 6 - 180 + 3) * math.pi / 180;
  final lat = coordinate.y * math.pi / 180;
  final lon = coordinate.x * math.pi / 180;
  const a = GeoGeodesy.semiMajorAxis;
  const f = GeoGeodesy.flattening;
  final e2 = f * (2 - f);
  final ep2 = e2 / (1 - e2);
  const k0 = 0.9996;
  final sinLat = math.sin(lat);
  final cosLat = math.cos(lat);
  final tanLat = math.tan(lat);
  final n = a / math.sqrt(1 - e2 * sinLat * sinLat);
  final t = tanLat * tanLat;
  final c = ep2 * cosLat * cosLat;
  final aa = cosLat * (lon - lon0);
  final m = a *
      ((1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256) * lat -
          (3 * e2 / 8 + 3 * e2 * e2 / 32 + 45 * e2 * e2 * e2 / 1024) *
              math.sin(2 * lat) +
          (15 * e2 * e2 / 256 + 45 * e2 * e2 * e2 / 1024) * math.sin(4 * lat) -
          (35 * e2 * e2 * e2 / 3072) * math.sin(6 * lat));
  final easting = k0 *
          n *
          (aa +
              (1 - t + c) * aa * aa * aa / 6 +
              (5 - 18 * t + t * t + 72 * c - 58 * ep2) *
                  math.pow(aa, 5) /
                  120) +
      500000.0;
  var northing = k0 *
      (m +
          n *
              tanLat *
              (aa * aa / 2 +
                  (5 - t + 9 * c + 4 * c * c) * math.pow(aa, 4) / 24 +
                  (61 - 58 * t + t * t + 600 * c - 330 * ep2) *
                      math.pow(aa, 6) /
                      720));
  if (!north) northing += 10000000;
  return GeoCoordinate(easting, northing, z: coordinate.z, m: coordinate.m);
}

GeoCoordinate _utmInverse(GeoCoordinate coordinate, GeoCrs crs) {
  final zone = crs.projection['zone']! as int;
  final north = crs.projection['north']! as bool;
  final lon0 = ((zone - 1) * 6 - 180 + 3) * math.pi / 180;
  const a = GeoGeodesy.semiMajorAxis;
  const f = GeoGeodesy.flattening;
  final e2 = f * (2 - f);
  final ep2 = e2 / (1 - e2);
  const k0 = 0.9996;
  final x = coordinate.x - 500000;
  var y = coordinate.y;
  if (!north) y -= 10000000;
  final m = y / k0;
  final mu = m / (a * (1 - e2 / 4 - 3 * e2 * e2 / 64 - 5 * e2 * e2 * e2 / 256));
  final e1 = (1 - math.sqrt(1 - e2)) / (1 + math.sqrt(1 - e2));
  final phi1 = mu +
      (3 * e1 / 2 - 27 * math.pow(e1, 3) / 32) * math.sin(2 * mu) +
      (21 * e1 * e1 / 16 - 55 * math.pow(e1, 4) / 32) * math.sin(4 * mu) +
      (151 * math.pow(e1, 3) / 96) * math.sin(6 * mu);
  final sin1 = math.sin(phi1);
  final cos1 = math.cos(phi1);
  final tan1 = math.tan(phi1);
  final n1 = a / math.sqrt(1 - e2 * sin1 * sin1);
  final t1 = tan1 * tan1;
  final c1 = ep2 * cos1 * cos1;
  final r1 = a * (1 - e2) / math.pow(1 - e2 * sin1 * sin1, 1.5);
  final d = x / (n1 * k0);
  final lat = phi1 -
      (n1 * tan1 / r1) *
          (d * d / 2 -
              (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ep2) *
                  math.pow(d, 4) /
                  24 +
              (61 +
                      90 * t1 +
                      298 * c1 +
                      45 * t1 * t1 -
                      252 * ep2 -
                      3 * c1 * c1) *
                  math.pow(d, 6) /
                  720);
  final lon = lon0 +
      (d -
              (1 + 2 * t1 + c1) * math.pow(d, 3) / 6 +
              (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ep2 + 24 * t1 * t1) *
                  math.pow(d, 5) /
                  120) /
          cos1;
  return GeoCoordinate(_toDegrees(lon), _toDegrees(lat),
      z: coordinate.z, m: coordinate.m);
}

GeoGeometry _mapTransform(
  GeoGeometry geometry,
  GeoCoordinate Function(GeoCoordinate coordinate) map,
  int srid,
) {
  final mapped = _mapCoordinates(geometry, map);
  return mapped.withSrid(srid);
}
