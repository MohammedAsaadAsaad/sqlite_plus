part of '../sqlite_plus_orm.dart';

String _ormAsciiLower(String value) => String.fromCharCodes(
    value.codeUnits.map((unit) => unit >= 65 && unit <= 90 ? unit + 32 : unit));

void _ormValidateName(String name) {
  if (name.isEmpty || name.contains('\u0000')) {
    throw const OrmMappingException('Identifiers must be nonempty without NUL');
  }
}

String quoteIdentifier(String identifier) {
  _ormValidateName(identifier);
  return '"${identifier.replaceAll('"', '""')}"';
}

final class Column<T, V> {
  Column(
      {required this.property,
      String? name,
      required this.codec,
      required this.read,
      this.write,
      this.keyOrder,
      this.generated = false,
      this.version = false,
      this.defaultSql,
      this.unique = false})
      : sqlName = name ?? property {
    _ormValidateName(property);
    _ormValidateName(sqlName);
    if (!['INTEGER', 'REAL', 'TEXT', 'BLOB'].contains(codec.sqlType)) {
      throw const OrmMappingException(
          'Codec SQL type must be INTEGER/REAL/TEXT/BLOB');
    }
    if (keyOrder != null && keyOrder! < 0) {
      throw const OrmMappingException('Key order must be nonnegative');
    }
    if (generated && keyOrder == null) {
      throw const OrmMappingException('Generated column must be a primary key');
    }
    if (defaultSql != null &&
        (defaultSql!.trim().isEmpty || defaultSql!.contains('\u0000'))) {
      throw const OrmMappingException(
          'Default SQL must be nonempty without NUL');
    }
  }

  final String property;
  final String sqlName;
  final ValueCodec<V> codec;
  final V Function(T) read;
  final void Function(T, V)? write;
  final int? keyOrder;
  final bool generated;
  final bool version;
  final String? defaultSql;
  final bool unique;
  bool get nullable => codec.nullable;

  Object? encodeValue(Object? value) {
    try {
      return copyOrmValue(codec.encode(value as V));
    } catch (error) {
      throw OrmCodecException('Cannot encode property $property', error);
    }
  }

  V decodeValue(Object? value) {
    try {
      return codec.decode(copyOrmValue(value));
    } catch (error) {
      throw OrmCodecException('Cannot decode property $property', error);
    }
  }

  Object? readEncoded(T entity) {
    try {
      return encodeValue(read(entity));
    } on OrmCodecException {
      rethrow;
    } catch (error) {
      throw OrmCodecException('Cannot read property $property', error);
    }
  }

  /// Invokes the typed setter without widening a function-valued getter through
  /// heterogeneous column metadata.
  bool get writable => write != null;
  void writeEncoded(T entity, Object? value) {
    final setter = write;
    if (setter == null) {
      throw OrmMappingException('Property $property is read-only');
    }
    setter(entity, decodeValue(value));
  }
}

final class RowReader {
  RowReader(Map<String, Object?> values) {
    for (final entry in values.entries) {
      final key = _ormAsciiLower(entry.key);
      if (_values.containsKey(key)) {
        throw const OrmMappingException('Duplicate row column name');
      }
      _values[key] = copyOrmValue(entry.value);
    }
  }
  final Map<String, Object?> _values = {};
  V read<T, V>(Column<T, V> column) => column.decodeValue(raw(column.sqlName));
  Object? raw(String sqlName) {
    final key = _ormAsciiLower(sqlName);
    if (!_values.containsKey(key)) {
      throw OrmMappingException('Missing row column $sqlName');
    }
    return copyOrmValue(_values[key]);
  }
}

