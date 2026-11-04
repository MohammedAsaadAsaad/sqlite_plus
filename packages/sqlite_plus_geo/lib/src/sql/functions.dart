part of '../geo_engine.dart';

/// Registers spatial SQL functions on one sqlite_plus connection.
///
/// Scalar `ST_Collect` with two or more arguments builds a collection.
/// `ST_Collect` with one argument is the aggregate. The engine stores one
/// overload per name and argument count, so that split is the registration rule.
abstract final class SqlitePlusGeo {
  /// [database] is a [SqliteDatabase], a [MutableSqliteDatabase], or the
  /// connection's [SqlFunctionRegistry].
  static void register(Object database) {
    final functions = _geoFunctions(database);
    _register(functions);
  }

  /// Names from the spatial SQL list that this package does not register.
  static const unsupported = <String>[
    'ST_Polygonize',
    'ST_AreaSpheroid',
    'ST_DistanceSpheroid for non-points',
  ];
}

SqlFunctionRegistry _geoFunctions(Object database) {
  if (database is SqliteDatabase) return database.functions;
  if (database is MutableSqliteDatabase) return database.functions;
  if (database is SqlFunctionRegistry) return database;
  throw ArgumentError('Expected a sqlite_plus database');
}

void _register(SqlFunctionRegistry functions) {
  void scalar(
      String name, int count, Object? Function(List<Object?> arguments) body) {
    functions.registerScalar(name, count, (arguments) {
      if (arguments.any((value) => value == null)) return null;
      try {
        return body(arguments);
      } on SqlException {
        rethrow;
      } on GeoException catch (error) {
        throw SqlException('$name: ${error.message}');
      }
    }, deterministic: true);
  }

  scalar('ST_Point', 2, (args) => _makeSqlPoint(args, null).toEwkb());
  scalar('ST_Point', 3,
      (args) => _makeSqlPoint(args, _int(args[2], 'ST_Point')).toEwkb());
  scalar('ST_MakePoint', 2, (args) => _makeSqlPoint(args, null).toEwkb());
  scalar('ST_MakePoint', 3, (args) {
    return GeoPoint.xy(_dbl(args[0]), _dbl(args[1]), z: _dbl(args[2])).toEwkb();
  });
  scalar('ST_MakePoint', 4, (args) {
    return GeoPoint.xy(
      _dbl(args[0]),
      _dbl(args[1]),
      z: _dbl(args[2]),
      m: _dbl(args[3]),
    ).toEwkb();
  });
  scalar('ST_GeomFromText', 1, (args) => _textGeom(args[0], null).toEwkb());
  scalar('ST_GeomFromText', 2,
      (args) => _textGeom(args[0], _int(args[1], 'ST_GeomFromText')).toEwkb());
  scalar('ST_GeomFromWKB', 1, (args) => _blobGeom(args[0], null).toEwkb());
  scalar('ST_GeomFromWKB', 2,
      (args) => _blobGeom(args[0], _int(args[1], 'ST_GeomFromWKB')).toEwkb());
  scalar('ST_GeomFromGeoJSON', 1, (args) {
    if (args[0] is! String) {
      throw const SqlException('ST_GeomFromGeoJSON: expected text');
    }
    return GeoGeometry.fromGeoJson(args[0]).toEwkb();
  });
  scalar('ST_MakeLine', -1, (args) {
    if (args.length < 2) {
      throw const SqlException('ST_MakeLine expects at least 2 geometries');
    }
    final points = <GeoCoordinate>[];
    int? srid;
    for (final arg in args) {
      final geometry = _geom(arg);
      srid ??= geometry.srid;
      _requireSameSrid(geometry, GeoPoint.empty(srid: srid));
      points.addAll(geometry.coordinates);
    }
    return GeoLineString(points, srid: srid ?? 0).toEwkb();
  });
  scalar('ST_MakePolygon', 1,
      (args) => _polygonFrom(_geom(args[0]), null).toEwkb());
  scalar('ST_MakePolygon', 2,
      (args) => _polygonFrom(_geom(args[0]), _geom(args[1])).toEwkb());
  scalar('ST_Collect', -1, (args) {
    if (args.length < 2) {
      throw const SqlException(
          'scalar ST_Collect expects at least 2 geometries');
    }
    final parts = [for (final arg in args) _geom(arg)];
    return GeoGeometryCollection(parts, srid: parts.first.srid).toEwkb();
  });
  scalar('ST_AsText', 1, (args) => _geom(args[0]).toWkt());
  scalar('ST_AsEWKT', 1, (args) => _geom(args[0]).toEwkt());
  scalar('ST_AsBinary', 1, (args) => _geom(args[0]).toWkb());
  scalar('ST_AsEWKB', 1, (args) => _geom(args[0]).toEwkb());
  scalar('ST_AsGeoJSON', 1, (args) => jsonEncode(_geom(args[0]).toGeoJson()));
  scalar('ST_GeometryType', 1, (args) => _geom(args[0]).type.wktName);
  scalar('ST_SRID', 1, (args) => _geom(args[0]).srid);
  scalar('ST_SetSRID', 2, (args) {
    return _geom(args[0]).withSrid(_int(args[1], 'ST_SetSRID')).toEwkb();
  });
  scalar('ST_Dimension', 1, (args) => _maxDim(_geom(args[0])));
  scalar('ST_CoordDim', 1, (args) => _geom(args[0]).dimension.coordinateCount);
  scalar('ST_IsEmpty', 1, (args) => _geom(args[0]).isEmpty ? 1 : 0);
  scalar('ST_IsValid', 1, (args) => _geom(args[0]).isValid ? 1 : 0);
  scalar('ST_IsValidReason', 1, (args) => _geom(args[0]).validate().reason);
  scalar('ST_IsSimple', 1, (args) => geoIsSimple(_geom(args[0])) ? 1 : 0);
  scalar('ST_NumGeometries', 1, (args) => _numGeometries(_geom(args[0])));
  scalar('ST_NumPoints', 1, (args) => _geom(args[0]).coordinates.length);
  scalar('ST_NPoints', 1, (args) => _geom(args[0]).coordinates.length);
  scalar(
      'ST_X', 1, (args) => _axis(_geom(args[0]), (coordinate) => coordinate.x));
  scalar(
      'ST_Y', 1, (args) => _axis(_geom(args[0]), (coordinate) => coordinate.y));
  scalar(
      'ST_Z', 1, (args) => _axis(_geom(args[0]), (coordinate) => coordinate.z));
  scalar(
      'ST_M', 1, (args) => _axis(_geom(args[0]), (coordinate) => coordinate.m));
  scalar('ST_Envelope', 1, (args) {
    final geometry = _geom(args[0]);
    final envelope = geometry.envelope;
    if (envelope == null) return GeoPolygon.empty(srid: geometry.srid).toEwkb();
    return envelope.toPolygon(srid: geometry.srid).toEwkb();
  });
  scalar('ST_Boundary', 1, (args) => geoBoundary(_geom(args[0])).toEwkb());
  scalar('ST_Centroid', 1, (args) => geoCentroid(_geom(args[0]))?.toEwkb());
  scalar('ST_PointOnSurface', 1,
      (args) => geoPointOnSurface(_geom(args[0]))?.toEwkb());
  for (final entry in _predicates.entries) {
    scalar(entry.key, 2, (args) {
      final left = _geom(args[0]);
      final right = _geom(args[1]);
      return entry.value(left, right) ? 1 : 0;
    });
  }
  scalar('ST_Relate', 2, (args) => geoRelate(_geom(args[0]), _geom(args[1])));
  scalar('ST_Relate', 3, (args) {
    if (args[2] is! String || (args[2] as String).length != 9) {
      throw const SqlException('ST_Relate pattern must be 9 characters');
    }
    return geoRelateMatches(
            geoRelate(_geom(args[0]), _geom(args[1])), args[2] as String)
        ? 1
        : 0;
  });
  scalar('ST_DWithin', 3, (args) {
    return geoDWithin(_geom(args[0]), _geom(args[1]), _dbl(args[2])) ? 1 : 0;
  });
  scalar('ST_DWithin', 4, (args) {
    final geographic = _bool(args[3]);
    final left = _geom(args[0]);
    final right = _geom(args[1]);
    final distance = _dbl(args[2]);
    if (!geographic) return geoDWithin(left, right, distance) ? 1 : 0;
    return _geographicDWithin(left, right, distance) ? 1 : 0;
  });
  scalar(
      'ST_Distance', 2, (args) => geoDistance(_geom(args[0]), _geom(args[1])));
  scalar('ST_DistanceSphere', 2,
      (args) => _sphereDistance(_geom(args[0]), _geom(args[1])));
  scalar(
      'ST_DistanceSpheroid',
      2,
      (args) =>
          _sphereDistance(_geom(args[0]), _geom(args[1]), ellipsoid: true));
  scalar('ST_Length', 1, (args) => geoLength(_geom(args[0])));
  scalar('ST_Length', 2, (args) {
    final geometry = _geom(args[0]);
    return _bool(args[1]) ? GeoGeodesy.length(geometry) : geoLength(geometry);
  });
  scalar('ST_Area', 1, (args) => geoArea(_geom(args[0])));
  scalar('ST_AreaSphere', 1, (args) => geoSphericalArea(_geom(args[0])));
  scalar('ST_Perimeter', 1, (args) => geoPerimeter(_geom(args[0])));
  scalar('ST_Perimeter', 2, (args) {
    final geometry = _geom(args[0]);
    return _bool(args[1])
        ? GeoGeodesy.length(_boundaryLines(geometry))
        : geoPerimeter(geometry);
  });
  scalar('ST_Azimuth', 2, (args) => _azimuth(_geom(args[0]), _geom(args[1])));
  scalar('ST_Buffer', 2,
      (args) => geoBuffer(_geom(args[0]), _dbl(args[1])).toEwkb());
  scalar('ST_Buffer', 3, (args) {
    return geoBuffer(
      _geom(args[0]),
      _dbl(args[1]),
      parameters:
          GeoBufferParameters(quadrantSegments: _int(args[2], 'ST_Buffer')),
    ).toEwkb();
  });
  scalar('ST_Union', 2,
      (args) => geoUnion(_geom(args[0]), _geom(args[1])).toEwkb());
  scalar('ST_Intersection', 2,
      (args) => geoIntersection(_geom(args[0]), _geom(args[1])).toEwkb());
  scalar('ST_Difference', 2,
      (args) => geoDifference(_geom(args[0]), _geom(args[1])).toEwkb());
  scalar(
      'ST_SymDifference',
      2,
      (args) =>
          geoSymmetricDifference(_geom(args[0]), _geom(args[1])).toEwkb());
  scalar('ST_ConvexHull', 1, (args) => geoConvexHull(_geom(args[0])).toEwkb());
  scalar('ST_ConcaveHull', 2,
      (args) => geoConcaveHull(_geom(args[0]), _dbl(args[1])).toEwkb());
  scalar('ST_Simplify', 2,
      (args) => geoSimplify(_geom(args[0]), _dbl(args[1])).toEwkb());
  scalar('ST_SimplifyPreserveTopology', 2, (args) {
    return geoSimplifyPreserveTopology(_geom(args[0]), _dbl(args[1])).toEwkb();
  });
  scalar(
      'ST_Snap',
      3,
      (args) =>
          geoSnap(_geom(args[0]), _geom(args[1]), _dbl(args[2])).toEwkb());
  scalar('ST_Reverse', 1, (args) => geoReverse(_geom(args[0])).toEwkb());
  scalar('ST_Force2D', 1, (args) => geoForce2d(_geom(args[0])).toEwkb());
  scalar('ST_Force3D', 1, (args) => geoForce3d(_geom(args[0])).toEwkb());
  scalar('ST_Translate', 3, (args) {
    return geoTranslate(_geom(args[0]), _dbl(args[1]), _dbl(args[2])).toEwkb();
  });
  scalar('ST_Translate', 4, (args) {
    return geoTranslate(_geom(args[0]), _dbl(args[1]), _dbl(args[2]),
            dz: _dbl(args[3]))
        .toEwkb();
  });
  scalar(
      'ST_Scale',
      3,
      (args) =>
          geoScale(_geom(args[0]), _dbl(args[1]), _dbl(args[2])).toEwkb());
  scalar('ST_Rotate', 2,
      (args) => geoRotate(_geom(args[0]), _dbl(args[1])).toEwkb());
  scalar('ST_Rotate', 4, (args) {
    return geoRotate(
      _geom(args[0]),
      _dbl(args[1]),
      origin: GeoCoordinate(_dbl(args[2]), _dbl(args[3])),
    ).toEwkb();
  });
  scalar('ST_Transform', 2, (args) {
    return geoTransform(_geom(args[0]),
            targetSrid: _int(args[1], 'ST_Transform'))
        .toEwkb();
  });
  scalar('ST_MakeValid', 1, (args) => geoMakeValid(_geom(args[0])).toEwkb());
  scalar('ST_LineMerge', 1, (args) => geoLineMerge(_geom(args[0])).toEwkb());
  functions.registerAggregate('ST_Collect', 1, _CollectAggregate.new);
  functions.registerAggregate('ST_Union', 1, _UnionAggregate.new);
  functions.registerAggregate('ST_Extent', 1, _ExtentAggregate.new);
}

