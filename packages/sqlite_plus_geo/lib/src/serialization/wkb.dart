part of '../geo_engine.dart';

Uint8List _writeWkb(
  GeoGeometry geometry, {
  required Endian endian,
  required bool extended,
}) {
  final buffer = BytesBuilder(copy: false);
  _writeWkbGeometry(
    geometry,
    buffer,
    endian: endian,
    extended: extended,
    includeSrid: extended,
    embedded: false,
  );
  return buffer.toBytes();
}

void _writeWkbGeometry(
  GeoGeometry geometry,
  BytesBuilder buffer, {
  required Endian endian,
  required bool extended,
  required bool includeSrid,
  required bool embedded,
}) {
  if (geometry is GeoPoint && geometry.isEmpty && embedded) {
    throw const GeoException(
      'WKB cannot represent an empty point inside another geometry',
    );
  }
  buffer.addByte(endian == Endian.little ? 1 : 0);
  var code = geometry.type.wkbCode;
  if (extended) {
    if (geometry.dimension.hasZ) code |= 0x80000000;
    if (geometry.dimension.hasM) code |= 0x40000000;
    if (includeSrid) code |= 0x20000000;
  } else {
    code += switch (geometry.dimension) {
      GeoDimension.xy => 0,
      GeoDimension.xyz => 1000,
      GeoDimension.xym => 2000,
      GeoDimension.xyzm => 3000,
    };
  }
  _writeUint32(buffer, code, endian);
  if (extended && includeSrid) _writeUint32(buffer, geometry.srid, endian);
  switch (geometry) {
    case GeoPoint point:
      if (!point.isEmpty) _writeCoordinate(buffer, point.position!, endian);
    case GeoLineString line:
      _writeCoordinateList(buffer, line.points, endian);
    case GeoPolygon polygon:
      if (polygon.isEmpty) {
        _writeUint32(buffer, 0, endian);
      } else {
        _writeUint32(buffer, 1 + polygon.holes.length, endian);
        _writeCoordinateList(buffer, polygon.exterior!.points, endian);
        for (final hole in polygon.holes) {
          _writeCoordinateList(buffer, hole.points, endian);
        }
      }
    case GeoMultiPoint multi:
      _writeUint32(buffer, multi.points.length, endian);
      for (final point in multi.points) {
        _writeWkbGeometry(
          point,
          buffer,
          endian: endian,
          extended: extended,
          includeSrid: false,
          embedded: true,
        );
      }
    case GeoMultiLineString multi:
      _writeUint32(buffer, multi.lines.length, endian);
      for (final line in multi.lines) {
        _writeWkbGeometry(
          line,
          buffer,
          endian: endian,
          extended: extended,
          includeSrid: false,
          embedded: true,
        );
      }
    case GeoMultiPolygon multi:
      _writeUint32(buffer, multi.polygons.length, endian);
      for (final polygon in multi.polygons) {
        _writeWkbGeometry(
          polygon,
          buffer,
          endian: endian,
          extended: extended,
          includeSrid: false,
          embedded: true,
        );
      }
    case GeoGeometryCollection collection:
      _writeUint32(buffer, collection.geometries.length, endian);
      for (final child in collection.geometries) {
        _writeWkbGeometry(
          child,
          buffer,
          endian: endian,
          extended: extended,
          includeSrid: false,
          embedded: true,
        );
      }
  }
}

void _writeCoordinateList(
  BytesBuilder buffer,
  List<GeoCoordinate> points,
  Endian endian,
) {
  _writeUint32(buffer, points.length, endian);
  for (final point in points) {
    _writeCoordinate(buffer, point, endian);
  }
}

void _writeCoordinate(
    BytesBuilder buffer, GeoCoordinate coordinate, Endian endian) {
  _writeFloat64(buffer, coordinate.x, endian);
  _writeFloat64(buffer, coordinate.y, endian);
  if (coordinate.z != null) _writeFloat64(buffer, coordinate.z!, endian);
  if (coordinate.m != null) _writeFloat64(buffer, coordinate.m!, endian);
}

void _writeUint32(BytesBuilder buffer, int value, Endian endian) {
  final data = ByteData(4)..setUint32(0, value, endian);
  buffer.add(data.buffer.asUint8List());
}

void _writeFloat64(BytesBuilder buffer, double value, Endian endian) {
  final data = ByteData(8)..setFloat64(0, value, endian);
  buffer.add(data.buffer.asUint8List());
}