final class OrmIndex<T> {
  OrmIndex(
      {required this.name,
      required List<Column<T, dynamic>> columns,
      this.unique = false})
      : columns = List.unmodifiable(columns) {
    _ormValidateName(name);
    if (_ormAsciiLower(name).startsWith('sqlite_')) {
      throw const OrmMappingException('sqlite_ index names are reserved');
    }
    if (columns.isEmpty || columns.toSet().length != columns.length) {
      throw const OrmMappingException('Index needs distinct columns');
    }
  }
  final String name;
  final List<Column<T, dynamic>> columns;
  final bool unique;
}

final class EntityType<T> {
  EntityType(
      {required this.tableName,
      required List<Column<T, dynamic>> columns,
      required this.create,
      this.applyStoreValues,
      List<OrmIndex<T>> indexes = const []})
      : columns = List.unmodifiable(columns),
        indexes = List.unmodifiable(indexes) {
    _ormValidateName(tableName);
    if (_ormAsciiLower(tableName).startsWith('sqlite_')) {
      throw const OrmMappingException('sqlite_ table names are reserved');
    }
    if (columns.isEmpty) {
      throw const OrmMappingException('Entity needs columns');
    }
    final names = <String>{};
    final properties = <String>{};
    final orders = <int>{};
    for (final column in columns) {
      if (!names.add(_ormAsciiLower(column.sqlName)) ||
          !properties.add(column.property)) {
        throw const OrmMappingException('Duplicate mapped column or property');
      }
      if (column.keyOrder != null && !orders.add(column.keyOrder!)) {
        throw const OrmMappingException('Duplicate key order');
      }
    }
    final sorted = columns.where((column) => column.keyOrder != null).toList()
      ..sort((left, right) => left.keyOrder!.compareTo(right.keyOrder!));
    if (sorted.isEmpty) {
      throw const OrmMappingException('Entity needs a primary key');
    }
    keys = List.unmodifiable(sorted);
    final generated = columns.where((column) => column.generated).toList();
    if (generated.length > 1 ||
        generated.isNotEmpty &&
            (keys.length != 1 ||
                !generated.single.nullable ||
                !_ormIntegerCodec(generated.single.codec))) {
      throw const OrmMappingException(
          'Generated key must be one nullable int/BigInt primary key');
    }
    generatedKey = generated.isEmpty ? null : generated.single;
    final versions = columns.where((column) => column.version).toList();
    if (versions.length > 1 ||
        versions.isNotEmpty &&
            (versions.single.nullable ||
                versions.single.keyOrder != null ||
                !_ormIntegerCodec(versions.single.codec))) {
      throw const OrmMappingException(
          'Version must be one nonnullable int/BigInt non-key column');
    }
    versionColumn = versions.isEmpty ? null : versions.single;
    final indexNames = <String>{};
    for (final index in indexes) {
      if (!indexNames.add(_ormAsciiLower(index.name)) ||
          !index.columns.every(columns.contains)) {
        throw const OrmMappingException('Invalid or duplicate mapped index');
      }
    }
  }
  final String tableName;
  final List<Column<T, dynamic>> columns;
  final T Function(RowReader) create;
  final T Function(T, RowReader)? applyStoreValues;
  final List<OrmIndex<T>> indexes;
  late final List<Column<T, dynamic>> keys;
  late final Column<T, dynamic>? generatedKey;
  late final Column<T, dynamic>? versionColumn;
  Type get dartType => T;

  bool get canApplyStoreValues => applyStoreValues != null;
  T applyValues(T entity, RowReader row) {
    final apply = applyStoreValues;
    if (apply == null) {
      throw const OrmMappingException(
          'No store-value reconstruction is mapped');
    }
    return apply(entity, row);
  }

  Map<String, Object?> encode(T entity) => {
        for (final column in columns) column.sqlName: column.readEncoded(entity)
      };
}

enum ForeignKeyAction { noAction, restrict, cascade, setNull, setDefault }

