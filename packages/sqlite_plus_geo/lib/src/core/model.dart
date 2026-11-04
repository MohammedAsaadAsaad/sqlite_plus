part of '../geo_engine.dart';

/// A geometry or parse failure. SQL functions turn this into [SqlException].
final class GeoException implements Exception {
  /// [message] is shown to the caller. It does not include a stack trace.
  const GeoException(this.message);

  /// What failed, in English.
  final String message;

  @override
  String toString() => 'GeoException: $message';
}

/// A WKT, WKB, or GeoJSON value was rejected.
final class GeoParseException extends GeoException {
  /// [offset] is a Dart string index when the source is text.
  const GeoParseException(super.message, {this.offset});

  /// Where parsing stopped, or null for a binary source.
  final int? offset;

  @override
  String toString() =>
      'GeoParseException: $message${offset == null ? '' : ' at $offset'}';
}

/// Caps for one parse or one constructive operation.
final class GeoLimits {
  /// Defaults reject inputs large enough to exhaust a small device.
  const GeoLimits({
    this.maxInputBytes = 8 * 1024 * 1024,
    this.maxCoordinates = 1000000,
    this.maxDepth = 32,
    this.maxParts = 100000,
    this.maxRings = 10000,
    this.maxOverlayEdges = 800,
  });

  /// The limits used when a caller does not pass its own.
  static const standard = GeoLimits();

  /// Largest accepted text or binary source, in bytes.
  final int maxInputBytes;

  /// Largest number of coordinates in one geometry.
  final int maxCoordinates;

  /// Largest nesting depth of a geometry collection.
  final int maxDepth;

  /// Largest number of parts in one collection or multi-geometry.
  final int maxParts;

  /// Largest number of rings in one polygon or multi-polygon.
  final int maxRings;

  /// Largest number of edges accepted by an overlay or buffer.
  final int maxOverlayEdges;
}

/// How a parser treats a structurally invalid geometry.
enum GeoValidationMode {
  /// Reject an unclosed ring, a short ring, or a bad dimension.
  strict,

  /// Build the geometry and leave [GeoGeometry.isValid] false.
  permissive,

  /// Close rings and run [geoMakeValid]. The type may change.
  repair,
}

/// Parser switches. Defaults follow RFC 7946 and reject legacy CRS members.
final class GeoParseOptions {
  /// [limits] and [mode] apply to one parse call.
  const GeoParseOptions({
    this.limits = GeoLimits.standard,
    this.mode = GeoValidationMode.strict,
    this.allowLegacyCrs = false,
  });

  /// Size and depth caps.
  final GeoLimits limits;

  /// What to do with an unclosed ring.
  final GeoValidationMode mode;

  /// When true, a GeoJSON `crs` member is accepted only if it names WGS84
  /// longitude-latitude. Coordinates are never reordered. When false, any
  /// `crs` member is an error.
  final bool allowLegacyCrs;
}

/// Coordinate axes stored on a geometry.
enum GeoDimension {
  /// X and Y. Geographic values are longitude then latitude.
  xy(2, false, false),

  /// X, Y, and Z.
  xyz(3, true, false),

  /// X, Y, and M.
  xym(3, false, true),

  /// X, Y, Z, and M.
  xyzm(4, true, true);

  const GeoDimension(this.coordinateCount, this.hasZ, this.hasM);

  /// Values stored for one position, including only the axes that exist.
  final int coordinateCount;

  /// Whether Z is stored.
  final bool hasZ;

  /// Whether M is stored.
  final bool hasM;

  /// The dimension implied by which optional axes are present.
  static GeoDimension fromFlags({required bool z, required bool m}) {
    if (z && m) return GeoDimension.xyzm;
    if (z) return GeoDimension.xyz;
    if (m) return GeoDimension.xym;
    return GeoDimension.xy;
  }
}

/// OGC geometry kind. A linear ring serializes as a line string.
enum GeoGeometryType {
  /// One position.
  point(1, 'POINT', 'Point'),

  /// A sequence of positions.
  lineString(2, 'LINESTRING', 'LineString'),

  /// One exterior ring and zero or more holes.
  polygon(3, 'POLYGON', 'Polygon'),

