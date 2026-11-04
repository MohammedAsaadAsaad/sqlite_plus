part of '../geo_engine.dart';

String _writeWkt(
  GeoGeometry geometry, {
  required bool extended,
  bool forceSrid = false,
}) {
  final buffer = StringBuffer();
  if (extended && (forceSrid || geometry.srid != 0)) {
    buffer.write('SRID=${geometry.srid};');
  }
  _writeWktBody(geometry, buffer);
  return buffer.toString();
}

void _writeWktBody(GeoGeometry geometry, StringBuffer buffer) {
  buffer.write(geometry.type.wktName);
  final suffix = switch (geometry.dimension) {
    GeoDimension.xy => '',
    GeoDimension.xyz => ' Z',
    GeoDimension.xym => ' M',
    GeoDimension.xyzm => ' ZM',
  };
  buffer.write(suffix);
  if (geometry.isEmpty) {
    buffer.write(' EMPTY');
    return;
  }
  buffer.write(' ');
  switch (geometry) {
    case GeoPoint point:
      buffer.write('(');
      _writePosition(point.position!, buffer);
      buffer.write(')');
    case GeoLineString line:
      _writePositions(line.points, buffer);
    case GeoPolygon polygon:
      buffer.write('(');
      _writePositions(polygon.exterior!.points, buffer);
      for (final hole in polygon.holes) {
        buffer.write(', ');
        _writePositions(hole.points, buffer);
      }
      buffer.write(')');
    case GeoMultiPoint multi:
      buffer.write('(');
      for (var i = 0; i < multi.points.length; i++) {
        if (i > 0) buffer.write(', ');
        final point = multi.points[i];
        if (point.isEmpty) {
          buffer.write('EMPTY');
        } else {
          buffer.write('(');
          _writePosition(point.position!, buffer);
          buffer.write(')');
        }
      }
      buffer.write(')');
    case GeoMultiLineString multi:
      buffer.write('(');
      for (var i = 0; i < multi.lines.length; i++) {
        if (i > 0) buffer.write(', ');
        if (multi.lines[i].isEmpty) {
          buffer.write('EMPTY');
        } else {
          _writePositions(multi.lines[i].points, buffer);
        }
      }
      buffer.write(')');
    case GeoMultiPolygon multi:
      buffer.write('(');
      for (var i = 0; i < multi.polygons.length; i++) {
        if (i > 0) buffer.write(', ');
        buffer.write(_innerPolygon(multi.polygons[i]));
      }
      buffer.write(')');
    case GeoGeometryCollection collection:
      buffer.write('(');
      for (var i = 0; i < collection.geometries.length; i++) {
        if (i > 0) buffer.write(', ');
        _writeWktBody(collection.geometries[i], buffer);
      }
      buffer.write(')');
  }
}

String _innerPolygon(GeoPolygon polygon) {
  if (polygon.isEmpty) return 'EMPTY';
  final buffer = StringBuffer('(');
  _writePositions(polygon.exterior!.points, buffer);
  for (final hole in polygon.holes) {
    buffer.write(', ');
    _writePositions(hole.points, buffer);
  }
  buffer.write(')');
  return buffer.toString();
}

void _writePositions(List<GeoCoordinate> points, StringBuffer buffer) {
  buffer.write('(');
  for (var i = 0; i < points.length; i++) {
    if (i > 0) buffer.write(', ');
    _writePosition(points[i], buffer);
  }
  buffer.write(')');
}

void _writePosition(GeoCoordinate coordinate, StringBuffer buffer) {
  buffer.write(_formatOrdinate(coordinate.x));
  buffer.write(' ');
  buffer.write(_formatOrdinate(coordinate.y));
  if (coordinate.z != null) {
    buffer.write(' ');
    buffer.write(_formatOrdinate(coordinate.z!));
  }
  if (coordinate.m != null) {
    buffer.write(' ');
    buffer.write(_formatOrdinate(coordinate.m!));
  }
}