const _predicates = <String, bool Function(GeoGeometry, GeoGeometry)>{
  'ST_Equals': geoEqualsTopologically,
  'ST_Intersects': geoIntersects,
  'ST_Disjoint': geoDisjoint,
  'ST_Contains': geoContains,
  'ST_Within': geoWithin,
  'ST_Covers': geoCovers,
  'ST_CoveredBy': geoCoveredBy,
  'ST_Touches': geoTouches,
  'ST_Crosses': geoCrosses,
  'ST_Overlaps': geoOverlaps,
};

double _dbl(Object? value) {
  if (value is double) {
    if (!value.isFinite) throw const SqlException('coordinate is not finite');
    return value;
  }
  if (value is int) return value.toDouble();
  if (value is BigInt) {
    final number = value.toDouble();
    if (!number.isFinite || BigInt.from(number) != value) {
      throw const SqlException('integer is not an exact coordinate');
    }
    return number;
  }
  throw const SqlException('expected a number');
}

int _int(Object? value, String name) {
  if (value is BigInt) return value.toInt();
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  throw SqlException('$name: expected an integer');
}

bool _bool(Object? value) {
  if (value is BigInt) return value != BigInt.zero;
  if (value is int) return value != 0;
  if (value is double) return value != 0;
  if (value is String) return value == '1' || value.toLowerCase() == 'true';
  throw const SqlException('expected a boolean flag');
}

