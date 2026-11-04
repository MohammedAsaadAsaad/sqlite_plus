part of '../geo_engine.dart';

/// Immutable geometry. [==] is exact structural equality, not topology.
sealed class GeoGeometry {
  /// Subclasses validate finite coordinates before calling this.
  const GeoGeometry({required this.srid, required this.dimension});

  /// Spatial reference identifier. `0` means the caller did not set one.
  final int srid;

  /// Axes stored on every position.
  final GeoDimension dimension;

  /// OGC kind. A [GeoLinearRing] reports [GeoGeometryType.lineString].
  GeoGeometryType get type;

  /// Whether the geometry has no positions.
  bool get isEmpty;

  /// Bounds of every position, or null when [isEmpty] is true.
  GeoEnvelope? get envelope;

  /// Every position, in part order. Polygon rings include the repeated close.
  Iterable<GeoCoordinate> get coordinates;

  /// Structural check described in `GEOMETRY.md`.
  bool get isValid => validate().valid;

  /// Structural check. This does not repair the geometry.
  GeoValidation validate() => _validateGeometry(this, GeoLimits.standard);

  /// Exact copy with a different SRID. Coordinates do not change.
  GeoGeometry withSrid(int srid);

  /// Counter-clockwise shells and clockwise holes. Part order is kept.
  GeoGeometry normalize() => _normalizeGeometry(this);

  /// WKT. [extended] prefixes `SRID=n;` when [srid] is not zero.
  String toWkt({bool extended = false}) => _writeWkt(this, extended: extended);

  /// EWKT, including `SRID=0;` when the SRID is zero.
  String toEwkt() => _writeWkt(this, extended: true, forceSrid: true);

  /// ISO WKB. An empty point is the 5-byte header documented in `GEOMETRY.md`.
  Uint8List toWkb({Endian endian = Endian.little}) =>
      _writeWkb(this, endian: endian, extended: false);

  /// PostGIS EWKB with the Z, M, and SRID flags.
  Uint8List toEwkb({Endian endian = Endian.little}) =>
      _writeWkb(this, endian: endian, extended: true);

  /// RFC 7946 GeoJSON. M is rejected. No `crs` member is written.
  Map<String, Object?> toGeoJson() => _writeGeoJson(this);

  /// WKT parser. [srid] is metadata unless the text itself is EWKT.
  factory GeoGeometry.fromWkt(
    String wkt, {
    int srid = 0,
    GeoParseOptions options = const GeoParseOptions(),
  }) =>
      _parseWkt(wkt, srid: srid, options: options);

  /// WKB or EWKB parser. An explicit [srid] overrides a missing EWKB SRID.
  factory GeoGeometry.fromWkb(
    Uint8List bytes, {
    int? srid,
    GeoParseOptions options = const GeoParseOptions(),
  }) =>
      _parseWkb(bytes, srid: srid, options: options);

  /// GeoJSON geometry, feature, or feature collection.
  ///
  /// A feature collection becomes a [GeoGeometryCollection]. Coordinates stay
  /// in longitude, latitude order.
  factory GeoGeometry.fromGeoJson(
    Object? json, {
    GeoParseOptions options = const GeoParseOptions(),
  }) =>
      _parseGeoJson(json, options: options);

  /// Exact structural equality, including SRID, dimension, and part order.
  bool equalsExactly(GeoGeometry other);

  @override
  bool operator ==(Object other) =>
      other is GeoGeometry && equalsExactly(other);

  @override
  int get hashCode => Object.hash(
        runtimeType,
        srid,
        dimension,
        Object.hashAll(
          coordinates.map((coordinate) => coordinate.hashCode),
        ),
      );
}

void _checkSrid(int srid) {
  if (srid < 0 || srid > 998999) {
    throw GeoException('SRID $srid is outside 0 to 998999');
  }
}

void _checkDimension(
    Iterable<GeoCoordinate> coordinates, GeoDimension dimension) {
  for (final coordinate in coordinates) {
    if (dimension.hasZ && coordinate.z == null) {
      throw const GeoException('coordinate is missing Z');
    }
    if (dimension.hasM && coordinate.m == null) {
      throw const GeoException('coordinate is missing M');
    }
    if (!dimension.hasZ && coordinate.z != null) {
      throw const GeoException('coordinate has an unexpected Z');
    }
    if (!dimension.hasM && coordinate.m != null) {
      throw const GeoException('coordinate has an unexpected M');
    }
  }
}