String _formatOrdinate(double value) => value.toString();

final class _WktReader {
  _WktReader(this.text, this.fallbackSrid, this.options);

  final String text;
  final int fallbackSrid;
  final GeoParseOptions options;
  int index = 0;
  int coordinates = 0;
  int? embeddedSrid;

  GeoGeometry parse() {
    if (text.length > options.limits.maxInputBytes) {
      throw GeoParseException(
        'WKT exceeds ${options.limits.maxInputBytes} bytes',
      );
    }
    _skip();
    if (_startsWith('SRID')) {
      _expectWord('SRID');
      _skip();
      _expect('=');
      _skip();
      embeddedSrid = _readInt();
      _checkSrid(embeddedSrid!);
      _skip();
      _expect(';');
      _skip();
    }
    var geometry = _readGeometry(0);
    _skip();
    if (index != text.length) {
      throw GeoParseException('unexpected trailing WKT', offset: index);
    }
    if (options.mode == GeoValidationMode.repair) {
      geometry = geoMakeValid(geometry);
    } else if (options.mode == GeoValidationMode.strict && !geometry.isValid) {
      throw GeoParseException(geometry.validate().reason, offset: index);
    }
    final srid = embeddedSrid ?? fallbackSrid;
    return geometry.srid == srid ? geometry : geometry.withSrid(srid);
  }

  GeoGeometry _readGeometry(int depth) {
    if (depth > options.limits.maxDepth) {
      throw GeoParseException('WKT nesting is too deep', offset: index);
    }
    final name = _readWord();
    _skip();
    var z = false;
    var m = false;
    if (_peekWord() == 'ZM' || _peekWord() == 'Z' || _peekWord() == 'M') {
      final flag = _readWord();
      z = flag == 'Z' || flag == 'ZM';
      m = flag == 'M' || flag == 'ZM';
      _skip();
    }
    final dimension = GeoDimension.fromFlags(z: z, m: m);
    if (_startsWith('EMPTY')) {
      _expectWord('EMPTY');
      return _empty(name, dimension);
    }
    return switch (name) {
      'POINT' => _point(dimension),
      'LINESTRING' =>
        GeoLineString(_positions(dimension), dimension: dimension),
      'POLYGON' => _polygon(dimension),
      'MULTIPOINT' => _multiPoint(dimension, depth),
      'MULTILINESTRING' => _multiLine(dimension),
      'MULTIPOLYGON' => _multiPolygon(dimension),
      'GEOMETRYCOLLECTION' => _collection(dimension, depth),
      _ =>
        throw GeoParseException('unknown geometry type $name', offset: index),
    };
  }

  GeoGeometry _empty(String name, GeoDimension dimension) => switch (name) {
        'POINT' => GeoPoint.empty(dimension: dimension),
        'LINESTRING' => GeoLineString.empty(dimension: dimension),
        'POLYGON' => GeoPolygon.empty(dimension: dimension),
        'MULTIPOINT' => GeoMultiPoint(const [], dimension: dimension),
        'MULTILINESTRING' => GeoMultiLineString(const [], dimension: dimension),
        'MULTIPOLYGON' => GeoMultiPolygon(const [], dimension: dimension),
        'GEOMETRYCOLLECTION' =>
          GeoGeometryCollection(const [], dimension: dimension),
        _ =>
          throw GeoParseException('unknown geometry type $name', offset: index),
      };

  GeoPoint _point(GeoDimension dimension) {
    _expect('(');
    final coordinate = _position(dimension);
    _expect(')');
    return GeoPoint.xy(
      coordinate.x,
      coordinate.y,
      z: coordinate.z,
      m: coordinate.m,
    );
  }

  GeoPolygon _polygon(GeoDimension dimension) {
    _expect('(');
    final rings = _ringList(dimension);
    _expect(')');
    return _polygonFrom(rings, dimension);
  }