GeoGeometry _geom(Object? value) {
  if (value is Uint8List) return GeoGeometry.fromWkb(value);
  throw const SqlException('expected a geometry blob');
}

GeoGeometry _textGeom(Object? value, int? srid) {
  if (value is! String) throw const SqlException('expected WKT text');
  return GeoGeometry.fromWkt(value, srid: srid ?? 0);
}

GeoGeometry _blobGeom(Object? value, int? srid) {
  if (value is! Uint8List) throw const SqlException('expected WKB');
  return GeoGeometry.fromWkb(value, srid: srid);
}

GeoPoint _makeSqlPoint(List<Object?> args, int? srid) =>
    GeoPoint.xy(_dbl(args[0]), _dbl(args[1]), srid: srid ?? 0);

Object? _axis(
    GeoGeometry geometry, double? Function(GeoCoordinate coordinate) read) {
  if (geometry is! GeoPoint || geometry.position == null) return null;
  return read(geometry.position!);
}

int _numGeometries(GeoGeometry geometry) => switch (geometry) {
      GeoPoint _ || GeoLineString _ || GeoPolygon _ => geometry.isEmpty ? 0 : 1,
      GeoMultiPoint multi => multi.points.length,
      GeoMultiLineString multi => multi.lines.length,
      GeoMultiPolygon multi => multi.polygons.length,
      GeoGeometryCollection collection => collection.geometries.length,
    };