GeoDimension _dimensionOf(
    List<GeoCoordinate> coordinates, GeoDimension? given) {
  if (coordinates.isEmpty) return given ?? GeoDimension.xy;
  final dimension = coordinates.first.dimension;
  _checkDimension(coordinates, dimension);
  if (given != null && given != dimension) {
    throw const GeoException('coordinate dimension does not match');
  }
  return dimension;
}

List<GeoCoordinate> _freeze(List<GeoCoordinate> coordinates) =>
    List<GeoCoordinate>.unmodifiable(coordinates);

/// One position, or an empty point.
final class GeoPoint extends GeoGeometry {
  GeoPoint._(this.position, {required super.srid, required super.dimension});

  /// [x] and [y], or [longitude] and [latitude]. The two pairs cannot mix.
  factory GeoPoint({
    double? x,
    double? y,
    double? longitude,
    double? latitude,
    double? z,
    double? m,
    int srid = 0,
  }) {
    if ((x != null && longitude != null) || (y != null && latitude != null)) {
      throw const GeoException(
        'pass x and y, or longitude and latitude, not both',
      );
    }
    final px = x ?? longitude;
    final py = y ?? latitude;
    if (px == null || py == null) {
      throw const GeoException('a point needs x and y');
    }
    final coordinate = GeoCoordinate(px, py, z: z, m: m);
    _checkSrid(srid);
    return GeoPoint._(
      coordinate,
      srid: srid,
      dimension: coordinate.dimension,
    );
  }

  /// Projected or raw axes.
  factory GeoPoint.xy(
    double x,
    double y, {
    double? z,
    double? m,
    int srid = 0,
  }) =>
      GeoPoint(x: x, y: y, z: z, m: m, srid: srid);

  /// An empty point. It has a dimension and an SRID and no position.
  factory GeoPoint.empty({
    GeoDimension dimension = GeoDimension.xy,
    int srid = 0,
  }) {
    _checkSrid(srid);
    return GeoPoint._(null, srid: srid, dimension: dimension);
  }

  /// The only position, or null when empty.
  final GeoCoordinate? position;

  @override
  GeoGeometryType get type => GeoGeometryType.point;

  @override
  bool get isEmpty => position == null;

  @override
  GeoEnvelope? get envelope =>
      position == null ? null : GeoEnvelope.of([position!]);

  @override
  Iterable<GeoCoordinate> get coordinates =>
      position == null ? const [] : [position!];

  @override
  GeoPoint withSrid(int srid) {
    _checkSrid(srid);
    return GeoPoint._(position, srid: srid, dimension: dimension);
  }

  @override
  bool equalsExactly(GeoGeometry other) =>
      other is GeoPoint &&
      srid == other.srid &&
      dimension == other.dimension &&
      (position == null
          ? other.position == null
          : other.position != null && position!.equalsExact(other.position!));
}

/// A sequence of positions. Fewer than two positions is structurally invalid
/// unless the line is empty.
final class GeoLineString extends GeoGeometry {
  GeoLineString._(this.points, {required super.srid, required super.dimension})
      : envelope = GeoEnvelope.of(points);

  /// Copies [points]. An empty list is an empty line.
  factory GeoLineString(
    List<GeoCoordinate> points, {
    int srid = 0,
    GeoDimension? dimension,
  }) {
    _checkSrid(srid);
    final resolved = _dimensionOf(points, dimension);
    return GeoLineString._(_freeze(points), srid: srid, dimension: resolved);
  }

  /// An empty line of [dimension].
  factory GeoLineString.empty({
    GeoDimension dimension = GeoDimension.xy,
    int srid = 0,
  }) =>
      GeoLineString(const [], srid: srid, dimension: dimension);

  /// Positions in order. The list cannot be modified.
  final List<GeoCoordinate> points;

  @override
  final GeoEnvelope? envelope;

  @override
  GeoGeometryType get type => GeoGeometryType.lineString;

  @override
  bool get isEmpty => points.isEmpty;

  @override
  Iterable<GeoCoordinate> get coordinates => points;

  /// Whether the first and last positions are exactly equal.
  bool get isClosed =>
      points.length >= 2 && points.first.equalsExact(points.last);

