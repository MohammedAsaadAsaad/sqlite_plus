part of '../geo_engine.dart';

/// One geometry column recorded in `geo_spatial_columns`.
final class GeoColumnInfo {
  /// Metadata for one spatial column. The geometry itself is an EWKB blob.
  const GeoColumnInfo({
    required this.table,
    required this.column,
    required this.geometryType,
    required this.dimension,
    required this.srid,
    required this.spatialIndex,
    required this.nullable,
  });

  /// Table that holds the blob.
  final String table;

  /// Blob column.
  final String column;

  /// Required type, or null when any geometry is accepted.
  final GeoGeometryType? geometryType;

  /// Required axes.
  final GeoDimension dimension;

  /// Required SRID. Zero accepts the geometry's own SRID.
  final int srid;

  /// R-tree virtual table, or null when the column is not indexed.
  final String? spatialIndex;

  /// Whether SQL NULL is allowed.
  final bool nullable;
}

/// A spatial index check.
final class GeoIndexReport {
  /// [missing] rows have a geometry and no index entry. [extra] entries have
  /// no row. [stale] entries do not contain the geometry envelope.
  const GeoIndexReport({
    required this.missing,
    required this.extra,
    required this.stale,
  });

  /// Rowids whose envelope is absent from the index.
  final List<BigInt> missing;

  /// Index ids that do not match a geometry row.
  final List<BigInt> extra;

  /// Index ids whose stored box does not contain the geometry envelope.
  final List<BigInt> stale;

  /// Whether the index matches every stored envelope.
  bool get consistent => missing.isEmpty && extra.isEmpty && stale.isEmpty;
}

/// Creates spatial tables and keeps their R-tree entries in the same savepoint
/// as the row.
final class GeoSession {
  /// [database] must already be open. Call [SqlitePlusGeo.register] before SQL
  /// functions are used. The session registers them again.
  GeoSession(this.database) {
    SqlitePlusGeo.register(database);
  }

  /// The underlying engine connection.
  final MutableSqliteDatabase database;

  static const _metadata = 'geo_spatial_columns';
  var _savepoints = 0;

  /// Creates [table] with an integer primary key, the extra [columns], and one
  /// geometry blob. The default extra column is `name TEXT`.
  Future<void> createSpatialTable(
    String table, {
    required String geometryColumn,
    GeoGeometryType? geometryType,
    GeoDimension dimension = GeoDimension.xy,
    int srid = 0,
    bool spatialIndex = true,
    bool nullable = true,
    List<String> columns = const ['name TEXT'],
  }) async {
    final tableName = _sqlName(table);
    final columnName = _sqlName(geometryColumn);
    _checkSrid(srid);
    if (tableName == columnName || columnName == 'id') {
      throw const GeoException('geometry column collides with another column');
    }
    await _metadataTable();
    final definitions = <String>[
      'id INTEGER PRIMARY KEY',
      for (final column in columns) _columnDefinition(column),
      '$columnName BLOB',
    ];
    await _write(() async {
      await database.execute(
        'CREATE TABLE $tableName (${definitions.join(', ')})',
      );
      final index = spatialIndex ? _indexName(tableName, columnName) : null;
      if (index != null) {
        await database.execute(
          'CREATE VIRTUAL TABLE $index USING rtree(id, minX, maxX, minY, maxY)',
        );
      }
      await database.execute(
        'INSERT INTO $_metadata(table_name, column_name, geometry_type, coord_dimension, srid, spatial_index, nullable) VALUES(?, ?, ?, ?, ?, ?, ?)',
        [
          tableName,
          columnName,
          geometryType?.wktName ?? 'GEOMETRY',
          dimension.name,
          BigInt.from(srid),
          index,
          nullable ? 1 : 0,
        ],
      );
    });
  }

  /// Inserts one row and its index entry.
  Future<BigInt> insert(
    String table, {
    required String geometryColumn,
    required GeoGeometry? geometry,
    Map<String, Object?> values = const {},
  }) async {
    final info = await _info(table, geometryColumn);
    final blob = _checked(info, geometry);
    return _write(() async {
      final names = <String>[info.column, ...values.keys.map(_sqlName)];
      final parameters = <Object?>[blob, ...values.values];
      final result = await database.execute(
        'INSERT INTO ${info.table} (${names.join(', ')}) VALUES (${List.filled(names.length, '?').join(', ')})',
        parameters,
      );
      final rowid = result.lastInsertRowid;
      if (rowid == null) {
        throw const GeoException('insert did not return a rowid');
      }
      await _upsertIndex(info, rowid, geometry);
      return rowid;
    });
  }

