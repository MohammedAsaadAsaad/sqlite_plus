part of '../sqlite_plus_orm.dart';

/// Selects a class for generation and optional virtual-table storage.
class DbEntity {
  /// [table] overrides the SQL name. [module] is `fts5` or `rtree`.
  const DbEntity({this.table, this.module});

  /// SQL table name. The class name is used when this is null.
  final String? table;

  /// `fts5` or `rtree`. Omitted models stay ordinary tables.
  final String? module;
}

/// Marks one TEXT column for a generated JSON path helper.
class DbJson {
  /// Marks the annotated `String` field as JSON text.
  const DbJson();
}

/// Overrides the SQL column derived from a field.
class DbColumn {
  /// [name] is the SQL column. [defaultSql] is emitted as a column default.
  const DbColumn({this.name, this.defaultSql, this.unique = false});

  /// SQL column name. The Dart field name is used when this is null.
  final String? name;

  /// SQL default expression, stored as text and not executed by the generator.
  final String? defaultSql;

  /// Whether the column is declared `UNIQUE`.
  final bool unique;
}

/// Leaves a field out of the generated table.
class DbIgnore {
  /// Skips the annotated field.
  const DbIgnore();
}

/// Marks a field as part of the primary key.
class DbKey {
  /// [order] starts at zero. [generated] asks the engine to assign the key.
  const DbKey({this.order = 0, this.generated = false});

  /// Position in a composite key.
  final int order;

  /// Whether a nullable integer key is assigned on insert.
  final bool generated;
}

/// Marks the integer revision column incremented on update.
class DbVersion {
  /// The field must be a non-nullable `int` or `BigInt` that is not a key.
  const DbVersion();
}

/// Declares a foreign key from this field to [target].
class DbReference {
  /// [target] is the parent model type. [column] names its key property.
  const DbReference(this.target,
      {this.column, this.onDelete = ForeignKeyAction.noAction});

  /// Parent model type.
  final Type target;

  /// Target Dart property name; omitted for a single primary key.
  final String? column;

  /// Action applied when the parent row is deleted.
  final ForeignKeyAction onDelete;
}
