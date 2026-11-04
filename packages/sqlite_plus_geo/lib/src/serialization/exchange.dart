part of '../geo_engine.dart';

/// How many GeoJSON or CSV records were stored or skipped.
final class GeoImportProgress {
  /// [accepted] rows were inserted. [rejected] records were skipped.
  const GeoImportProgress({required this.accepted, required this.rejected});

  /// Rows written to the table.
  final int accepted;

  /// Records that failed validation when skipping was requested.
  final int rejected;
}

/// One decoded GeoJSON feature. A bare geometry has empty [properties].
final class GeoFeatureRecord {
  /// [geometry] keeps the longitude, latitude order of the source.
  const GeoFeatureRecord({required this.geometry, required this.properties});

  /// The feature geometry, with SRID 4326.
  final GeoGeometry geometry;

  /// JSON properties. Nested objects stay as decoded JSON values.
  final Map<String, Object?> properties;
}

/// Reads GeoJSON features from a byte stream without `dart:io`.
///
/// A FeatureCollection yields one record per feature. Newline-delimited
/// features and a single geometry are accepted. Each object is capped by
/// [GeoParseOptions.limits]. The whole file is not required to fit in memory.
Stream<GeoFeatureRecord> readGeoJsonFeatures(
  Stream<List<int>> bytes, {
  GeoParseOptions options = const GeoParseOptions(),
  bool skipInvalid = false,
  void Function()? onRejected,
}) async* {
  final splitter = _GeoJsonSplitter(options.limits.maxInputBytes);
  var produced = 0;
  await for (final chunk in utf8.decoder.bind(bytes)) {
    for (final object in splitter.add(chunk)) {
      final record = _recordFromJson(object, options, skipInvalid: skipInvalid);
      if (record == null) {
        onRejected?.call();
        continue;
      }
      produced++;
      if (produced > options.limits.maxParts) {
        throw const GeoParseException('too many geometry parts');
      }
      yield record;
    }
  }
  for (final object in splitter.finish()) {
    final record = _recordFromJson(object, options, skipInvalid: skipInvalid);
    if (record == null) {
      onRejected?.call();
      continue;
    }
    produced++;
    if (produced > options.limits.maxParts) {
      throw const GeoParseException('too many geometry parts');
    }
    yield record;
  }
}

