part of '../sqlite_plus_orm.dart';

/// A context supplies this function to serialize a complete query operation.
typedef OrmOperationRunner = Future<R> Function<R>(Future<R> Function());

/// An immutable predicate built from mapped columns and bound values.
sealed class SqlPredicate<T> {
  const SqlPredicate();

  /// Both predicates, combined with `AND`.
  SqlPredicate<T> operator &(SqlPredicate<T> other) =>
      _LogicalPredicate('AND', this, other);

  /// Either predicate, combined with `OR`.
  SqlPredicate<T> operator |(SqlPredicate<T> other) =>
      _LogicalPredicate('OR', this, other);

  /// Negates this predicate.
  SqlPredicate<T> not() => _NotPredicate(this);

  Iterable<Column<T, dynamic>> get _columns;
  String _sql(List<Object?> parameters);
}

final class _ComparisonPredicate<T> extends SqlPredicate<T> {
  _ComparisonPredicate(this.column, this.operator, Object? value)
      : value = copyOrmValue(value);
  final Column<T, dynamic> column;
  final String operator;
  final Object? value;

  @override
  Iterable<Column<T, dynamic>> get _columns => [column];
  @override
  String _sql(List<Object?> parameters) {
    if (value == null && (operator == '=' || operator == '<>')) {
      return '${quoteIdentifier(column.sqlName)} IS ${operator == '<>' ? 'NOT ' : ''}NULL';
    }
    parameters.add(copyOrmValue(value));
    return '${quoteIdentifier(column.sqlName)} $operator ?';
  }
}

final class _NullPredicate<T> extends SqlPredicate<T> {
  const _NullPredicate(this.column, this.negate);
  final Column<T, dynamic> column;
  final bool negate;
  @override
  Iterable<Column<T, dynamic>> get _columns => [column];
  @override
  String _sql(List<Object?> parameters) =>
      '${quoteIdentifier(column.sqlName)} IS ${negate ? 'NOT ' : ''}NULL';
}

final class _InPredicate<T> extends SqlPredicate<T> {
  _InPredicate(this.column, List<Object?> values)
      : values = List.unmodifiable(values.map(copyOrmValue));
  final Column<T, dynamic> column;
  final List<Object?> values;
  @override
  Iterable<Column<T, dynamic>> get _columns => [column];
  @override
  String _sql(List<Object?> parameters) {
    if (values.isEmpty) return '0';
    parameters.addAll(values.map(copyOrmValue));
    return '${quoteIdentifier(column.sqlName)} IN (${List.filled(values.length, '?').join(', ')})';
  }
}

final class _LogicalPredicate<T> extends SqlPredicate<T> {
  const _LogicalPredicate(this.operator, this.left, this.right);
  final String operator;
  final SqlPredicate<T> left;
  final SqlPredicate<T> right;
  @override
  Iterable<Column<T, dynamic>> get _columns =>
      [...left._columns, ...right._columns];
  @override
  String _sql(List<Object?> parameters) =>
      '(${left._sql(parameters)} $operator ${right._sql(parameters)})';
}

final class _MatchPredicate<T> extends SqlPredicate<T> {
  _MatchPredicate(this.table, this.text);
  final String table;
  final String text;

  @override
  Iterable<Column<T, dynamic>> get _columns => const [];
  @override
  String _sql(List<Object?> parameters) {
    parameters.add(text);
    return '${quoteIdentifier(table)} MATCH ?';
  }
}

/// A rectangle in the same coordinate space as an rtree table.
final class Rect {
  /// Inclusive bounds of one rectangle.
  const Rect(
      {required this.minX,
      required this.minY,
      required this.maxX,
      required this.maxY});

  /// Left edge.
  final double minX;

  /// Bottom edge.
  final double minY;

  /// Right edge.
  final double maxX;

  /// Top edge.
  final double maxY;
}

/// Bound comparisons for an rtree. The caller does not write the SQL.
final class Bounds<T> {
  /// The four rtree coordinate columns.
  const Bounds(
      {required this.minX,
      required this.maxX,
      required this.minY,
      required this.maxY});

  /// Column storing the minimum X of a stored box.
  final Column<T, double> minX;

  /// Column storing the maximum X of a stored box.
  final Column<T, double> maxX;

  /// Column storing the minimum Y of a stored box.
  final Column<T, double> minY;

  /// Column storing the maximum Y of a stored box.
  final Column<T, double> maxY;

  /// Rows whose box overlaps [rect].
  SqlPredicate<T> intersects(Rect rect) =>
      minX.lte(rect.maxX) &
      maxX.gte(rect.minX) &
      minY.lte(rect.maxY) &
      maxY.gte(rect.minY);
}

/// A mapped table whose [search] stays in Dart.
final class MappedTable<T> {
  /// [type] is the mapping. [connection] runs the generated `MATCH` query.
  MappedTable(this.type, this.connection);

