part of '../sqlite_plus_orm.dart';

String _ormAsciiLower(String value) => String.fromCharCodes(
    value.codeUnits.map((unit) => unit >= 65 && unit <= 90 ? unit + 32 : unit));

void _ormValidateName(String name) {
  if (name.isEmpty || name.contains('\u0000')) {
    throw const OrmMappingException('Identifiers must be nonempty without NUL');
  }
}

/// Quotes [identifier] as a SQL delimited identifier.
String quoteIdentifier(String identifier) {
  _ormValidateName(identifier);
  return '"${identifier.replaceAll('"', '""')}"';
}

/// One mapped property: its SQL name, codec, and how to read or write it.
final class Column<T, V> {
  /// [property] is the Dart name. [name] overrides the SQL column name.
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

  /// Dart property name.
  final String property;

  /// SQL column name.
  final String sqlName;

  /// Converts between the Dart property and the stored value.
  final ValueCodec<V> codec;

  /// Reads the property from an entity.
  final V Function(T) read;

  /// Writes the property. Null when the column is immutable.
  final void Function(T, V)? write;

  /// Primary-key position, starting at zero. Null when this is not a key.
  final int? keyOrder;

  /// Whether the engine assigns this nullable integer key on insert.
  final bool generated;

  /// Whether this integer is incremented on update.
  final bool version;

  /// SQL default text, or null when the column has no default.
  final String? defaultSql;

  /// Whether the column is declared `UNIQUE`.
  final bool unique;

  /// Whether the codec accepts SQL `NULL`.
  bool get nullable => codec.nullable;

  /// Encodes [value] and copies the stored form.
  Object? encodeValue(Object? value) {
    try {
      return copyOrmValue(codec.encode(value as V));
    } catch (error) {
      throw OrmCodecException('Cannot encode property $property', error);
    }
  }

  /// Decodes a stored [value] into the property type.
  V decodeValue(Object? value) {
    try {
      return codec.decode(copyOrmValue(value));
    } catch (error) {
      throw OrmCodecException('Cannot decode property $property', error);
    }
  }

  /// Reads [entity] and returns the stored form.
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

  /// Decodes [value] and writes it through the property setter.
  void writeEncoded(T entity, Object? value) {
    final setter = write;
    if (setter == null) {
      throw OrmMappingException('Property $property is read-only');
    }
    setter(entity, decodeValue(value));
  }
}

/// Decodes one stored row through column metadata.
final class RowReader {
  /// Copies [values] using case-insensitive SQL column names.
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

  /// Decodes [column] from this row.
  V read<T, V>(Column<T, V> column) => column.decodeValue(raw(column.sqlName));

  /// Stored value for [sqlName], copied so the caller cannot alias the row.
  Object? raw(String sqlName) {
    final key = _ormAsciiLower(sqlName);
    if (!_values.containsKey(key)) {
      throw OrmMappingException('Missing row column $sqlName');
    }
    return copyOrmValue(_values[key]);
  }
}

/// A secondary index declared on an [EntityType].
final class OrmIndex<T> {
  /// [name] is the SQL index name. [columns] must be distinct and nonempty.
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

  /// SQL index name.
  final String name;

  /// Indexed columns, in index order.
  final List<Column<T, dynamic>> columns;

  /// Whether the index is unique.
  final bool unique;
}