final class _WkbReader {
  _WkbReader(this.bytes, this.fallbackSrid, this.options)
      : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  final int? fallbackSrid;
  final GeoParseOptions options;
  int offset = 0;
  int coordinates = 0;

  GeoGeometry parse() {
    if (bytes.length > options.limits.maxInputBytes) {
      throw GeoParseException(
        'WKB exceeds ${options.limits.maxInputBytes} bytes',
      );
    }
    if (bytes.isEmpty) throw const GeoParseException('WKB is empty');
    final geometry = _readGeometry(0, inheritedSrid: fallbackSrid);
    if (offset != bytes.length) {
      throw const GeoParseException('unexpected trailing WKB');
    }
    return geometry;
  }

  GeoGeometry _readGeometry(int depth, {required int? inheritedSrid}) {
    if (depth > options.limits.maxDepth) {
      throw const GeoParseException('WKB nesting is too deep');
    }
    if (offset >= bytes.length) throw const GeoParseException('truncated WKB');
    final order = bytes[offset];
    offset++;
    final endian = switch (order) {
      0 => Endian.big,
      1 => Endian.little,
      _ => throw const GeoParseException('WKB byte order is not 0 or 1'),
    };
    final raw = _uint32(endian);
    final hasSrid = raw & 0x20000000 != 0;
    final extendedZ = raw & 0x80000000 != 0;
    final extendedM = raw & 0x40000000 != 0;
    var code = raw & 0xffff;
    if (!extendedZ && !extendedM && !hasSrid) {
      code = raw;
    }
    var dimension = GeoDimension.xy;
    if (extendedZ || extendedM) {
      dimension = GeoDimension.fromFlags(z: extendedZ, m: extendedM);
      code = raw & 0xffff;
    } else if (code >= 3000) {
      dimension = GeoDimension.xyzm;
      code -= 3000;
    } else if (code >= 2000) {
      dimension = GeoDimension.xym;
      code -= 2000;
    } else if (code >= 1000) {
      dimension = GeoDimension.xyz;
      code -= 1000;
    }
    int? srid = inheritedSrid;
    if (hasSrid) {
      srid = _uint32(endian);
      _checkSrid(srid);
    }
    srid ??= 0;
    final geometry = switch (code) {
      1 => _point(endian, dimension, srid),
      2 => GeoLineString(
          _coordinates(endian, dimension),
          srid: srid,
          dimension: dimension,
        ),
      3 => _polygon(endian, dimension, srid),
      4 => _multi(endian, dimension, srid, depth, GeoGeometryType.multiPoint),
      5 => _multi(
          endian,
          dimension,
          srid,
          depth,
          GeoGeometryType.multiLineString,
        ),
      6 => _multi(endian, dimension, srid, depth, GeoGeometryType.multiPolygon),
      7 => _collection(endian, dimension, srid, depth),
      _ => throw GeoParseException('unknown WKB type $code'),
    };
    if (options.mode == GeoValidationMode.strict && !geometry.isValid) {
      throw GeoParseException(geometry.validate().reason);
    }
    if (options.mode == GeoValidationMode.repair) return geoMakeValid(geometry);
    return geometry;
  }

  GeoPoint _point(Endian endian, GeoDimension dimension, int srid) {
    if (offset == bytes.length) {
      return GeoPoint.empty(dimension: dimension, srid: srid);
    }
    final needed = dimension.coordinateCount * 8;
    if (bytes.length - offset < needed) {
      throw const GeoParseException('truncated WKB point');
    }
    // A parent count follows a child header only when this point is not the
    // last value. An empty point is the header alone, so a following type
    // byte is not a coordinate. Callers that embed a point consume the
    // coordinates whenever they are present.
    final coordinate = _coordinate(endian, dimension);
    return GeoPoint.xy(
      coordinate.x,
      coordinate.y,
      z: coordinate.z,
      m: coordinate.m,
      srid: srid,
    );
  }

  GeoPolygon _polygon(Endian endian, GeoDimension dimension, int srid) {
    final rings = _uint32(endian);
    if (rings > options.limits.maxRings) {
      throw const GeoParseException('too many polygon rings');
    }
    if (rings == 0) return GeoPolygon.empty(dimension: dimension, srid: srid);
    final exterior = _coordinates(endian, dimension);
    final holes = <List<GeoCoordinate>>[];
    for (var i = 1; i < rings; i++) {
      holes.add(_coordinates(endian, dimension));
    }
    return GeoPolygon(
      exteriorRing: exterior,
      holes: holes,
      srid: srid,
      dimension: dimension,
    );
  }