  /// Entity mapping for this table.
  final EntityType<T> type;

  /// Connection that executes the search.
  final OrmConnection connection;

  /// Rows whose FTS content matches [text].
  TypedQuery<T> search(String text) =>
      TypedQuery(type: type, connection: connection).search(text);
}

final class _NotPredicate<T> extends SqlPredicate<T> {
  const _NotPredicate(this.predicate);
  final SqlPredicate<T> predicate;
  @override
  Iterable<Column<T, dynamic>> get _columns => predicate._columns;
  @override
  String _sql(List<Object?> parameters) =>
      'NOT (${predicate._sql(parameters)})';
}

/// One mapped ordering term. SQL's default NULL placement is preserved unless
/// [nullsFirst] is supplied.
final class SqlOrdering<T> {
  const SqlOrdering._(this.column, this.descending, this.nullsFirst);

  /// Column being ordered.
  final Column<T, dynamic> column;

  /// Whether the term is `DESC`.
  final bool descending;

  /// `NULLS FIRST`, `NULLS LAST`, or null for SQLite's default placement.
  final bool? nullsFirst;
  String get _sql => '${quoteIdentifier(column.sqlName)} '
      '${descending ? 'DESC' : 'ASC'}'
      '${nullsFirst == null ? '' : nullsFirst! ? ' NULLS FIRST' : ' NULLS LAST'}';
}

/// Bound comparisons and orderings on a [Column].
extension ColumnQueryExpressions<T, V> on Column<T, V> {
  /// `column = ?`.
  SqlPredicate<T> eq(V value) =>
      _ComparisonPredicate(this, '=', encodeValue(value));

  /// `column <> ?`.
  SqlPredicate<T> notEq(V value) =>
      _ComparisonPredicate(this, '<>', encodeValue(value));

  /// `column < ?`.
  SqlPredicate<T> lt(V value) =>
      _ComparisonPredicate(this, '<', encodeValue(value));

  /// `column <= ?`.
  SqlPredicate<T> lte(V value) =>
      _ComparisonPredicate(this, '<=', encodeValue(value));

  /// `column > ?`.
  SqlPredicate<T> gt(V value) =>
      _ComparisonPredicate(this, '>', encodeValue(value));

  /// `column >= ?`.
  SqlPredicate<T> gte(V value) =>
      _ComparisonPredicate(this, '>=', encodeValue(value));

  /// `column IS NULL`.
  SqlPredicate<T> isNull() => _NullPredicate(this, false);

  /// `column IS NOT NULL`.
  SqlPredicate<T> isNotNull() => _NullPredicate(this, true);

  /// `column IN (...)` with one bound value per element.
  SqlPredicate<T> inValues(Iterable<V> values) =>
      _InPredicate(this, values.map(encodeValue).toList());

  /// Ascending order. [nullsFirst] selects `NULLS FIRST` or `NULLS LAST`.
  SqlOrdering<T> asc({bool? nullsFirst}) =>
      SqlOrdering._(this, false, nullsFirst);

  /// Descending order. [nullsFirst] selects `NULLS FIRST` or `NULLS LAST`.
  SqlOrdering<T> desc({bool? nullsFirst}) =>
      SqlOrdering._(this, true, nullsFirst);
}

/// A mapped column used from a Dart closure. Equality is [equalTo] because
/// Dart's `==` must return `bool` and cannot build a predicate. Parenthesize
/// comparison operators before combining them with `&` or `|`.
final class MappedField<T, V> {
  /// Wraps [column] for closure syntax.
  const MappedField(this.column);

  /// The mapped column.
  final Column<T, V> column;

  /// `column = ?`.
  SqlPredicate<T> equalTo(V value) => column.eq(value);

  /// `column <> ?`.
  SqlPredicate<T> notEqualTo(V value) => column.notEq(value);

  /// `column > ?`.
  SqlPredicate<T> operator >(V value) => column.gt(value);

  /// `column < ?`.
  SqlPredicate<T> operator <(V value) => column.lt(value);

  /// `column >= ?`.
  SqlPredicate<T> operator >=(V value) => column.gte(value);

  /// `column <= ?`.
  SqlPredicate<T> operator <=(V value) => column.lte(value);

  /// `column IN (...)`.
  SqlPredicate<T> oneOf(Iterable<V> values) => column.inValues(values);

  /// `column IS NULL`.
  SqlPredicate<T> get isNull => column.isNull();

  /// `column IS NOT NULL`.
  SqlPredicate<T> get isNotNull => column.isNotNull();

  /// Ascending order of this column.
  SqlOrdering<T> get ascending => column.asc();

  /// Descending order of this column.
  SqlOrdering<T> get descending => column.desc();

  /// JSON path read through `json_extract`. The path is a bound parameter.
  JsonPathField<T> at(String path) => JsonPathField(column, path);
}