  @override
  GeoLineString withSrid(int srid) {
    _checkSrid(srid);
    return GeoLineString._(points, srid: srid, dimension: dimension);
  }

  @override
  bool equalsExactly(GeoGeometry other) =>
      other is GeoLineString &&
      other is! GeoLinearRing &&
      srid == other.srid &&
      dimension == other.dimension &&
      _sameCoordinates(points, other.points);
}

/// A closed ring used by [GeoPolygon]. It serializes as a line string.
final class GeoLinearRing extends GeoLineString {
  GeoLinearRing._(
    super.points, {
    required super.srid,
    required super.dimension,
  }) : super._();

  /// Copies [points]. A non-empty ring is invalid until it is closed and has
  /// at least four positions.
  factory GeoLinearRing(
    List<GeoCoordinate> points, {
    int srid = 0,
    GeoDimension? dimension,
  }) {
    _checkSrid(srid);
    final resolved = _dimensionOf(points, dimension);
    return GeoLinearRing._(_freeze(points), srid: srid, dimension: resolved);
  }

  @override
  GeoLinearRing withSrid(int srid) {
    _checkSrid(srid);
    return GeoLinearRing._(points, srid: srid, dimension: dimension);
  }

  @override
  bool equalsExactly(GeoGeometry other) =>
      other is GeoLinearRing &&
      srid == other.srid &&
      dimension == other.dimension &&
      _sameCoordinates(points, other.points);
}

/// One exterior ring and zero or more holes.
final class GeoPolygon extends GeoGeometry {
  GeoPolygon._(
    this.exterior,
    this.holes, {
    required super.srid,
    required super.dimension,
  }) : envelope = exterior == null
            ? null
            : GeoEnvelope.of([
                ...exterior.points,
                for (final hole in holes) ...hole.points,
              ]);

  /// [exteriorRing] null or empty builds an empty polygon.
  /// Holes are stored as given. Validity is reported by [validate].
  factory GeoPolygon({
    List<GeoCoordinate>? exteriorRing,
    List<List<GeoCoordinate>> holes = const [],
    int srid = 0,
    GeoDimension? dimension,
  }) {
    _checkSrid(srid);
    if (exteriorRing == null || exteriorRing.isEmpty) {
      if (holes.isNotEmpty) {
        throw const GeoException('an empty polygon cannot contain a hole');
      }
      return GeoPolygon._(
        null,
        const [],
        srid: srid,
        dimension: dimension ?? GeoDimension.xy,
      );
    }
    final resolved = _dimensionOf(exteriorRing, dimension);
    for (final hole in holes) {
      _checkDimension(hole, resolved);
    }
    return GeoPolygon._(
      GeoLinearRing._(_freeze(exteriorRing), srid: srid, dimension: resolved),
      List<GeoLinearRing>.unmodifiable([
        for (final hole in holes)
          GeoLinearRing._(_freeze(hole), srid: srid, dimension: resolved),
      ]),
      srid: srid,
      dimension: resolved,
    );
  }

  /// An empty polygon.
  factory GeoPolygon.empty({
    GeoDimension dimension = GeoDimension.xy,
    int srid = 0,
  }) =>
      GeoPolygon(srid: srid, dimension: dimension);

  /// Exterior ring, or null when empty.
  final GeoLinearRing? exterior;

  /// Hole rings. Each is clockwise after [normalize].
  final List<GeoLinearRing> holes;

  @override
  final GeoEnvelope? envelope;

  @override
  GeoGeometryType get type => GeoGeometryType.polygon;

  @override
  bool get isEmpty => exterior == null;

  @override
  Iterable<GeoCoordinate> get coordinates => [
        if (exterior != null) ...exterior!.points,
        for (final hole in holes) ...hole.points,
      ];

  @override
  GeoPolygon withSrid(int srid) {
    _checkSrid(srid);
    return GeoPolygon._(
      exterior?.withSrid(srid),
      [for (final hole in holes) hole.withSrid(srid)],
      srid: srid,
      dimension: dimension,
    );
  }

  @override
  bool equalsExactly(GeoGeometry other) =>
      other is GeoPolygon &&
      srid == other.srid &&
      dimension == other.dimension &&
      _sameRing(exterior, other.exterior) &&
      holes.length == other.holes.length &&
      [
        for (var i = 0; i < holes.length; i++)
          if (!_sameCoordinates(holes[i].points, other.holes[i].points)) false,
      ].isEmpty;
}

