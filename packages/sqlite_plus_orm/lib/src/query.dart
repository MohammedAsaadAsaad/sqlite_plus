part of '../sqlite_plus_orm.dart';

/// A context supplies this function to serialize a complete query operation.
typedef OrmOperationRunner = Future<R> Function<R>(Future<R> Function());

/// An immutable predicate built from mapped columns and bound values.
sealed class SqlPredicate<T> {
  const SqlPredicate();

  SqlPredicate<T> operator &(SqlPredicate<T> other) =>
      _LogicalPredicate('AND', this, other);
  SqlPredicate<T> operator |(SqlPredicate<T> other) =>
      _LogicalPredicate('OR', this, other);
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
  final Column<T, dynamic> column;
  final bool descending;
  final bool? nullsFirst;
  String get _sql => '${quoteIdentifier(column.sqlName)} '
      '${descending ? 'DESC' : 'ASC'}'
      '${nullsFirst == null ? '' : nullsFirst! ? ' NULLS FIRST' : ' NULLS LAST'}';
}

extension ColumnQueryExpressions<T, V> on Column<T, V> {
  SqlPredicate<T> eq(V value) =>
      _ComparisonPredicate(this, '=', encodeValue(value));
  SqlPredicate<T> notEq(V value) =>
      _ComparisonPredicate(this, '<>', encodeValue(value));
  SqlPredicate<T> lt(V value) =>
      _ComparisonPredicate(this, '<', encodeValue(value));
  SqlPredicate<T> lte(V value) =>
      _ComparisonPredicate(this, '<=', encodeValue(value));
  SqlPredicate<T> gt(V value) =>
      _ComparisonPredicate(this, '>', encodeValue(value));
  SqlPredicate<T> gte(V value) =>
      _ComparisonPredicate(this, '>=', encodeValue(value));
  SqlPredicate<T> isNull() => _NullPredicate(this, false);
  SqlPredicate<T> isNotNull() => _NullPredicate(this, true);
  SqlPredicate<T> inValues(Iterable<V> values) =>
      _InPredicate(this, values.map(encodeValue).toList());
  SqlOrdering<T> asc({bool? nullsFirst}) =>
      SqlOrdering._(this, false, nullsFirst);
  SqlOrdering<T> desc({bool? nullsFirst}) =>
      SqlOrdering._(this, true, nullsFirst);
}

/// A mapped column used from a Dart closure. Equality is [equalTo] because
/// Dart's `==` must return `bool` and cannot build a predicate. Parenthesize
/// comparison operators before combining them with `&` or `|`.
final class MappedField<T, V> {
  const MappedField(this.column);
  final Column<T, V> column;

  SqlPredicate<T> equalTo(V value) => column.eq(value);
  SqlPredicate<T> notEqualTo(V value) => column.notEq(value);
  SqlPredicate<T> operator >(V value) => column.gt(value);
  SqlPredicate<T> operator <(V value) => column.lt(value);
  SqlPredicate<T> operator >=(V value) => column.gte(value);
  SqlPredicate<T> operator <=(V value) => column.lte(value);
  SqlPredicate<T> oneOf(Iterable<V> values) => column.inValues(values);
  SqlPredicate<T> get isNull => column.isNull();
  SqlPredicate<T> get isNotNull => column.isNotNull();
  SqlOrdering<T> get ascending => column.asc();
  SqlOrdering<T> get descending => column.desc();

  /// JSON path read through `json_extract`. The path is a bound parameter.
  JsonPathField<T> at(String path) => JsonPathField(column, path);
}

/// A JSON path on a mapped column. Comparisons bind both the path and the value.
final class JsonPathField<T> {
  const JsonPathField(this.column, this.path);
  final Column<T, dynamic> column;
  final String path;

  SqlPredicate<T> equalTo(Object? value) =>
      _JsonExtractPredicate(column, path, '=', value);
  SqlPredicate<T> notEqualTo(Object? value) =>
      _JsonExtractPredicate(column, path, '<>', value);
  SqlPredicate<T> operator >(Object? value) =>
      _JsonExtractPredicate(column, path, '>', value);
  SqlPredicate<T> operator <(Object? value) =>
      _JsonExtractPredicate(column, path, '<', value);
  SqlPredicate<T> operator >=(Object? value) =>
      _JsonExtractPredicate(column, path, '>=', value);
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
  final String sql;
  final List<Object?> _parameters;
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
        _noTracking = false;

  TypedQuery._(
      this.type,
      this.connection,
      this._materialize,
      this._serialize,
      this._predicate,
      this._ordering,
      this._offset,
      this._limit,
      this._noTracking);

  final EntityType<T> type;
  final OrmConnection connection;
  final T Function(RowReader)? _materialize;
  final OrmOperationRunner? _serialize;
  final SqlPredicate<T>? _predicate;
  final List<SqlOrdering<T>> _ordering;
  final int _offset;
  final int? _limit;
  final bool _noTracking;

  TypedQuery<T> _copy(
          {SqlPredicate<T>? predicate,
          List<SqlOrdering<T>>? ordering,
          int? offset,
          int? limit,
          bool? noTracking}) =>
      TypedQuery._(
          type,
          connection,
          _materialize,
          _serialize,
          predicate ?? _predicate,
          ordering ?? _ordering,
          offset ?? _offset,
          limit ?? _limit,
          noTracking ?? _noTracking);

  void _validateColumns(Iterable<Column<T, dynamic>> columns) {
    if (columns.any((candidate) =>
        !type.columns.any((column) => identical(column, candidate)))) {
      throw const OrmMappingException(
          'Query column belongs to another mapping');
    }
  }

  TypedQuery<T> where(SqlPredicate<T> predicate) {
    _validateColumns(predicate._columns);
    return _copy(
        predicate: _predicate == null ? predicate : _predicate & predicate);
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

  TypedQuery<T> take(int count) {
    _validatePagination(count);
    return _copy(limit: _limit == null || count < _limit ? count : _limit);
  }

  TypedQuery<T> asNoTracking() => _copy(noTracking: true);

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
    if (_ordering.isNotEmpty) {
      sql.write(' ORDER BY ${_ordering.map((term) => term._sql).join(', ')}');
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

  Future<List<T>> toList() => _run(() async {
        final result = await _rows();
        return [for (final row in result.rows) _read(result, row)];
      });

  Future<T?> firstOrNull() => _run(() async {
        final result = await take(1)._rows();
        return result.rows.isEmpty ? null : _read(result, result.rows.first);
      });

  Future<T> single() => _run(() async {
        final result = await take(2)._rows();
        if (result.rows.length != 1) {
          throw OrmStateException(result.rows.isEmpty
              ? 'Expected one entity but the query returned none'
              : 'Expected one entity but the query returned multiple');
        }
        return _read(result, result.rows.single);
      });

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

  Future<bool> any() =>
      _run(() async => (await take(1)._rows()).rows.isNotEmpty);
}