/// A JSON path on a mapped column. Comparisons bind both the path and the value.
final class JsonPathField<T> {
  /// [path] is bound, not interpolated.
  const JsonPathField(this.column, this.path);

  /// JSON text column.
  final Column<T, dynamic> column;

  /// JSON path passed to `json_extract`.
  final String path;

  /// `json_extract(column, ?) = ?`.
  SqlPredicate<T> equalTo(Object? value) =>
      _JsonExtractPredicate(column, path, '=', value);

  /// `json_extract(column, ?) <> ?`.
  SqlPredicate<T> notEqualTo(Object? value) =>
      _JsonExtractPredicate(column, path, '<>', value);

  /// `json_extract(column, ?) > ?`.
  SqlPredicate<T> operator >(Object? value) =>
      _JsonExtractPredicate(column, path, '>', value);

  /// `json_extract(column, ?) < ?`.
  SqlPredicate<T> operator <(Object? value) =>
      _JsonExtractPredicate(column, path, '<', value);

  /// `json_extract(column, ?) >= ?`.
  SqlPredicate<T> operator >=(Object? value) =>
      _JsonExtractPredicate(column, path, '>=', value);

  /// `json_extract(column, ?) <= ?`.
  SqlPredicate<T> operator <=(Object? value) =>
      _JsonExtractPredicate(column, path, '<=', value);
}

final class _JsonExtractPredicate<T> extends SqlPredicate<T> {
  _JsonExtractPredicate(this.column, this.path, this.operator, Object? value)
      : value = copyOrmValue(value);
  final Column<T, dynamic> column;
  final String path;
  final String operator;
  final Object? value;

  @override
  Iterable<Column<T, dynamic>> get _columns => [column];

  @override
  String _sql(List<Object?> parameters) {
    parameters.add(path);
    final sqlName = quoteIdentifier(column.sqlName);
    if (value == null && (operator == '=' || operator == '<>')) {
      return 'json_extract($sqlName, ?) IS ${operator == '<>' ? 'NOT ' : ''}NULL';
    }
    parameters.add(copyOrmValue(value));
    return 'json_extract($sqlName, ?) $operator ?';
  }
}

/// Reviewable generated SQL. Bound blobs are copied on every ownership boundary.
final class OrmQueryCommand {
  OrmQueryCommand._(this.sql, List<Object?> parameters)
      : _parameters = List.unmodifiable(parameters.map(copyOrmValue));

  /// SQL text with `?` placeholders.
  final String sql;
  final List<Object?> _parameters;

  /// A fresh copy of the bound parameters.
  List<Object?> get parameters =>
      List.unmodifiable(_parameters.map(copyOrmValue));
}

/// Immutable single-entity SQL query builder. Filters and ordering describe SQL
/// clauses before pagination. Repeated skip/take operations compose a bounded
/// interval; counts use the same interval.
final class TypedQuery<T> {
  TypedQuery(
      {required this.type,
      required this.connection,
      T Function(RowReader)? materialize,
      OrmOperationRunner? serialize})
      : _materialize = materialize,
        _serialize = serialize,
        _predicate = null,
        _ordering = const [],
        _offset = 0,
        _limit = null,
        _noTracking = false,
        _rank = false;

  TypedQuery._(
      this.type,
      this.connection,
      this._materialize,
      this._serialize,
      this._predicate,
      this._ordering,
      this._offset,
      this._limit,
      this._noTracking,
      this._rank);

  /// Mapping this query reads.
  final EntityType<T> type;

  /// Connection that runs the statement.
  final OrmConnection connection;
  final T Function(RowReader)? _materialize;
  final OrmOperationRunner? _serialize;
  final SqlPredicate<T>? _predicate;
  final List<SqlOrdering<T>> _ordering;
  final int _offset;
  final int? _limit;
  final bool _noTracking;
  final bool _rank;

  TypedQuery<T> _copy(
          {SqlPredicate<T>? predicate,
          List<SqlOrdering<T>>? ordering,
          int? offset,
          int? limit,
          bool? noTracking,
          bool? rank}) =>
      TypedQuery._(
          type,
          connection,
          _materialize,
          _serialize,
          predicate ?? _predicate,
          ordering ?? _ordering,
          offset ?? _offset,
          limit ?? _limit,
          noTracking ?? _noTracking,
          rank ?? _rank);

  void _validateColumns(Iterable<Column<T, dynamic>> columns) {
    if (columns.any((candidate) =>
        !type.columns.any((column) => identical(column, candidate)))) {
      throw const OrmMappingException(
          'Query column belongs to another mapping');
    }
  }

  /// Adds [predicate] with `AND` when a filter already exists.
  TypedQuery<T> where(SqlPredicate<T> predicate) {
    _validateColumns(predicate._columns);
    return _copy(
        predicate: _predicate == null ? predicate : _predicate & predicate);
  }