GeoPolygon _polygonFrom(GeoGeometry shell, GeoGeometry? holes) {
  if (shell is! GeoLineString) {
    throw const SqlException('ST_MakePolygon expects a line string shell');
  }
  final holeRings = <List<GeoCoordinate>>[];
  if (holes is GeoLineString) holeRings.add(holes.points);
  if (holes is GeoMultiLineString) {
    holeRings.addAll(holes.lines.map((line) => line.points));
  }
  return GeoPolygon(
      exteriorRing: shell.points, holes: holeRings, srid: shell.srid);
}

double _sphereDistance(GeoGeometry left, GeoGeometry right,
    {bool ellipsoid = false}) {
  final a =
      _onlyPoint(left, ellipsoid ? 'ST_DistanceSpheroid' : 'ST_DistanceSphere');
  final b = _onlyPoint(
      right, ellipsoid ? 'ST_DistanceSpheroid' : 'ST_DistanceSphere');
  return GeoGeodesy.distance(
    a,
    b,
    model: ellipsoid ? GeodesicModel.ellipsoid : GeodesicModel.sphere,
  );
}

GeoPoint _onlyPoint(GeoGeometry geometry, String name) {
  if (geometry is! GeoPoint || geometry.isEmpty) {
    throw SqlException('$name is implemented for points');
  }
  return geometry;
}