final class ForeignKey<C, P> {
  ForeignKey(
      {required this.name,
      required this.child,
      required this.parent,
      required List<Column<C, dynamic>> columns,
      required List<Column<P, dynamic>> targetColumns,
      this.onDelete = ForeignKeyAction.noAction,
      this.onUpdate = ForeignKeyAction.noAction,
      this.deferred = false})
      : columns = List.unmodifiable(columns),
        targetColumns = List.unmodifiable(targetColumns) {
    _ormValidateName(name);
    if (columns.isEmpty ||
        columns.length != targetColumns.length ||
        columns.toSet().length != columns.length ||
        targetColumns.toSet().length != targetColumns.length ||
        !columns.every(child.columns.contains) ||
        !targetColumns.every(parent.columns.contains)) {
      throw const OrmMappingException(
          'Foreign key columns must belong to their entities with equal nonzero width');
    }
    for (var i = 0; i < columns.length; i++) {
      if (!identical(_ormBaseCodec(columns[i].codec),
          _ormBaseCodec(targetColumns[i].codec))) {
        throw const OrmMappingException('Foreign key codecs must agree');
      }
    }
    final target = targetColumns.toSet();
    bool matches(List<Column<P, dynamic>> candidate) =>
        candidate.length == target.length && target.containsAll(candidate);
    if (!matches(parent.keys) &&
        !(targetColumns.length == 1 && targetColumns.single.unique) &&
        !parent.indexes
            .any((index) => index.unique && matches(index.columns))) {
      throw const OrmMappingException('Foreign key target must be unique');
    }
    for (final action in [onDelete, onUpdate]) {
      if (action == ForeignKeyAction.setNull &&
          columns.any((column) => !column.nullable)) {
        throw const OrmMappingException(
            'SET NULL requires nullable child columns');
      }
      if (action == ForeignKeyAction.setDefault &&
          columns
              .any((column) => !column.nullable && column.defaultSql == null)) {
        throw const OrmMappingException(
            'SET DEFAULT requires defaults or nullable child columns');
      }
    }
  }
  final String name;
  final EntityType<C> child;
  final EntityType<P> parent;
  final List<Column<C, dynamic>> columns;
  final List<Column<P, dynamic>> targetColumns;
  final ForeignKeyAction onDelete;
  final ForeignKeyAction onUpdate;
  final bool deferred;
}

final class DbModel {
  DbModel(List<EntityType<dynamic>> entities,
      {List<ForeignKey<dynamic, dynamic>> foreignKeys = const []})
      : entities = List.unmodifiable(entities),
        foreignKeys = List.unmodifiable(foreignKeys) {
    final names = <String>{};
    for (final entity in entities) {
      if (!names.add(_ormAsciiLower(entity.tableName))) {
        throw const OrmMappingException('Duplicate mapped schema name');
      }
      for (final index in entity.indexes) {
        if (!names.add(_ormAsciiLower(index.name))) {
          throw const OrmMappingException('Duplicate mapped schema name');
        }
      }
    }
    final relationNames = <EntityType<dynamic>, Set<String>>{};
    for (final key in foreignKeys) {
      if (!entities.contains(key.child) ||
          !entities.contains(key.parent) ||
          !(relationNames[key.child] ??= {}).add(_ormAsciiLower(key.name))) {
        throw const OrmMappingException(
            'Foreign key entities must be registered and names unique per child');
      }
    }
  }
  final List<EntityType<dynamic>> entities;
  final List<ForeignKey<dynamic, dynamic>> foreignKeys;
}

final class EntityKey {
  EntityKey(List<Object?> values)
      : _values = List.unmodifiable(values.map(copyOrmValue));
  final List<Object?> _values;
  List<Object?> get values => List.unmodifiable(_values.map(copyOrmValue));
  @override
  bool operator ==(Object other) =>
      other is EntityKey &&
      other._values.length == _values.length &&
      Iterable<int>.generate(_values.length).every(
          (index) => ormValuesEqual(_values[index], other._values[index]));
  @override
  int get hashCode => Object.hashAll(_values
      .map((value) => value is Uint8List ? Object.hashAll(value) : value));
}