/// Streaming import and export on a [GeoSession].
extension GeoExchange on GeoSession {
  /// Inserts features from [bytes]. Properties that match a table column are
  /// stored. The geometry column receives EWKB with SRID 4326.
  Future<GeoImportProgress> importGeoJsonStream({
    required Stream<List<int>> bytes,
    required String table,
    required String geometryColumn,
    int batchSize = 1000,
    bool skipInvalid = false,
    GeoParseOptions options = const GeoParseOptions(),
    void Function(GeoImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (batchSize < 1) throw const GeoException('batch size must be positive');
    final columns = await _spatialColumns(this, table);
    if (!columns.contains(geometryColumn)) {
      throw GeoException('table $table has no column $geometryColumn');
    }
    final batch = <GeoFeatureRecord>[];
    var accepted = 0;
    var rejected = 0;
    Future<void> flush() async {
      if (batch.isEmpty) return;
      await _insertBatch(table, geometryColumn, columns, batch);
      accepted += batch.length;
      batch.clear();
      onProgress
          ?.call(GeoImportProgress(accepted: accepted, rejected: rejected));
    }

    await for (final record in readGeoJsonFeatures(
      bytes,
      options: options,
      skipInvalid: skipInvalid,
      onRejected: () => rejected++,
    )) {
      if (isCancelled?.call() == true) break;
      if (record.geometry.isEmpty && record.geometry is GeoPoint) {
        if (!skipInvalid) {
          throw const GeoParseException('GeoJSON has no empty point');
        }
        rejected++;
        continue;
      }
      batch.add(record);
      if (batch.length >= batchSize) await flush();
    }
    await flush();
    return GeoImportProgress(accepted: accepted, rejected: rejected);
  }

  /// Inserts points from a CSV stream. The header must name `longitude` and
  /// `latitude`, or `x` and `y`. Other headers that match columns are stored.
  Future<GeoImportProgress> importCsvStream({
    required Stream<List<int>> bytes,
    required String table,
    required String geometryColumn,
    int srid = 4326,
    int batchSize = 1000,
    bool skipInvalid = false,
    void Function(GeoImportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (batchSize < 1) throw const GeoException('batch size must be positive');
    final columns = await _spatialColumns(this, table);
    final batch = <GeoFeatureRecord>[];
    var accepted = 0;
    var rejected = 0;
    List<String>? header;
    final pending = StringBuffer();

    Future<void> flush() async {
      if (batch.isEmpty) return;
      await _insertBatch(table, geometryColumn, columns, batch);
      accepted += batch.length;
      batch.clear();
      onProgress
          ?.call(GeoImportProgress(accepted: accepted, rejected: rejected));
    }

    Future<void> takeLine(String line) async {
      if (line.isEmpty) return;
      final cells = _csvCells(line);
      if (header == null) {
        header = [for (final cell in cells) cell.trim()];
        return;
      }
      if (isCancelled?.call() == true) return;
      try {
        batch.add(_pointRecord(header!, cells, srid, columns, geometryColumn));
        if (batch.length >= batchSize) await flush();
      } on GeoException {
        if (!skipInvalid) rethrow;
        rejected++;
      } on FormatException {
        if (!skipInvalid) {
          throw const GeoException('CSV coordinate is not a number');
        }
        rejected++;
      }
    }

    await for (final chunk in utf8.decoder.bind(bytes)) {
      pending.write(chunk);
      final text = pending.toString();
      final lines = text.split('\n');
      pending
        ..clear()
        ..write(lines.removeLast());
      for (final line in lines) {
        await takeLine(line.trimRight());
      }
      if (isCancelled?.call() == true) break;
    }
    final tail = pending.toString().trim();
    if (tail.isNotEmpty && isCancelled?.call() != true) await takeLine(tail);
    await flush();
    return GeoImportProgress(accepted: accepted, rejected: rejected);
  }

  /// Writes a GeoJSON FeatureCollection. One feature is encoded at a time.
  Future<void> exportGeoJson({
    required String table,
    required String geometryColumn,
    required StringSink sink,
    Iterable<String>? propertyColumns,
  }) async {
    final info = await _info(table, geometryColumn);
    final available = await _spatialColumns(this, info.table);
    final properties = <String>[
      for (final name in propertyColumns ?? available)
        if (name != info.column && available.contains(name)) _sqlName(name),
    ];
    final selected = ['rowid', info.column, ...properties];
    final rows = await database.query(
      'SELECT ${selected.join(', ')} FROM ${info.table}',
    );
    sink.write('{"type":"FeatureCollection","features":[');
    var first = true;
    for (final row in rows.rows) {
      if (row[1] is! Uint8List) continue;
      final geometry = GeoGeometry.fromWkb(row[1]! as Uint8List);
      final values = <String, Object?>{};
      for (var i = 0; i < properties.length; i++) {
        values[properties[i]] = _jsonValue(row[i + 2]);
      }
      if (!first) sink.write(',');
      first = false;
      sink.write(
        jsonEncode({
          'type': 'Feature',
          'geometry': geometry.toGeoJson(),
          'properties': values,
        }),
      );
    }
    sink.write(']}');
  }

  Future<void> _insertBatch(
    String table,
    String geometryColumn,
    Set<String> columns,
    List<GeoFeatureRecord> records,
  ) async {
    final owns = !database.inTransaction;
    if (owns) await database.execute('BEGIN');
    try {
      for (final record in records) {
        final values = <String, Object?>{};
        for (final entry in record.properties.entries) {
          if (entry.key == geometryColumn || entry.key == 'id') continue;
          if (!columns.contains(entry.key)) continue;
          final stored = _storedValue(entry.value);
          if (stored == null && entry.value != null) continue;
          values[entry.key] = stored;
        }
        await insert(
          table,
          geometryColumn: geometryColumn,
          geometry: record.geometry,
          values: values,
        );
      }
      if (owns) await database.execute('COMMIT');
    } catch (error) {
      if (owns) {
        try {
          await database.execute('ROLLBACK');
        } on Object {
          // The failed statement already rolled the savepoint back.
        }
      }
      rethrow;
    }
  }
}

Future<Set<String>> _spatialColumns(GeoSession session, String table) async {
  final name = _sqlName(table);
  final rows = await session.database.query('PRAGMA table_info($name)');
  return {for (final row in rows.rows) row[1]! as String};
}

GeoFeatureRecord? _recordFromJson(
  String source,
  GeoParseOptions options, {
  required bool skipInvalid,
}) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const GeoParseException('GeoJSON value must be an object');
    }
    final type = decoded['type'];
    Object? geometryJson = decoded;
    final properties = <String, Object?>{};
    if (type == 'Feature') {
      geometryJson = decoded['geometry'];
      final raw = decoded['properties'];
      if (raw is Map) {
        for (final entry in raw.entries) {
          if (entry.key is String) {
            properties[entry.key as String] = entry.value;
          }
        }
      }
    } else if (type == 'FeatureCollection') {
      throw const GeoParseException('a feature collection was not split');
    }
    if (geometryJson == null) {
      throw const GeoParseException('GeoJSON feature geometry is null');
    }
    final geometry = GeoGeometry.fromGeoJson(geometryJson, options: options);
    return GeoFeatureRecord(
      geometry: geometry.srid == 0 ? geometry.withSrid(4326) : geometry,
      properties: properties,
    );
  } on GeoException {
    if (skipInvalid) return null;
    rethrow;
  }
}

GeoFeatureRecord _pointRecord(
  List<String> header,
  List<String> cells,
  int srid,
  Set<String> columns,
  String geometryColumn,
) {
  double? x;
  double? y;
  final properties = <String, Object?>{};
  for (var i = 0; i < header.length && i < cells.length; i++) {
    final name = header[i];
    final cell = cells[i].trim();
    if (name == 'longitude' || name == 'lon' || name == 'x') {
      x = double.parse(cell);
    } else if (name == 'latitude' || name == 'lat' || name == 'y') {
      y = double.parse(cell);
    } else if (columns.contains(name) && name != geometryColumn) {
      properties[name] = _csvValue(cell);
    }
  }
  if (x == null || y == null) {
    throw const GeoException('CSV header needs longitude and latitude');
  }
  return GeoFeatureRecord(
    geometry: GeoPoint(longitude: x, latitude: y, srid: srid),
    properties: properties,
  );
}

Object? _csvValue(String cell) {
  if (cell.isEmpty) return null;
  final number = num.tryParse(cell);
  if (number != null) return number;
  return cell;
}

Object? _storedValue(Object? value) => switch (value) {
      null || String _ || int _ || double _ => value,
      bool flag => flag ? 1 : 0,
      BigInt number => number,
      _ => null,
    };

Object? _jsonValue(Object? value) => switch (value) {
      BigInt number => number.toInt(),
      _ => value,
    };

List<String> _csvCells(String line) {
  final cells = <String>[];
  final current = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final char = line[i];
    if (quoted) {
      if (char == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          current.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        current.write(char);
      }
      continue;
    }
    if (char == '"') {
      quoted = true;
    } else if (char == ',') {
      cells.add(current.toString());
      current.clear();
    } else if (char != '\r') {
      current.write(char);
    }
  }
  cells.add(current.toString());
  return cells;
}

