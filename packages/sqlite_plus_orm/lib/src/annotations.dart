part of '../sqlite_plus_orm.dart';

/// Selects a class for generation and optional virtual-table storage.
class DbEntity {
  /// [table] overrides the SQL name.
  ///
  /// [module] is a virtual-table module. Use [DbModules] for the modules
  /// this ORM creates: [DbModules.fts5], [DbModules.rtree], and
  /// [DbModules.vec0]. The value is a [String], so `'fts5'` is the same as
  /// [DbModules.fts5].
  ///
  /// [tokenizer] is the FTS5 `tokenize` name. Use [DbTokenizers] for the
  /// built-in names. A registered tokenizer such as `'arabic'` is written
  /// as a string. It is valid only when [module] is [DbModules.fts5].
  const DbEntity({this.table, this.module, this.tokenizer});

  /// SQL table name. The class name is used when this is null.
  final String? table;

  /// [DbModules.fts5], [DbModules.rtree], [DbModules.vec0], or the same text.
  ///
  /// Omitted models stay ordinary tables.
  final String? module;

  /// FTS5 tokenizer name. See [DbTokenizers].
  ///
  /// Null keeps the engine default. Any other SQL identifier is kept so a
  /// package can register it before the table is created.
  final String? tokenizer;
}

/// Marks an instance method or getter as a SQL scalar.
///
/// The body reads mapped fields. The generated query calls it with no
/// arguments, and the runtime passes those fields in for each row.
class DbScalar {
  /// The body is a pure function of the mapped fields it reads.
  const DbScalar();
}

/// Marks one `List<double>` column of a [DbModules.vec0] table.
class DbVector {
  /// [dimensions] is `float[N]`. [metric] is [DbVectorMetrics.l2] unless
  /// another identifier is written.
  const DbVector(this.dimensions, {this.metric = DbVectorMetrics.l2});

  /// Number of float32 coordinates. From [DbVectorLimits.minimumDimensions]
  /// through [DbVectorLimits.maximumDimensions].
  final int dimensions;

  /// `distance_metric` stored in the `CREATE VIRTUAL TABLE` statement.
  ///
  /// [DbVectorMetrics.l2] and [DbVectorMetrics.cosine] are implemented by
  /// `sqlite_plus_vec`. Another identifier is accepted here and checked when
  /// that package creates the table.
  final String metric;
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
