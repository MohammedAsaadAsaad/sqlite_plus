part of '../sqlite_plus_orm.dart';

/// SQL module names the ORM knows how to create.
///
/// [DbEntity.module] is still a [String]. `DbModules.fts5` and `'fts5'` are
/// the same value. A name outside this class is rejected, because the
/// generator has to write the `CREATE VIRTUAL TABLE` statement.
abstract final class DbModules {
  /// FTS5 full-text table.
  ///
  /// The key column is `rowid`. Every other mapped column is text.
  /// [DbEntity.tokenizer] selects the tokenizer. When it is omitted, FTS5
  /// uses its built-in default.
  static const String fts5 = 'fts5';

  /// R-tree of rectangles.
  ///
  /// The first column is an integer key. The coordinates are `minX`, `maxX`,
  /// `minY`, and `maxY`.
  static const String rtree = 'rtree';

  /// One-column vector table implemented by `sqlite_plus_vec`.
  ///
  /// The key column is `rowid`. The other column is a `@DbVector` list of
  /// doubles stored as little-endian float32. Register `SqlitePlusVec` on
  /// the connection before creating or querying the table. `nearest` writes
  /// `column MATCH ? AND k = ?`.
  static const String vec0 = 'vec0';
}

/// Built-in FTS tokenizer names.
///
/// [DbEntity.tokenizer] is still a [String]. These constants are the names
/// the engine already implements. A package may register another name, and
/// that name can be written here as a plain string, for example `'arabic'`.
abstract final class DbTokenizers {
  /// FTS5 default. Unicode letters and numbers, with diacritics removed.
  ///
  /// Arabic letters stay whole tokens. This is not an Arabic stemmer.
  static const String unicode61 = 'unicode61';

  /// Porter stemmer for English, wrapped around unicode61 unless another
  /// parent tokenizer is named in the SQL declaration.
  static const String porter = 'porter';

  /// Overlapping three-character tokens. A query shorter than three
  /// characters does not match.
  static const String trigram = 'trigram';

  /// ASCII letters and digits. This is the FTS3 and FTS4 default.
  static const String ascii = 'ascii';

  /// FTS3 spelling of [ascii]. FTS5 rejects this name.
  static const String simple = 'simple';
}

/// Distance names vec0 stores in `distance_metric`.
///
/// [DbVector.metric] is still a [String]. `l2` and `cosine` are the metrics
/// `sqlite_plus_vec` implements. Another metric can be written as a plain
/// identifier; vec0 rejects it when the table is created.
abstract final class DbVectorMetrics {
  /// Euclidean distance, `sqrt` of the sum of squared coordinate differences.
  ///
  /// This is the default when [DbVector.metric] is omitted.
  static const String l2 = 'l2';

  /// One minus the cosine similarity, in the range 0 to 2.
  ///
  /// Two zero vectors have distance 0. A zero vector beside a non-zero
  /// vector has distance 1.
  static const String cosine = 'cosine';
}

/// Limits shared by a mapped vector column and `TypedQuery.nearest`.
abstract final class DbVectorLimits {
  /// Smallest `float[N]` a mapped vector accepts.
  static const int minimumDimensions = 1;

  /// Largest `float[N]` a mapped vector accepts.
  static const int maximumDimensions = 4096;

  /// Largest `k` accepted by `TypedQuery.nearest`.
  static const int maximumNeighbors = 4096;
}
