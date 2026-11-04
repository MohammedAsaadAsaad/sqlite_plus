part of '../geo_engine.dart';

Map<String, Object?> _writeGeoJson(GeoGeometry geometry) {
  if (geometry.dimension.hasM) {
    throw const GeoException('GeoJSON does not encode measure values');
  }
  if (geometry is GeoPoint && geometry.isEmpty) {
    throw const GeoException('GeoJSON has no empty point');
  }
  if (geometry is GeoGeometryCollection) {
    return {
      'type': 'GeometryCollection',
      'geometries': [
        for (final child in geometry.geometries) _writeGeoJson(child),
      ],
    };
  }
  return {
    'type': geometry.type.geoJsonName,
    'coordinates': _geoJsonCoordinates(geometry),
  };
}

Object _geoJsonCoordinates(GeoGeometry geometry) => switch (geometry) {
      GeoPoint point => point.isEmpty
          ? const <Object>[]
          : _position(point.position!, geometry.dimension),
      GeoLineString line => [
          for (final coordinate in line.points)
            _position(coordinate, geometry.dimension),
        ],
      GeoPolygon polygon => polygon.isEmpty
          ? const <Object>[]
          : [
              [
                for (final coordinate in polygon.exterior!.points)
                  _position(coordinate, geometry.dimension),
              ],
              for (final hole in polygon.holes)
                [
                  for (final coordinate in hole.points)
                    _position(coordinate, geometry.dimension),
                ],
            ],
      GeoMultiPoint multi => [
          for (final point in multi.points)
            if (point.isEmpty)
              throw const GeoException('GeoJSON has no empty point')
            else
              _position(point.position!, geometry.dimension),
        ],
      GeoMultiLineString multi => [
          for (final line in multi.lines)
            [
              for (final coordinate in line.points)
                _position(coordinate, geometry.dimension),
            ],
        ],
      GeoMultiPolygon multi => [
          for (final polygon in multi.polygons) _geoJsonCoordinates(polygon),
        ],
      GeoGeometryCollection _ => const <Object>[],
    };

List<Object> _position(GeoCoordinate coordinate, GeoDimension dimension) => [
      coordinate.x,
      coordinate.y,
      if (dimension.hasZ) coordinate.z!,
    ];

GeoGeometry _parseGeoJson(Object? json, {required GeoParseOptions options}) {
  final value = json is String ? jsonDecode(json) : json;
  if (value is! Map) {
    throw const GeoParseException('GeoJSON value must be an object');
  }
  final text = jsonEncode(value);
  if (text.length > options.limits.maxInputBytes) {
    throw GeoParseException(
      'GeoJSON exceeds ${options.limits.maxInputBytes} bytes',
    );
  }
  _rejectForeignCrs(value, options);
  final geometry = _readGeoJson(value, options, 0, _GeoJsonCounter());
  if (options.mode == GeoValidationMode.repair) return geoMakeValid(geometry);
  if (options.mode == GeoValidationMode.strict && !geometry.isValid) {
    throw GeoParseException(geometry.validate().reason);
  }
  return geometry;
}

final class _GeoJsonCounter {
  int coordinates = 0;
}

void _rejectForeignCrs(Map<Object?, Object?> json, GeoParseOptions options) {
  if (!json.containsKey('crs')) return;
  if (!options.allowLegacyCrs) {
    throw const GeoParseException(
      'GeoJSON crs members are rejected; coordinates stay longitude, latitude',
    );
  }
  final crs = json['crs'];
  final name = crs is Map ? crs['properties'] : null;
  final label = name is Map ? name['name'] : null;
  const accepted = {
    'urn:ogc:def:crs:OGC:1.3:CRS84',
    'CRS84',
  };
  if (label is! String || !accepted.contains(label)) {
    throw const GeoParseException(
      'legacy GeoJSON crs is not applied and coordinates are not reordered',
    );
  }
}