  GeoMultiPoint _multiPoint(GeoDimension dimension, int depth) {
    _expect('(');
    final points = <GeoPoint>[];
    _skip();
    if (_peek() == ')') {
      _expect(')');
      return GeoMultiPoint(points, dimension: dimension);
    }
    while (true) {
      _skip();
      if (_startsWith('EMPTY')) {
        _expectWord('EMPTY');
        points.add(GeoPoint.empty(dimension: dimension));
      } else if (_peek() == '(') {
        points.add(_point(dimension));
      } else {
        final coordinate = _position(dimension);
        points.add(GeoPoint.xy(
          coordinate.x,
          coordinate.y,
          z: coordinate.z,
          m: coordinate.m,
        ));
      }
      if (points.length > options.limits.maxParts) {
        throw GeoParseException('too many geometry parts', offset: index);
      }
      _skip();
      if (_peek() == ',') {
        index++;
        continue;
      }
      break;
    }
    _expect(')');
    if (depth > options.limits.maxDepth) {
      throw GeoParseException('WKT nesting is too deep', offset: index);
    }
    return GeoMultiPoint(points, dimension: dimension);
  }

  GeoMultiLineString _multiLine(GeoDimension dimension) {
    _expect('(');
    final lines = <GeoLineString>[];
    _skip();
    if (_peek() != ')') {
      while (true) {
        _skip();
        if (_startsWith('EMPTY')) {
          _expectWord('EMPTY');
          lines.add(GeoLineString.empty(dimension: dimension));
        } else {
          lines.add(GeoLineString(_positions(dimension), dimension: dimension));
        }
        if (lines.length > options.limits.maxParts) {
          throw GeoParseException('too many geometry parts', offset: index);
        }
        _skip();
        if (_peek() == ',') {
          index++;
          continue;
        }
        break;
      }
    }
    _expect(')');
    return GeoMultiLineString(lines, dimension: dimension);
  }

  GeoMultiPolygon _multiPolygon(GeoDimension dimension) {
    _expect('(');
    final polygons = <GeoPolygon>[];
    _skip();
    if (_peek() != ')') {
      while (true) {
        _skip();
        if (_startsWith('EMPTY')) {
          _expectWord('EMPTY');
          polygons.add(GeoPolygon.empty(dimension: dimension));
        } else {
          _expect('(');
          final rings = _ringList(dimension);
          _expect(')');
          polygons.add(_polygonFrom(rings, dimension));
        }
        if (polygons.length > options.limits.maxParts) {
          throw GeoParseException('too many geometry parts', offset: index);
        }
        _skip();
        if (_peek() == ',') {
          index++;
          continue;
        }
        break;
      }
    }
    _expect(')');
    return GeoMultiPolygon(polygons, dimension: dimension);
  }

  GeoGeometryCollection _collection(GeoDimension dimension, int depth) {
    _expect('(');
    final parts = <GeoGeometry>[];
    _skip();
    if (_peek() != ')') {
      while (true) {
        parts.add(_readGeometry(depth + 1));
        if (parts.length > options.limits.maxParts) {
          throw GeoParseException('too many geometry parts', offset: index);
        }
        _skip();
        if (_peek() == ',') {
          index++;
          continue;
        }
        break;
      }
    }
    _expect(')');
    return GeoGeometryCollection(parts, dimension: dimension);
  }

  List<List<GeoCoordinate>> _ringList(GeoDimension dimension) {
    final rings = <List<GeoCoordinate>>[];
    while (true) {
      rings.add(_positions(dimension));
      if (rings.length > options.limits.maxRings) {
        throw GeoParseException('too many polygon rings', offset: index);
      }
      _skip();
      if (_peek() == ',') {
        index++;
        _skip();
        continue;
      }
      break;
    }
    return rings;
  }

  GeoPolygon _polygonFrom(
      List<List<GeoCoordinate>> rings, GeoDimension dimension) {
    if (rings.isEmpty) return GeoPolygon.empty(dimension: dimension);
    return GeoPolygon(
      exteriorRing: rings.first,
      holes: rings.skip(1).toList(),
      dimension: dimension,
    );
  }