/// Table mapping: columns, factory, and optional store-value writer.
final class EntityType<T> {
  /// [tableName] is the SQL name. [create] builds an entity from a row.
  EntityType(
      {required this.tableName,
      required List<Column<T, dynamic>> columns,
      required this.create,
      this.applyStoreValues,
      this.virtualModule,
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
    _validateVirtualModule();
  }

  /// SQL table name.
  final String tableName;

  /// `fts5`, `rtree`, or null for an ordinary table.
  final String? virtualModule;

  /// Mapped columns, including keys.
  final List<Column<T, dynamic>> columns;

  /// Builds an entity from a stored row.
  final T Function(RowReader) create;

  /// Writes stored values back onto an existing entity, when it is mutable.
  final T Function(T, RowReader)? applyStoreValues;

  /// Secondary indexes.
  final List<OrmIndex<T>> indexes;

  /// Primary-key columns in key order.
  late final List<Column<T, dynamic>> keys;

  /// The generated primary key, or null.
  late final Column<T, dynamic>? generatedKey;

  /// The version column, or null.
  late final Column<T, dynamic>? versionColumn;

  /// The entity type [T].
  Type get dartType => T;

  /// Whether [applyStoreValues] was supplied.
  bool get canApplyStoreValues => applyStoreValues != null;

  /// Applies a stored row to [entity].
  T applyValues(T entity, RowReader row) {
    final apply = applyStoreValues;
    if (apply == null) {
      throw const OrmMappingException(
          'No store-value reconstruction is mapped');
    }
    return apply(entity, row);
  }

  /// Encoded column values for [entity], keyed by SQL name.
  Map<String, Object?> encode(T entity) => {
        for (final column in columns) column.sqlName: column.readEncoded(entity)
      };

  void _validateVirtualModule() {
    final module = virtualModule;
    if (module == null) return;
    if (module != 'fts5' && module != 'rtree') {
      throw const OrmMappingException('Virtual module must be fts5 or rtree');
    }
    if (indexes.isNotEmpty || versionColumn != null) {
      throw const OrmMappingException(
          'A virtual table cannot map indexes or a version column');
    }
    if (columns.any((column) => column.unique || column.defaultSql != null)) {
      throw const OrmMappingException(
          'A virtual table cannot map unique or default constraints');
    }
    if (module == 'fts5') {
      final content = columns.where((column) => column.keyOrder == null);
      if (keys.length != 1 ||
          _ormAsciiLower(keys.single.sqlName) != 'rowid' ||
          content.isEmpty ||
          content.any((column) => column.codec.sqlType != 'TEXT')) {
        throw const OrmMappingException(
            'fts5 needs one rowid key and one or more TEXT columns');
      }
      return;
    }
    final coordinates = columns.skip(1).toList();
    if (generatedKey != null ||
        keys.length != 1 ||
        !identical(columns.first, keys.single) ||
        keys.single.codec.sqlType != 'INTEGER' ||
        coordinates.length < 2 ||
        coordinates.length.isOdd ||
        coordinates.length > 10 ||
        coordinates.any((column) => column.codec.sqlType != 'REAL')) {
      throw const OrmMappingException(
          'rtree needs an integer key first and an even number of REAL coordinates');
    }
  }
}

/// SQL action for a foreign-key delete or update.
enum ForeignKeyAction { noAction, restrict, cascade, setNull, setDefault }

/// A foreign key from [child] columns to a unique parent key.
final class ForeignKey<C, P> {
  /// [columns] and [targetColumns] must have the same width and codecs.
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

  /// Constraint name.
  final String name;

  /// Entity that stores the foreign key.
  final EntityType<C> child;

  /// Entity that owns the referenced key.
  final EntityType<P> parent;

  /// Child columns, in constraint order.
  final List<Column<C, dynamic>> columns;

  /// Parent columns, in constraint order.
  final List<Column<P, dynamic>> targetColumns;

  /// Action when the parent row is deleted.
  final ForeignKeyAction onDelete;

  /// Action when the parent key is updated.
  final ForeignKeyAction onUpdate;

  /// Whether the constraint is deferred until commit.
  final bool deferred;
}

/// The entities and foreign keys that form one schema.
final class DbModel {
  /// [entities] and [foreignKeys] are copied and validated.
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
      if (key.child.virtualModule != null || key.parent.virtualModule != null) {
        throw const OrmMappingException(
            'Virtual tables cannot be foreign key endpoints');
      }
    }
  }

  /// Mapped entities.
  final List<EntityType<dynamic>> entities;

  /// Foreign keys between [entities].
  final List<ForeignKey<dynamic, dynamic>> foreignKeys;
}

/// A copied primary-key value list.
final class EntityKey {
  /// Copies [values] so later caller edits do not change the key.
  EntityKey(List<Object?> values)
      : _values = List.unmodifiable(values.map(copyOrmValue));
  final List<Object?> _values;

  /// A fresh copy of the key values.
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