/// Several points.
final class GeoMultiPoint extends GeoGeometry {
  GeoMultiPoint._(this.points, {required super.srid, required super.dimension})
      : envelope = GeoEnvelope.of([
          for (final point in points)
            if (point.position != null) point.position!,
        ]);

  /// Copies [points] and requires one SRID and one dimension.
  factory GeoMultiPoint(
    List<GeoPoint> points, {
    int srid = 0,
    GeoDimension? dimension,
  }) {
    _checkSrid(srid);
    final resolved = _sharedDimension(
      points,
      dimension,
      empty: GeoDimension.xy,
    );
    _sharedSrid(points, srid);
    return GeoMultiPoint._(
      List<GeoPoint>.unmodifiable(points),
      srid: srid,
      dimension: resolved,
    );
  }

  /// The points, including empty members.
  final List<GeoPoint> points;

  @override
  final GeoEnvelope? envelope;

  @override
  GeoGeometryType get type => GeoGeometryType.multiPoint;

  @override
  bool get isEmpty => points.every((point) => point.isEmpty);

  @override
  Iterable<GeoCoordinate> get coordinates =>
      points.expand((point) => point.coordinates);

  @override
  GeoMultiPoint withSrid(int srid) {
    _checkSrid(srid);
    return GeoMultiPoint._(
      [for (final point in points) point.withSrid(srid)],
      srid: srid,
      dimension: dimension,
    );
  }

  @override
  bool equalsExactly(GeoGeometry other) =>
      other is GeoMultiPoint &&
      srid == other.srid &&
      dimension == other.dimension &&
      points.length == other.points.length &&
      [
        for (var i = 0; i < points.length; i++)
          if (!points[i].equalsExactly(other.points[i])) false,
      ].isEmpty;
}

/// Several line strings.
final class GeoMultiLineString extends GeoGeometry {
  GeoMultiLineString._(
    this.lines, {
    required super.srid,
    required super.dimension,
  }) : envelope = GeoEnvelope.of(lines.expand((line) => line.points));

  /// Copies [lines].
  factory GeoMultiLineString(
    List<GeoLineString> lines, {
    int srid = 0,
    GeoDimension? dimension,
  }) {
    _checkSrid(srid);
    final resolved = _sharedDimension(lines, dimension, empty: GeoDimension.xy);
    _sharedSrid(lines, srid);
    return GeoMultiLineString._(
      List<GeoLineString>.unmodifiable(lines),
      srid: srid,
      dimension: resolved,
    );
  }

  /// The member lines.
  final List<GeoLineString> lines;

  @override
  final GeoEnvelope? envelope;

  @override
  GeoGeometryType get type => GeoGeometryType.multiLineString;

  @override
  bool get isEmpty => lines.every((line) => line.isEmpty);

  @override
  Iterable<GeoCoordinate> get coordinates =>
      lines.expand((line) => line.points);

  @override
  GeoMultiLineString withSrid(int srid) {
    _checkSrid(srid);
    return GeoMultiLineString._(
      [for (final line in lines) line.withSrid(srid)],
      srid: srid,
      dimension: dimension,
    );
  }

  @override
  bool equalsExactly(GeoGeometry other) =>
      other is GeoMultiLineString &&
      srid == other.srid &&
      dimension == other.dimension &&
      lines.length == other.lines.length &&
      [
        for (var i = 0; i < lines.length; i++)
          if (!lines[i].equalsExactly(other.lines[i])) false,
      ].isEmpty;
}

/// Several polygons.
final class GeoMultiPolygon extends GeoGeometry {
  GeoMultiPolygon._(
    this.polygons, {
    required super.srid,
    required super.dimension,
  }) : envelope =
            GeoEnvelope.of(polygons.expand((polygon) => polygon.coordinates));

  /// Copies [polygons].
  factory GeoMultiPolygon(
    List<GeoPolygon> polygons, {
    int srid = 0,
    GeoDimension? dimension,
  }) {
    _checkSrid(srid);
    final resolved =
        _sharedDimension(polygons, dimension, empty: GeoDimension.xy);
    _sharedSrid(polygons, srid);
    return GeoMultiPolygon._(
      List<GeoPolygon>.unmodifiable(polygons),
      srid: srid,
      dimension: resolved,
    );
  }