  List<GeoCoordinate> _positions(GeoDimension dimension) {
    _expect('(');
    final points = <GeoCoordinate>[];
    _skip();
    if (_peek() != ')') {
      while (true) {
        points.add(_position(dimension));
        _skip();
        if (_peek() == ',') {
          index++;
          continue;
        }
        break;
      }
    }
    _expect(')');
    return points;
  }

  GeoCoordinate _position(GeoDimension dimension) {
    final x = _readDouble();
    _skip();
    final y = _readDouble();
    double? z;
    double? m;
    if (dimension.hasZ) {
      _skip();
      z = _readDouble();
    }
    if (dimension.hasM) {
      _skip();
      m = _readDouble();
    }
    coordinates++;
    if (coordinates > options.limits.maxCoordinates) {
      throw GeoParseException('too many coordinates', offset: index);
    }
    return GeoCoordinate(x, y, z: z, m: m);
  }

  double _readDouble() {
    _skip();
    final start = index;
    if (_peek() == '+' || _peek() == '-') index++;
    if (!_isDigit() && _peek() != '.') {
      throw GeoParseException('expected a number', offset: index);
    }
    while (_isDigit()) {
      index++;
    }
    if (_peek() == '.') {
      index++;
      while (_isDigit()) {
        index++;
      }
    }
    if (_peek() == 'e' || _peek() == 'E') {
      index++;
      if (_peek() == '+' || _peek() == '-') index++;
      if (!_isDigit()) {
        throw GeoParseException('expected an exponent', offset: index);
      }
      while (_isDigit()) {
        index++;
      }
    }
    final token = text.substring(start, index);
    final value = double.tryParse(token);
    if (value == null || !value.isFinite) {
      throw GeoParseException('invalid number $token', offset: start);
    }
    return value;
  }

  int _readInt() {
    final start = index;
    if (_peek() == '+' || _peek() == '-') index++;
    if (!_isDigit()) throw GeoParseException('expected an SRID', offset: index);
    while (_isDigit()) {
      index++;
    }
    return int.parse(text.substring(start, index));
  }

  String _readWord() {
    _skip();
    final start = index;
    if (!_isLetter()) {
      throw GeoParseException('expected a geometry type', offset: index);
    }
    while (_isLetter()) {
      index++;
    }
    return text.substring(start, index).toUpperCase();
  }

  String? _peekWord() {
    final saved = index;
    _skip();
    if (!_isLetter()) {
      index = saved;
      return null;
    }
    final word = _readWord();
    index = saved;
    return word;
  }

  void _expectWord(String word) {
    final found = _readWord();
    if (found != word) {
      throw GeoParseException('expected $word', offset: index);
    }
  }

  bool _startsWith(String word) {
    final saved = index;
    _skip();
    final matched = _peekWord() == word;
    index = saved;
    return matched;
  }

  void _expect(String mark) {
    _skip();
    if (_peek() != mark) {
      throw GeoParseException('expected $mark', offset: index);
    }
    index += mark.length;
  }

  void _skip() {
    while (index < text.length) {
      final unit = text.codeUnitAt(index);
      if (unit != 32 && unit != 9 && unit != 10 && unit != 13) return;
      index++;
    }
  }

  String? _peek() => index < text.length ? text[index] : null;

  bool _isDigit() =>
      index < text.length &&
      text.codeUnitAt(index) >= 48 &&
      text.codeUnitAt(index) <= 57;

  bool _isLetter() =>
      index < text.length &&
      ((text.codeUnitAt(index) >= 65 && text.codeUnitAt(index) <= 90) ||
          (text.codeUnitAt(index) >= 97 && text.codeUnitAt(index) <= 122));
}

GeoGeometry _parseWkt(
  String wkt, {
  required int srid,
  required GeoParseOptions options,
}) {
  _checkSrid(srid);
  return _WktReader(wkt, srid, options).parse();
}