GeoGeometry _readGeoJson(
  Map<Object?, Object?> json,
  GeoParseOptions options,
  int depth,
  _GeoJsonCounter counter,
) {
  if (depth > options.limits.maxDepth) {
    throw const GeoParseException('GeoJSON nesting is too deep');
  }
  final type = json['type'];
  if (type is! String) throw const GeoParseException('GeoJSON type is missing');
  switch (type) {
    case 'Point':
    case 'LineString':
    case 'Polygon':
    case 'MultiPoint':
    case 'MultiLineString':
    case 'MultiPolygon':
      return _readShaped(type, json['coordinates'], options, counter);
    case 'GeometryCollection':
      final geometries = json['geometries'];
      if (geometries is! List) {
        throw const GeoParseException('GeoJSON geometries must be an array');
      }
      if (geometries.length > options.limits.maxParts) {
        throw const GeoParseException('too many geometry parts');
      }
      return GeoGeometryCollection([
        for (final child in geometries)
          if (child is Map)
            _readGeoJson(child, options, depth + 1, counter)
          else
            throw const GeoParseException('GeoJSON part must be an object'),
      ], srid: 4326);
    case 'Feature':
      _rejectForeignCrs(json, options);
      final geometry = json['geometry'];
      if (geometry == null) {
        throw const GeoParseException('GeoJSON feature geometry is null');
      }
      if (geometry is! Map) {
        throw const GeoParseException(
            'GeoJSON feature geometry is not an object');
      }
      return _readGeoJson(geometry, options, depth + 1, counter);
    case 'FeatureCollection':
      final features = json['features'];
      if (features is! List) {
        throw const GeoParseException('GeoJSON features must be an array');
      }
      if (features.length > options.limits.maxParts) {
        throw const GeoParseException('too many geometry parts');
      }
      return GeoGeometryCollection([
        for (final feature in features)
          if (feature is Map)
            _readGeoJson(feature, options, depth + 1, counter)
          else
            throw const GeoParseException('GeoJSON feature must be an object'),
      ], srid: 4326);
    default:
      throw GeoParseException('unsupported GeoJSON type $type');
  }
}

GeoGeometry _readShaped(
  String type,
  Object? coordinates,
  GeoParseOptions options,
  _GeoJsonCounter counter,
) {
  if (coordinates is! List) {
    throw const GeoParseException('GeoJSON coordinates must be an array');
  }
  GeoGeometry geometry = switch (type) {
    'Point' => coordinates.isEmpty
        ? GeoPoint.empty(srid: 4326)
        : _point(coordinates, counter, options),
    'LineString' => GeoLineString(
        _line(coordinates, counter, options),
        srid: 4326,
      ),
    'Polygon' => _polygon(coordinates, counter, options),
    'MultiPoint' => GeoMultiPoint(
        [
          for (final item in coordinates)
            item is List
                ? _point(item, counter, options)
                : throw const GeoParseException('GeoJSON position is invalid'),
        ],
        srid: 4326,
      ),
    'MultiLineString' => GeoMultiLineString(
        [
          for (final item in coordinates)
            item is List
                ? GeoLineString(_line(item, counter, options), srid: 4326)
                : throw const GeoParseException('GeoJSON line is invalid'),
        ],
        srid: 4326,
      ),
    'MultiPolygon' => GeoMultiPolygon(
        [
          for (final item in coordinates)
            item is List
                ? _polygon(item, counter, options)
                : throw const GeoParseException('GeoJSON polygon is invalid'),
        ],
        srid: 4326,
      ),
    _ => throw GeoParseException('unsupported GeoJSON type $type'),
  };
  return geometry;
}

GeoPoint _point(
    List<Object?> position, _GeoJsonCounter counter, GeoParseOptions options) {
  final coordinate = _coordinate(position, counter, options);
  return GeoPoint.xy(coordinate.x, coordinate.y, z: coordinate.z, srid: 4326);
}

GeoPolygon _polygon(
  List<Object?> rings,
  _GeoJsonCounter counter,
  GeoParseOptions options,
) {
  if (rings.length > options.limits.maxRings) {
    throw const GeoParseException('too many polygon rings');
  }
  if (rings.isEmpty) return GeoPolygon.empty(srid: 4326);
  final parsed = <List<GeoCoordinate>>[];
  for (final ring in rings) {
    if (ring is! List) throw const GeoParseException('GeoJSON ring is invalid');
    parsed.add(_line(ring, counter, options));
  }
  return GeoPolygon(
    exteriorRing: parsed.first,
    holes: parsed.skip(1).toList(),
    srid: 4326,
  );
}

List<GeoCoordinate> _line(
  List<Object?> positions,
  _GeoJsonCounter counter,
  GeoParseOptions options,
) =>
    [
      for (final position in positions)
        if (position is List)
          _coordinate(position, counter, options)
        else
          throw const GeoParseException('GeoJSON position is invalid'),
    ];

GeoCoordinate _coordinate(
  List<Object?> position,
  _GeoJsonCounter counter,
  GeoParseOptions options,
) {
  if (position.length < 2 || position.length > 3) {
    throw const GeoParseException('GeoJSON position must have 2 or 3 numbers');
  }
  counter.coordinates++;
  if (counter.coordinates > options.limits.maxCoordinates) {
    throw const GeoParseException('too many coordinates');
  }
  return GeoCoordinate(
    _number(position[0]),
    _number(position[1]),
    z: position.length == 3 ? _number(position[2]) : null,
  );
}

double _number(Object? value) {
  final number = switch (value) {
    double item => item,
    int item => item.toDouble(),
    _ => throw const GeoParseException('GeoJSON coordinate is not a number'),
  };
  if (!number.isFinite) {
    throw const GeoParseException('GeoJSON coordinate is not finite');
  }
  return number;
}