  /// Replaces the geometry and its index entry.
  Future<void> updateGeometry(
    String table, {
    required BigInt rowid,
    required String geometryColumn,
    required GeoGeometry? geometry,
  }) async {
    final info = await _info(table, geometryColumn);
    final blob = _checked(info, geometry);
    await _write(() async {
      await database.execute(
        'UPDATE ${info.table} SET ${info.column} = ? WHERE rowid = ?',
        [blob, rowid],
      );
      await _upsertIndex(info, rowid, geometry);
    });
  }

  /// Deletes the row and its index entry.
  Future<void> delete(
    String table, {
    required BigInt rowid,
    required String geometryColumn,
  }) async {
    final info = await _info(table, geometryColumn);
    await _write(() async {
      await database.execute(
        'DELETE FROM ${info.table} WHERE rowid = ?',
        [rowid],
      );
      if (info.spatialIndex != null) {
        await database.execute(
          'DELETE FROM ${info.spatialIndex} WHERE id = ?',
          [rowid],
        );
      }
    });
  }

  /// Compares every geometry envelope with the R-tree. This does not repair it.
  Future<GeoIndexReport> validateIndex(
    String table, {
    required String geometryColumn,
  }) async {
    final info = await _info(table, geometryColumn);
    if (info.spatialIndex == null) {
      throw const GeoException('column has no spatial index');
    }
    final rows = await database.query(
      'SELECT rowid, ${info.column} FROM ${info.table}',
    );
    final indexed = await database.query(
      'SELECT id, minX, maxX, minY, maxY FROM ${info.spatialIndex}',
    );
    final byId = <BigInt, List<Object?>>{
      for (final row in indexed.rows) row[0]! as BigInt: row,
    };
    final missing = <BigInt>[];
    final stale = <BigInt>[];
    final seen = <BigInt>{};
    for (final row in rows.rows) {
      final rowid = row[0]! as BigInt;
      final geometry =
          row[1] == null ? null : GeoGeometry.fromWkb(row[1]! as Uint8List);
      final envelope = geometry?.envelope;
      if (envelope == null) continue;
      seen.add(rowid);
      final stored = byId[rowid];
      if (stored == null) {
        missing.add(rowid);
        continue;
      }
      if (!_containsStored(stored, envelope)) stale.add(rowid);
    }
    final extra = [
      for (final id in byId.keys)
        if (!seen.contains(id)) id,
    ];
    return GeoIndexReport(missing: missing, extra: extra, stale: stale);
  }

  /// Rebuilds the R-tree from the stored geometries.
  Future<void> rebuildIndex(
    String table, {
    required String geometryColumn,
  }) async {
    final info = await _info(table, geometryColumn);
    if (info.spatialIndex == null) {
      throw const GeoException('column has no spatial index');
    }
    await _write(() async {
      await database.execute('DELETE FROM ${info.spatialIndex}');
      final rows = await database.query(
        'SELECT rowid, ${info.column} FROM ${info.table}',
      );
      for (final row in rows.rows) {
        final geometry =
            row[1] == null ? null : GeoGeometry.fromWkb(row[1]! as Uint8List);
        await _upsertIndex(info, row[0]! as BigInt, geometry);
      }
    });
  }

  Future<void> _metadataTable() async {
    await database.execute(
      'CREATE TABLE IF NOT EXISTS $_metadata ('
      'table_name TEXT NOT NULL, column_name TEXT NOT NULL, '
      'geometry_type TEXT NOT NULL, coord_dimension TEXT NOT NULL, '
      'srid INTEGER NOT NULL, spatial_index TEXT, nullable INTEGER NOT NULL, '
      'PRIMARY KEY (table_name, column_name))',
    );
  }

  Future<GeoColumnInfo> _info(String table, String column) async {
    await _metadataTable();
    final tableName = _sqlName(table);
    final columnName = _sqlName(column);
    final rows = await database.query(
      'SELECT geometry_type, coord_dimension, srid, spatial_index, nullable '
      'FROM $_metadata WHERE table_name = ? AND column_name = ?',
      [tableName, columnName],
    );
    if (rows.rows.isEmpty) {
      throw GeoException(
          'spatial column $tableName.$columnName is not registered');
    }
    final row = rows.rows.single;
    final typeName = row[0]! as String;
    return GeoColumnInfo(
      table: tableName,
      column: columnName,
      geometryType: typeName == 'GEOMETRY'
          ? null
          : GeoGeometryType.values
              .firstWhere((type) => type.wktName == typeName),
      dimension: GeoDimension.values.byName(row[1]! as String),
      srid: (row[2]! as BigInt).toInt(),
      spatialIndex: row[3] as String?,
      nullable: row[4] == BigInt.one || row[4] == 1,
    );
  }