final class _GeoJsonSplitter {
  _GeoJsonSplitter(this.maxObjectBytes);

  final int maxObjectBytes;
  final _ready = <String>[];
  final _buffer = StringBuffer();
  final _key = StringBuffer();
  var _inString = false;
  var _escape = false;
  var _readingKey = false;
  var _objectDepth = 0;
  var _featureDepth = 0;
  var _capturingFeature = false;
  var _capturingRoot = false;
  var _inFeatures = false;
  var _afterKey = false;
  var _valueComing = false;
  String? _lastKey;
  int? _lastStructural;

  List<String> add(String chunk) {
    _ready.clear();
    for (final unit in chunk.codeUnits) {
      final char = String.fromCharCode(unit);
      if (_inString) {
        if (_escape) {
          _write(char);
          if (_readingKey) _key.write(char);
          _escape = false;
          continue;
        }
        if (char == r'\') {
          _write(char);
          if (_readingKey) _key.write(char);
          _escape = true;
          continue;
        }
        if (char == '"') {
          _inString = false;
          if (_readingKey) {
            _lastKey = _key.toString();
            _key.clear();
            _readingKey = false;
            _afterKey = true;
          }
          _write(char);
          continue;
        }
        _write(char);
        if (_readingKey) _key.write(char);
        continue;
      }
      if (char == '"') {
        _inString = true;
        _escape = false;
        _readingKey = !_afterKey &&
            !_valueComing &&
            (_lastStructural == 0x7B || _lastStructural == 0x2C);
        _write(char);
        continue;
      }
      if (char == '{') {
        _objectDepth++;
        if (_inFeatures && !_capturingFeature) {
          _capturingFeature = true;
          _featureDepth = 1;
          _buffer
            ..clear()
            ..write('{');
        } else if (_capturingFeature) {
          _featureDepth++;
          _buffer.write('{');
        } else if (!_inFeatures && _objectDepth == 1) {
          _capturingRoot = true;
          _buffer
            ..clear()
            ..write('{');
        } else if (_capturingRoot) {
          _buffer.write('{');
        }
        _lastStructural = 0x7B;
        _valueComing = false;
        _afterKey = false;
        continue;
      }
      if (char == '}') {
        final closingRoot = _capturingRoot && _objectDepth == 1 && !_inFeatures;
        if (_capturingFeature) {
          _buffer.write('}');
          _featureDepth--;
          if (_featureDepth == 0) {
            _emit();
            _capturingFeature = false;
          }
        } else if (_capturingRoot) {
          _buffer.write('}');
        }
        _objectDepth--;
        if (closingRoot) {
          _emit();
          _capturingRoot = false;
        }
        _lastStructural = 0x7D;
        _valueComing = false;
        continue;
      }
      if (char == '[') {
        if (_valueComing && _lastKey == 'features' && _objectDepth == 1) {
          _inFeatures = true;
          _capturingRoot = false;
          _buffer.clear();
        } else {
          _write(char);
        }
        _lastStructural = 0x5B;
        _valueComing = false;
        _afterKey = false;
        continue;
      }
      if (char == ']') {
        if (_inFeatures && !_capturingFeature) _inFeatures = false;
        _write(char);
        _lastStructural = 0x5D;
        continue;
      }
      if (char == ':') {
        if (_afterKey) {
          _afterKey = false;
          _valueComing = true;
        }
        _write(char);
        _lastStructural = 0x3A;
        continue;
      }
      if (char == ',') {
        _write(char);
        _lastStructural = 0x2C;
        _valueComing = false;
        _afterKey = false;
        continue;
      }
      if (char.trim().isEmpty) {
        _write(char);
        continue;
      }
      _write(char);
      _valueComing = false;
      _lastStructural = char.codeUnitAt(0);
    }
    return List<String>.of(_ready);
  }

  List<String> finish() {
    _ready.clear();
    if (_capturingRoot && _objectDepth == 0 && _buffer.isNotEmpty) _emit();
    if (_inString || _capturingFeature || _objectDepth != 0) {
      throw const GeoParseException('GeoJSON ended inside a value');
    }
    return List<String>.of(_ready);
  }

  void _write(String char) {
    if (_capturingFeature || _capturingRoot) {
      _buffer.write(char);
      if (_buffer.length > maxObjectBytes) {
        throw GeoParseException('GeoJSON exceeds $maxObjectBytes bytes');
      }
    }
  }

  void _emit() {
    final text = _buffer.toString();
    _buffer.clear();
    if (text.isNotEmpty) _ready.add(text);
  }
}