  /// Positions that share one SRID.
  multiPoint(4, 'MULTIPOINT', 'MultiPoint'),

  /// Line strings that share one SRID.
  multiLineString(5, 'MULTILINESTRING', 'MultiLineString'),

  /// Polygons that share one SRID.
  multiPolygon(6, 'MULTIPOLYGON', 'MultiPolygon'),

  /// Mixed parts.
  geometryCollection(7, 'GEOMETRYCOLLECTION', 'GeometryCollection');

  const GeoGeometryType(this.wkbCode, this.wktName, this.geoJsonName);

  /// ISO WKB type code without a dimension flag.
  final int wkbCode;

  /// Uppercase WKT name.
  final String wktName;

  /// GeoJSON `type` name.
  final String geoJsonName;

  /// Topological dimension: 0, 1, or 2. A collection uses its parts.
  int get topologicalDimension => switch (this) {
        GeoGeometryType.point || GeoGeometryType.multiPoint => 0,
        GeoGeometryType.lineString || GeoGeometryType.multiLineString => 1,
        GeoGeometryType.polygon || GeoGeometryType.multiPolygon => 2,
        GeoGeometryType.geometryCollection => -1,
      };
}

/// Where a point sits relative to a geometry.
enum GeoLocation {
  /// In the interior.
  interior,

  /// On the boundary.
  boundary,

  /// Outside the geometry.
  exterior,
}

/// One position. X is easting or longitude. Y is northing or latitude.
final class GeoCoordinate {
  /// Rejects a non-finite component. `-0.0` is stored as `0.0`.
  GeoCoordinate(double x, double y, {double? z, double? m})
      : x = _finiteCoordinate(x),
        y = _finiteCoordinate(y),
        z = _optionalCoordinate(z),
        m = _optionalCoordinate(m);

  /// Longitude in [x] and latitude in [y]. Nothing is swapped.
  GeoCoordinate.geographic({
    required double longitude,
    required double latitude,
    double? z,
    double? m,
  }) : this(longitude, latitude, z: z, m: m);

  /// Easting, longitude, or projected X.
  final double x;

  /// Northing, latitude, or projected Y.
  final double y;

  /// Elevation, or null when the position is XY or XYM.
  final double? z;

  /// Measure, or null when the position is XY or XYZ.
  final double? m;

  /// Axes present on this position.
  GeoDimension get dimension =>
      GeoDimension.fromFlags(z: z != null, m: m != null);

  /// Exact axis equality, including null Z or M.
  bool equalsExact(GeoCoordinate other) =>
      x == other.x && y == other.y && z == other.z && m == other.m;

  @override
  bool operator ==(Object other) =>
      other is GeoCoordinate && equalsExact(other);

  @override
  int get hashCode => Object.hash(x, y, z, m);

  @override
  String toString() => 'GeoCoordinate($x, $y, z: $z, m: $m)';
}

double _finiteCoordinate(double value) {
  if (!value.isFinite) {
    throw const GeoException('coordinate is not finite');
  }
  return value == 0 ? 0 : value;
}

double? _optionalCoordinate(double? value) =>
    value == null ? null : _finiteCoordinate(value);

/// Axis-aligned bounds. Empty geometries have no envelope.
final class GeoEnvelope {
  /// [minX] may equal [maxX] for a point or a vertical line.
  GeoEnvelope({
    required double minX,
    required double minY,
    required double maxX,
    required double maxY,
    this.minZ,
    this.maxZ,
    this.minM,
    this.maxM,
  })  : minX = _finiteCoordinate(minX),
        minY = _finiteCoordinate(minY),
        maxX = _finiteCoordinate(maxX),
        maxY = _finiteCoordinate(maxY);

  /// Smallest X.
  final double minX;

  /// Smallest Y.
  final double minY;

  /// Largest X.
  final double maxX;

  /// Largest Y.
  final double maxY;

  /// Smallest Z, or null when Z is absent.
  final double? minZ;

  /// Largest Z, or null when Z is absent.
  final double? maxZ;

  /// Smallest M, or null when M is absent.
  final double? minM;

  /// Largest M, or null when M is absent.
  final double? maxM;