  Uint8List? _checked(GeoColumnInfo info, GeoGeometry? geometry) {
    if (geometry == null) {
      if (!info.nullable) {
        throw const GeoException('geometry column is not nullable');
      }
      return null;
    }
    if (info.geometryType != null && geometry.type != info.geometryType) {
      throw GeoException(
        'expected ${info.geometryType!.wktName} and received ${geometry.type.wktName}',
      );
    }
    if (geometry.dimension != info.dimension) {
      throw const GeoException('geometry dimension does not match the column');
    }
    if (info.srid != 0 && geometry.srid != info.srid) {
      throw GeoException(
          'expected SRID ${info.srid} and received ${geometry.srid}');
    }
    return geometry.toEwkb();
  }

  Future<void> _upsertIndex(
    GeoColumnInfo info,
    BigInt rowid,
    GeoGeometry? geometry,
  ) async {
    if (info.spatialIndex == null) return;
    await database
        .execute('DELETE FROM ${info.spatialIndex} WHERE id = ?', [rowid]);
    final envelope = geometry?.envelope;
    if (envelope == null) return;
    final box = _indexBox(envelope);
    await database.execute(
      'INSERT INTO ${info.spatialIndex}(id, minX, maxX, minY, maxY) VALUES(?, ?, ?, ?, ?)',
      [rowid, box.minX, box.maxX, box.minY, box.maxY],
    );
  }

  Future<T> _write<T>(Future<T> Function() action) async {
    final name = 'geo_${_savepoints++}';
    await database.execute('SAVEPOINT $name');
    try {
      final value = await action();
      await database.execute('RELEASE $name');
      return value;
    } catch (error) {
      try {
        await database.execute('ROLLBACK TO $name');
        await database.execute('RELEASE $name');
      } catch (_) {}
      rethrow;
    }
  }
}

String _sqlName(String name) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,62}$').hasMatch(name)) {
    throw GeoException('identifier $name is not a simple SQL name');
  }
  return name;
}

String _columnDefinition(String definition) {
  final match =
      RegExp(r'^([A-Za-z_][A-Za-z0-9_]{0,62})(\s+[A-Za-z0-9_() ,]+)?$')
          .firstMatch(definition.trim());
  if (match == null) {
    throw GeoException('column definition $definition is not accepted');
  }
  return definition.trim();
}

String _indexName(String table, String column) {
  final name = 'geoidx_${table}_$column';
  if (name.length > 63) {
    throw const GeoException('spatial index name is too long');
  }
  return name;
}

GeoEnvelope _indexBox(GeoEnvelope envelope) => GeoEnvelope(
      minX: _float32Down(envelope.minX),
      minY: _float32Down(envelope.minY),
      maxX: _float32Up(envelope.maxX),
      maxY: _float32Up(envelope.maxY),
    );

bool _containsStored(List<Object?> row, GeoEnvelope envelope) {
  final minX = (row[1]! as num).toDouble();
  final maxX = (row[2]! as num).toDouble();
  final minY = (row[3]! as num).toDouble();
  final maxY = (row[4]! as num).toDouble();
  return minX <= envelope.minX &&
      maxX >= envelope.maxX &&
      minY <= envelope.minY &&
      maxY >= envelope.maxY;
}

double _float32(double value) {
  final data = ByteData(4)..setFloat32(0, value);
  return data.getFloat32(0);
}

double _float32Down(double value) {
  final current = _float32(value);
  if (!current.isFinite) {
    throw const GeoException('coordinate does not fit in the spatial index');
  }
  if (current <= value) return current;
  return _stepFloat32(current, down: true);
}

double _float32Up(double value) {
  final current = _float32(value);
  if (!current.isFinite) {
    throw const GeoException('coordinate does not fit in the spatial index');
  }
  if (current >= value) return current;
  return _stepFloat32(current, down: false);
}

double _stepFloat32(double value, {required bool down}) {
  final data = ByteData(4)..setFloat32(0, value);
  var bits = data.getUint32(0);
  if (value == 0) {
    bits = down ? 0x80000001 : 0x00000001;
  } else if (bits & 0x80000000 == 0) {
    bits += down ? -1 : 1;
  } else {
    bits += down ? 1 : -1;
  }
  data.setUint32(0, bits);
  final stepped = data.getFloat32(0);
  if (!stepped.isFinite) {
    throw const GeoException('coordinate does not fit in the spatial index');
  }
  return stepped;
}