  /// Binds [text] to `table MATCH ?` and orders by FTS rank first.
  TypedQuery<T> search(String text) {
    final predicate = _MatchPredicate<T>(type.tableName, text);
    return _copy(
        predicate: _predicate == null ? predicate : _predicate & predicate,
        rank: true);
  }

  /// Replaces ordering; supply all ordering terms in their priority order.
  TypedQuery<T> orderBy(List<SqlOrdering<T>> ordering) {
    _validateColumns(ordering.map((term) => term.column));
    return _copy(ordering: List.unmodifiable(ordering));
  }

  // A Dart int used as a row count must be exact on both VM and JavaScript.
  static const _maximumPagination = 9007199254740991;
  static void _validatePagination(int count) {
    if (count < 0 || count > _maximumPagination) {
      throw RangeError.range(count, 0, _maximumPagination, 'count');
    }
  }

  /// Skips [count] rows. Combined with [take], the bounds stay portable.
  TypedQuery<T> skip(int count) {
    _validatePagination(count);
    final offset = BigInt.from(_offset) + BigInt.from(count);
    if (offset > BigInt.from(_maximumPagination)) {
      throw RangeError('Combined offset exceeds the portable integer range');
    }
    final remaining = _limit == null
        ? null
        : count >= _limit
            ? 0
            : _limit - count;
    return _copy(offset: offset.toInt(), limit: remaining);
  }

  /// Limits the query to [count] rows.
  TypedQuery<T> take(int count) {
    _validatePagination(count);
    return _copy(limit: _limit == null || count < _limit ? count : _limit);
  }

  /// Reads rows without placing them in the identity map.
  TypedQuery<T> asNoTracking() => _copy(noTracking: true);

  /// The SQL and parameters this query would run.
  OrmQueryCommand toSql() {
    final parameters = <Object?>[];
    final sql = StringBuffer('SELECT ')
      ..write(type.columns
          .map((column) => quoteIdentifier(column.sqlName))
          .join(', '))
      ..write(' FROM ${quoteIdentifier(type.tableName)}');
    if (_predicate != null) {
      sql.write(' WHERE ${_predicate._sql(parameters)}');
    }
    if (_rank || _ordering.isNotEmpty) {
      sql.write(' ORDER BY ');
      sql.write([if (_rank) 'rank', ..._ordering.map((term) => term._sql)]
          .join(', '));
    }
    if (_limit != null || _offset != 0) {
      sql.write(' LIMIT ?');
      parameters.add(BigInt.from(_limit ?? -1));
      if (_offset != 0) {
        sql.write(' OFFSET ?');
        parameters.add(BigInt.from(_offset));
      }
    }
    return OrmQueryCommand._(sql.toString(), parameters);
  }

  Future<R> _run<R>(Future<R> Function() operation) =>
      _serialize == null ? operation() : _serialize<R>(operation);

  Future<QueryResult> _rows() {
    final command = toSql();
    return connection.query(command.sql, command.parameters);
  }

  T _read(QueryResult result, List<Object?> row) {
    if (row.length != result.columns.length) {
      throw const OrmMappingException('Query row width does not match columns');
    }
    final reader = RowReader({
      for (var index = 0; index < row.length; index++)
        result.columns[index]: row[index]
    });
    return (_noTracking ? type.create : _materialize ?? type.create)(reader);
  }

  /// Materializes every matching row.
  Future<List<T>> toList() => _run(() async {
        final result = await _rows();
        return [for (final row in result.rows) _read(result, row)];
      });

  /// The first row, or null when the query is empty.
  Future<T?> firstOrNull() => _run(() async {
        final result = await take(1)._rows();
        return result.rows.isEmpty ? null : _read(result, result.rows.first);
      });

  /// The only row. Fails when the query returns zero or more than one.
  Future<T> single() => _run(() async {
        final result = await take(2)._rows();
        if (result.rows.length != 1) {
          throw OrmStateException(result.rows.isEmpty
              ? 'Expected one entity but the query returned none'
              : 'Expected one entity but the query returned multiple');
        }
        return _read(result, result.rows.single);
      });

  /// Number of rows matching the filter, as [BigInt].
  Future<BigInt> count() => _run(() async {
        final command = toSql();
        final result = await connection.query(
            'SELECT COUNT(*) FROM (${command.sql}) AS "_orm_count"',
            command.parameters);
        if (result.rows.length != 1 ||
            result.rows.single.length != 1 ||
            result.rows.single.single is! BigInt) {
          throw const OrmMappingException(
              'COUNT returned an invalid SQL value');
        }
        return result.rows.single.single as BigInt;
      });

  /// Whether at least one row matches.
  Future<bool> any() =>
      _run(() async => (await take(1)._rows()).rows.isNotEmpty);
}