  GeoGeometry _multi(
    Endian endian,
    GeoDimension dimension,
    int srid,
    int depth,
    GeoGeometryType type,
  ) {
    final count = _uint32(endian);
    if (count > options.limits.maxParts) {
      throw const GeoParseException('too many geometry parts');
    }
    final children = [
      for (var i = 0; i < count; i++)
        _readGeometry(depth + 1, inheritedSrid: srid),
    ];
    return switch (type) {
      GeoGeometryType.multiPoint => GeoMultiPoint(
          [for (final child in children) _asPoint(child)],
          srid: srid,
          dimension: dimension,
        ),
      GeoGeometryType.multiLineString => GeoMultiLineString(
          [for (final child in children) _asLine(child)],
          srid: srid,
          dimension: dimension,
        ),
      GeoGeometryType.multiPolygon => GeoMultiPolygon(
          [for (final child in children) _asPolygon(child)],
          srid: srid,
          dimension: dimension,
        ),
      _ => throw GeoParseException('unexpected multi type ${type.wktName}'),
    };
  }

  GeoGeometryCollection _collection(
    Endian endian,
    GeoDimension dimension,
    int srid,
    int depth,
  ) {
    final count = _uint32(endian);
    if (count > options.limits.maxParts) {
      throw const GeoParseException('too many geometry parts');
    }
    return GeoGeometryCollection(
      [
        for (var i = 0; i < count; i++)
          _readGeometry(depth + 1, inheritedSrid: srid),
      ],
      srid: srid,
      dimension: dimension,
    );
  }

  List<GeoCoordinate> _coordinates(Endian endian, GeoDimension dimension) {
    final count = _uint32(endian);
    if (coordinates + count > options.limits.maxCoordinates) {
      throw const GeoParseException('too many coordinates');
    }
    return [for (var i = 0; i < count; i++) _coordinate(endian, dimension)];
  }

  GeoCoordinate _coordinate(Endian endian, GeoDimension dimension) {
    final x = _float64(endian);
    final y = _float64(endian);
    final z = dimension.hasZ ? _float64(endian) : null;
    final m = dimension.hasM ? _float64(endian) : null;
    coordinates++;
    return GeoCoordinate(x, y, z: z, m: m);
  }

  int _uint32(Endian endian) {
    if (offset + 4 > bytes.length) {
      throw const GeoParseException('truncated WKB');
    }
    final value = data.getUint32(offset, endian);
    offset += 4;
    return value;
  }

  double _float64(Endian endian) {
    if (offset + 8 > bytes.length) {
      throw const GeoParseException('truncated WKB');
    }
    final value = data.getFloat64(offset, endian);
    offset += 8;
    if (!value.isFinite) {
      throw const GeoParseException('WKB coordinate is not finite');
    }
    return value;
  }
}

GeoPoint _asPoint(GeoGeometry geometry) {
  if (geometry is GeoPoint) return geometry;
  throw const GeoParseException('MULTIPOINT member is not a point');
}

GeoLineString _asLine(GeoGeometry geometry) {
  if (geometry is GeoLineString && geometry is! GeoLinearRing) return geometry;
  if (geometry is GeoLinearRing) {
    return GeoLineString(geometry.points, srid: geometry.srid);
  }
  throw const GeoParseException('MULTILINESTRING member is not a line string');
}

GeoPolygon _asPolygon(GeoGeometry geometry) {
  if (geometry is GeoPolygon) return geometry;
  throw const GeoParseException('MULTIPOLYGON member is not a polygon');
}

GeoGeometry _parseWkb(
  Uint8List bytes, {
  required int? srid,
  required GeoParseOptions options,
}) {
  if (srid != null) _checkSrid(srid);
  final geometry = _WkbReader(bytes, srid, options).parse();
  if (srid != null && geometry.srid != 0 && geometry.srid != srid) {
    throw GeoParseException(
      'WKB SRID ${geometry.srid} does not match $srid',
    );
  }
  if (srid != null && geometry.srid == 0) return geometry.withSrid(srid);
  return geometry;
}