  /// The member polygons.
  final List<GeoPolygon> polygons;

  @override
  final GeoEnvelope? envelope;

  @override
  GeoGeometryType get type => GeoGeometryType.multiPolygon;

  @override
  bool get isEmpty => polygons.every((polygon) => polygon.isEmpty);

  @override
  Iterable<GeoCoordinate> get coordinates =>
      polygons.expand((polygon) => polygon.coordinates);

  @override
  GeoMultiPolygon withSrid(int srid) {
    _checkSrid(srid);
    return GeoMultiPolygon._(
      [for (final polygon in polygons) polygon.withSrid(srid)],
      srid: srid,
      dimension: dimension,
    );
  }

  @override
  bool equalsExactly(GeoGeometry other) =>
      other is GeoMultiPolygon &&
      srid == other.srid &&
      dimension == other.dimension &&
      polygons.length == other.polygons.length &&
      [
        for (var i = 0; i < polygons.length; i++)
          if (!polygons[i].equalsExactly(other.polygons[i])) false,
      ].isEmpty;
}

/// Mixed geometry parts.
final class GeoGeometryCollection extends GeoGeometry {
  GeoGeometryCollection._(
    this.geometries, {
    required super.srid,
    required super.dimension,
  }) : envelope = GeoEnvelope.of(
            geometries.expand((geometry) => geometry.coordinates));

  /// Copies [geometries].
  factory GeoGeometryCollection(
    List<GeoGeometry> geometries, {
    int srid = 0,
    GeoDimension? dimension,
  }) {
    _checkSrid(srid);
    final resolved =
        _sharedDimension(geometries, dimension, empty: GeoDimension.xy);
    _sharedSrid(geometries, srid);
    return GeoGeometryCollection._(
      List<GeoGeometry>.unmodifiable(geometries),
      srid: srid,
      dimension: resolved,
    );
  }

  /// The parts, in order.
  final List<GeoGeometry> geometries;

  @override
  final GeoEnvelope? envelope;

  @override
  GeoGeometryType get type => GeoGeometryType.geometryCollection;

  @override
  bool get isEmpty => geometries.every((geometry) => geometry.isEmpty);

  @override
  Iterable<GeoCoordinate> get coordinates =>
      geometries.expand((geometry) => geometry.coordinates);

  @override
  GeoGeometryCollection withSrid(int srid) {
    _checkSrid(srid);
    return GeoGeometryCollection._(
      [for (final geometry in geometries) geometry.withSrid(srid)],
      srid: srid,
      dimension: dimension,
    );
  }

  @override
  bool equalsExactly(GeoGeometry other) =>
      other is GeoGeometryCollection &&
      srid == other.srid &&
      dimension == other.dimension &&
      geometries.length == other.geometries.length &&
      [
        for (var i = 0; i < geometries.length; i++)
          if (!geometries[i].equalsExactly(other.geometries[i])) false,
      ].isEmpty;
}

bool _sameCoordinates(List<GeoCoordinate> left, List<GeoCoordinate> right) {
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (!left[i].equalsExact(right[i])) return false;
  }
  return true;
}

bool _sameRing(GeoLinearRing? left, GeoLinearRing? right) {
  if (left == null || right == null) return left == null && right == null;
  return _sameCoordinates(left.points, right.points);
}

GeoDimension _sharedDimension(
  List<GeoGeometry> geometries,
  GeoDimension? given, {
  required GeoDimension empty,
}) {
  var resolved = given;
  for (final geometry in geometries) {
    if (geometry.isEmpty && geometry.coordinates.isEmpty) {
      resolved ??= geometry.dimension;
      if (geometry.dimension != (resolved)) {
        throw const GeoException('geometry dimensions differ');
      }
      continue;
    }
    resolved ??= geometry.dimension;
    if (geometry.dimension != resolved) {
      throw const GeoException('geometry dimensions differ');
    }
  }
  return resolved ?? empty;
}

void _sharedSrid(List<GeoGeometry> geometries, int srid) {
  for (final geometry in geometries) {
    if (geometry.srid != 0 && geometry.srid != srid && srid != 0) {
      throw const GeoException('geometry SRIDs differ');
    }
  }
}

int _countCoordinates(GeoGeometry geometry) => geometry.coordinates.length;