  /// Whether the boxes overlap, including a shared edge.
  bool intersects(GeoEnvelope other) =>
      minX <= other.maxX &&
      maxX >= other.minX &&
      minY <= other.maxY &&
      maxY >= other.minY;

  /// Whether [x], [y] lies inside, including the boundary.
  bool containsCoordinate(double x, double y) =>
      x >= minX && x <= maxX && y >= minY && y <= maxY;

  /// Closed rectangular polygon in the same axis order as the envelope.
  GeoPolygon toPolygon({int srid = 0}) => GeoPolygon(
        exteriorRing: [
          GeoCoordinate(minX, minY),
          GeoCoordinate(maxX, minY),
          GeoCoordinate(maxX, maxY),
          GeoCoordinate(minX, maxY),
          GeoCoordinate(minX, minY),
        ],
        srid: srid,
      );

  /// Bounds of [coordinates], or null when [coordinates] is empty.
  static GeoEnvelope? of(Iterable<GeoCoordinate> coordinates) {
    GeoEnvelope? box;
    for (final coordinate in coordinates) {
      box = box == null
          ? GeoEnvelope(
              minX: coordinate.x,
              minY: coordinate.y,
              maxX: coordinate.x,
              maxY: coordinate.y,
              minZ: coordinate.z,
              maxZ: coordinate.z,
              minM: coordinate.m,
              maxM: coordinate.m,
            )
          : GeoEnvelope(
              minX: math.min(box.minX, coordinate.x),
              minY: math.min(box.minY, coordinate.y),
              maxX: math.max(box.maxX, coordinate.x),
              maxY: math.max(box.maxY, coordinate.y),
              minZ: _minOpt(box.minZ, coordinate.z),
              maxZ: _maxOpt(box.maxZ, coordinate.z),
              minM: _minOpt(box.minM, coordinate.m),
              maxM: _maxOpt(box.maxM, coordinate.m),
            );
    }
    return box;
  }
}

double? _minOpt(double? left, double? right) {
  if (left == null) return right;
  if (right == null) return left;
  return math.min(left, right);
}

double? _maxOpt(double? left, double? right) {
  if (left == null) return right;
  if (right == null) return left;
  return math.max(left, right);
}

/// Result of [GeoGeometry.validate].
final class GeoValidation {
  /// [reason] is `Valid Geometry` when [valid] is true.
  const GeoValidation(this.valid, this.reason);

  /// Whether the geometry satisfies the documented structural rules.
  final bool valid;

  /// A short English reason.
  final String reason;
}

/// Planar or geographic length unit requested by a caller.
enum DistanceUnit {
  /// Metres on a sphere or ellipsoid.
  meters,

  /// Kilometres on a sphere or ellipsoid.
  kilometers,

  /// Euclidean degrees. This is not a ground distance.
  degrees,
}

/// Which distance formula [GeoGeodesy.distance] evaluates.
enum GeodesicModel {
  /// Euclidean distance in the stored axes.
  planar,

  /// Haversine on a documented sphere.
  sphere,

  /// Vincenty on the WGS84 ellipsoid.
  ellipsoid,
}

/// Longitude and latitude for a map widget.
///
/// [longitude] is X and [latitude] is Y. This type does not import a map
/// package. Pass [longitude] and [latitude] to the widget's own point type.
final class GeoMapPosition {
  /// Copies the two axes. Nothing is swapped.
  const GeoMapPosition({required this.longitude, required this.latitude});

  /// X, in degrees, when the source is geographic.
  final double longitude;

  /// Y, in degrees, when the source is geographic.
  final double latitude;

  /// A geographic point. The SRID is metadata and does not move the numbers.
  GeoPoint toPoint({int srid = 4326}) => GeoPoint(
        longitude: longitude,
        latitude: latitude,
        srid: srid,
      );
}

/// Reads a point as longitude, latitude for a map.
extension GeoMapCoordinates on GeoPoint {
  /// Throws when the point is empty. X stays longitude.
  GeoMapPosition toMapPosition() {
    final position = this.position;
    if (position == null) {
      throw const GeoException('empty point has no map position');
    }
    return GeoMapPosition(longitude: position.x, latitude: position.y);
  }
}