double? _azimuth(GeoGeometry left, GeoGeometry right) {
  if (left is! GeoPoint || right is! GeoPoint) {
    throw const SqlException('ST_Azimuth is implemented for points');
  }
  if (left.srid == 4326 || left.srid == 0) {
    return GeoGeodesy.azimuth(left, right) * math.pi / 180;
  }
  final dx = right.position!.x - left.position!.x;
  final dy = right.position!.y - left.position!.y;
  return math.atan2(dx, dy);
}

bool _geographicDWithin(GeoGeometry left, GeoGeometry right, double metres) {
  if (metres < 0) {
    throw const SqlException('ST_DWithin distance must be non-negative');
  }
  if (left is! GeoPoint || right is! GeoPoint) {
    throw const SqlException(
      'geographic ST_DWithin is implemented for points; planar ST_DWithin accepts other types',
    );
  }
  return GeoGeodesy.distance(left, right) <= metres;
}

GeoGeometry _boundaryLines(GeoGeometry geometry) => geoBoundary(geometry);

final class _CollectAggregate implements SqlAggregate {
  final _parts = <GeoGeometry>[];

  @override
  void step(List<Object?> arguments) {
    if (arguments.length != 1 || arguments.single == null) return;
    _parts.add(_geom(arguments.single));
  }

  @override
  Object? finish() {
    if (_parts.isEmpty) return null;
    return GeoGeometryCollection(_parts, srid: _parts.first.srid).toEwkb();
  }
}

final class _UnionAggregate implements SqlAggregate {
  GeoGeometry? _value;

  @override
  void step(List<Object?> arguments) {
    if (arguments.length != 1 || arguments.single == null) return;
    final geometry = _geom(arguments.single);
    _value = _value == null ? geometry : geoUnion(_value!, geometry);
  }

  @override
  Object? finish() => _value?.toEwkb();
}

final class _ExtentAggregate implements SqlAggregate {
  GeoEnvelope? _envelope;
  var _srid = 0;

  @override
  void step(List<Object?> arguments) {
    if (arguments.length != 1 || arguments.single == null) return;
    final geometry = _geom(arguments.single);
    final envelope = geometry.envelope;
    if (envelope == null) return;
    _srid = geometry.srid;
    _envelope = _envelope == null
        ? envelope
        : GeoEnvelope(
            minX: math.min(_envelope!.minX, envelope.minX),
            minY: math.min(_envelope!.minY, envelope.minY),
            maxX: math.max(_envelope!.maxX, envelope.maxX),
            maxY: math.max(_envelope!.maxY, envelope.maxY),
          );
  }

  @override
  Object? finish() => _envelope?.toPolygon(srid: _srid).toEwkb();
}
