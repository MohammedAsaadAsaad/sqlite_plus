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

final class _NearestPredicate<T> extends SqlPredicate<T> {
  _NearestPredicate(this.column, this.vector, this.k);
  final Column<T, dynamic> column;
  final Uint8List vector;
  final int k;

  @override
  Iterable<Column<T, dynamic>> get _columns => [column];

  @override
  String _sql(List<Object?> parameters) {
    parameters
      ..add(Uint8List.fromList(vector))
      ..add(BigInt.from(k));
    return '${quoteIdentifier(column.sqlName)} MATCH ? AND '
        '${quoteIdentifier('k')} = ?';
  }
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

  /// The [k] nearest rows to [vector], ordered by distance.
  TypedQuery<T> nearest(List<double> vector, {int k = 10}) =>
      TypedQuery(type: type, connection: connection).nearest(vector, k: k);
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
  const SqlOrdering._(this.expression, this.descending, this.nullsFirst);

  /// Value being ordered. A column, a JSON path, or a scalar call.
  final SqlExpression<T, dynamic> expression;

  /// Whether the term is `DESC`.
  final bool descending;

  /// `NULLS FIRST`, `NULLS LAST`, or null for SQLite's default placement.
  final bool? nullsFirst;
  String _sql(List<Object?> parameters) =>
      '${expression._sql(parameters)} ${descending ? 'DESC' : 'ASC'}'
      '${nullsFirst == null ? '' : nullsFirst! ? ' NULLS FIRST' : ' NULLS LAST'}';
}

/// A SQL value built from mapped columns. Comparisons bind the right-hand side.
sealed class SqlExpression<T, V> {
  const SqlExpression();

  Iterable<Column<T, dynamic>> get _columns;
  String _sql(List<Object?> parameters);
  Object? _encodeComparison(Object? value);

  /// `expression = ?`, or `IS NULL` when [value] is null.
  SqlPredicate<T> equalTo(Object? value) =>
      _ExpressionComparison(this, '=', value);

  /// `expression <> ?`, or `IS NOT NULL` when [value] is null.
  SqlPredicate<T> notEqualTo(Object? value) =>
      _ExpressionComparison(this, '<>', value);

  /// `expression > ?`.
  SqlPredicate<T> operator >(Object? value) =>
      _ExpressionComparison(this, '>', value);

  /// `expression < ?`.
  SqlPredicate<T> operator <(Object? value) =>
      _ExpressionComparison(this, '<', value);

  /// `expression >= ?`.
  SqlPredicate<T> operator >=(Object? value) =>
      _ExpressionComparison(this, '>=', value);

  /// `expression <= ?`.
  SqlPredicate<T> operator <=(Object? value) =>
      _ExpressionComparison(this, '<=', value);

  /// `expression IN (...)`.
  SqlPredicate<T> oneOf(Iterable<Object?> values) =>
      _ExpressionIn(this, values);

  /// `expression IS NULL`.
  SqlPredicate<T> get isNull => _ExpressionNull(this, false);

  /// `expression IS NOT NULL`.
  SqlPredicate<T> get isNotNull => _ExpressionNull(this, true);

  /// Ascending order of this value.
  SqlOrdering<T> get ascending => SqlOrdering._(this, false, null);

  /// Descending order of this value.
  SqlOrdering<T> get descending => SqlOrdering._(this, true, null);

  SqlCall<T, R> _call<R>(String name, [List<SqlArgument<T>> rest = const []]) =>
      SqlCall(name, [SqlArgument.of(this), ...rest]);

  /// `abs(expression)`.
  SqlCall<T, Object?> abs() => _call('abs');

  /// `sign(expression)`.
  SqlCall<T, BigInt> sign() => _call('sign');

  /// `length(expression)`.
  SqlCall<T, BigInt> length() => _call('length');

  /// `octet_length(expression)`.
  SqlCall<T, BigInt> octetLength() => _call('octet_length');

  /// `lower(expression)`.
  SqlCall<T, String> lower() => _call('lower');

  /// `upper(expression)`.
  SqlCall<T, String> upper() => _call('upper');

  /// `hex(expression)`.
  SqlCall<T, String> hex() => _call('hex');

  /// `quote(expression)`.
  SqlCall<T, String> quote() => _call('quote');

  /// `unicode(expression)`.
  SqlCall<T, BigInt> unicode() => _call('unicode');

  /// `typeof(expression)`.
  SqlCall<T, String> typeOf() => _call('typeof');

  /// `floor(expression)`.
  SqlCall<T, Object?> floor() => _call('floor');

  /// `ceil(expression)`.
  SqlCall<T, Object?> ceil() => _call('ceil');

  /// `sqrt(expression)`.
  SqlCall<T, Object?> sqrt() => _call('sqrt');

  /// `trim(expression)` or `trim(expression, ?)`.
  SqlCall<T, String> trim([String? characters]) => _call('trim', [
        if (characters != null) SqlArgument.of(_SqlLiteral<T>(characters)),
      ]);

  /// `ltrim(expression)` or `ltrim(expression, ?)`.
  SqlCall<T, String> ltrim([String? characters]) => _call('ltrim', [
        if (characters != null) SqlArgument.of(_SqlLiteral<T>(characters)),
      ]);

  /// `rtrim(expression)` or `rtrim(expression, ?)`.
  SqlCall<T, String> rtrim([String? characters]) => _call('rtrim', [
        if (characters != null) SqlArgument.of(_SqlLiteral<T>(characters)),
      ]);

  /// `round(expression)` or `round(expression, ?)`.
  SqlCall<T, Object?> round([int? digits]) => _call('round', [
        if (digits != null) SqlArgument.of(_SqlLiteral<T>(digits)),
      ]);

  /// `substr(expression, ?, ?)`. [start] is 1-based, matching SQLite.
  SqlCall<T, String> substr(int start, [int? length]) => _call('substr', [
        SqlArgument.of(_SqlLiteral<T>(start)),
        if (length != null) SqlArgument.of(_SqlLiteral<T>(length)),
      ]);

  /// `instr(expression, ?)`.
  SqlCall<T, BigInt> instr(String needle) =>
      _call('instr', [SqlArgument.of(_SqlLiteral<T>(needle))]);

  /// `replace(expression, ?, ?)`.
  SqlCall<T, String> replace(String from, String to) => _call('replace', [
        SqlArgument.of(_SqlLiteral<T>(from)),
        SqlArgument.of(_SqlLiteral<T>(to)),
      ]);

  /// `concat(expression, other)`.
  SqlCall<T, String> concat<A>(SqlExpression<T, A> other) =>
      _call('concat', [SqlArgument.of(other)]);

  /// `coalesce(expression, other)`.
  SqlCall<T, Object?> coalesce<A>(SqlExpression<T, A> other) =>
      _call('coalesce', [SqlArgument.of(other)]);

  /// `ifnull(expression, ?)`.
  SqlCall<T, Object?> ifNull(Object? value) =>
      _call('ifnull', [SqlArgument.of(_SqlLiteral<T>(value))]);

  /// `nullif(expression, ?)`.
  SqlCall<T, Object?> nullIf(Object? value) =>
      _call('nullif', [SqlArgument.of(_SqlLiteral<T>(value))]);

  /// `date(expression)`.
  SqlCall<T, String> date() => _call('date');

  /// `time(expression)`.
  SqlCall<T, String> time() => _call('time');

  /// `datetime(expression)`.
  SqlCall<T, String> dateTime() => _call('datetime');

  /// `julianday(expression)`.
  SqlCall<T, double> julianDay() => _call('julianday');

  /// `unixepoch(expression)`.
  SqlCall<T, BigInt> unixEpoch() => _call('unixepoch');
}

/// One argument of a [SqlCall], keeping the expression's own value type.
final class SqlArgument<T> {
  SqlArgument._(this._columns, this._render);

  /// Captures [expression] for a scalar call.
  static SqlArgument<T> of<T, V>(SqlExpression<T, V> expression) =>
      SqlArgument._(expression._columns, expression._sql);

  final Iterable<Column<T, dynamic>> _columns;
  final String Function(List<Object?> parameters) _render;
}

/// A scalar call. Arguments are expressions or bound literals.
final class SqlCall<T, V> extends SqlExpression<T, V> {
  /// [name] is an SQL identifier such as `abs` or a generated model scalar.
  SqlCall(this.name, List<SqlArgument<T>> arguments)
      : arguments = List.unmodifiable(arguments) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'SQL function name');
    }
  }

  /// SQL function name.
  final String name;

  /// Arguments in call order.
  final List<SqlArgument<T>> arguments;

  @override
  Iterable<Column<T, dynamic>> get _columns =>
      [for (final argument in arguments) ...argument._columns];

  @override
  String _sql(List<Object?> parameters) =>
      '$name(${arguments.map((argument) => argument._render(parameters)).join(', ')})';

  @override
  Object? _encodeComparison(Object? value) =>
      value == null ? null : publishOrmScalar(value);
}

final class _SqlLiteral<T> extends SqlExpression<T, Object?> {
  _SqlLiteral(Object? value) : value = publishOrmScalar(value);
  final Object? value;

  @override
  Iterable<Column<T, dynamic>> get _columns => const [];

  @override
  String _sql(List<Object?> parameters) {
    parameters.add(copyOrmValue(value));
    return '?';
  }

  @override
  Object? _encodeComparison(Object? value) =>
      value == null ? null : publishOrmScalar(value);
}

final class _ExpressionComparison<T> extends SqlPredicate<T> {
  _ExpressionComparison(this.expression, this.operator, Object? value)
      : value = expression._encodeComparison(value);
  final SqlExpression<T, dynamic> expression;
  final String operator;
  final Object? value;

  @override
  Iterable<Column<T, dynamic>> get _columns => expression._columns;

  @override
  String _sql(List<Object?> parameters) {
    final rendered = expression._sql(parameters);
    if (value == null && (operator == '=' || operator == '<>')) {
      return '$rendered IS ${operator == '<>' ? 'NOT ' : ''}NULL';
    }
    parameters.add(copyOrmValue(value));
    return '$rendered $operator ?';
  }
}

final class _ExpressionNull<T> extends SqlPredicate<T> {
  const _ExpressionNull(this.expression, this.negate);
  final SqlExpression<T, dynamic> expression;
  final bool negate;

  @override
  Iterable<Column<T, dynamic>> get _columns => expression._columns;

  @override
  String _sql(List<Object?> parameters) =>
      '${expression._sql(parameters)} IS ${negate ? 'NOT ' : ''}NULL';
}

final class _ExpressionIn<T> extends SqlPredicate<T> {
  _ExpressionIn(this.expression, Iterable<Object?> values)
      : values = List.unmodifiable(values.map(expression._encodeComparison));
  final SqlExpression<T, dynamic> expression;
  final List<Object?> values;

  @override
  Iterable<Column<T, dynamic>> get _columns => expression._columns;

  @override
  String _sql(List<Object?> parameters) {
    final rendered = expression._sql(parameters);
    if (values.isEmpty) return '0';
    parameters.addAll(values.map(copyOrmValue));
    return '$rendered IN (${List.filled(values.length, '?').join(', ')})';
  }
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
      SqlOrdering._(MappedField(this), false, nullsFirst);

  /// Descending order. [nullsFirst] selects `NULLS FIRST` or `NULLS LAST`.
  SqlOrdering<T> desc({bool? nullsFirst}) =>
      SqlOrdering._(MappedField(this), true, nullsFirst);
}

/// A mapped column used from a Dart closure. Equality is [equalTo] because
/// Dart's `==` must return `bool` and cannot build a predicate. Parenthesize
/// comparison operators before combining them with `&` or `|`.
final class MappedField<T, V> extends SqlExpression<T, V> {
  /// Wraps [column] for closure syntax.
  const MappedField(this.column);

  /// The mapped column.
  final Column<T, V> column;

  @override
  Iterable<Column<T, dynamic>> get _columns => [column];

  @override
  String _sql(List<Object?> parameters) => quoteIdentifier(column.sqlName);

  @override
  Object? _encodeComparison(Object? value) => column.encodeValue(value as V);

  /// JSON path read through `json_extract`. The path is a bound parameter.
  JsonPathField<T> at(String path) => JsonPathField(column, path);
}

/// A mapped object stored as one JSON text value.
///
/// [path] reads a value inside the object. The path is bound. Equality,
/// null tests, and ordering on this field use the stored text.
final class DocumentField<T, V> extends MappedField<T, V> {
  /// Wraps a column whose codec is [Codecs.document].
  const DocumentField(super.column);

  /// `json_extract(column, path)`. [jsonPath] is bound, not interpolated.
  JsonPathField<T> path(String jsonPath) => at(jsonPath);
}

/// A JSON path on a mapped column. Comparisons bind both the path and the value.
final class JsonPathField<T> extends SqlExpression<T, Object?> {
  /// [path] is bound, not interpolated.
  const JsonPathField(this.column, this.path);

  /// JSON text column.
  final Column<T, dynamic> column;

  /// JSON path passed to `json_extract`.
  final String path;

  @override
  Iterable<Column<T, dynamic>> get _columns => [column];

  @override
  String _sql(List<Object?> parameters) {
    parameters.add(path);
    return 'json_extract(${quoteIdentifier(column.sqlName)}, ?)';
  }

  @override
  Object? _encodeComparison(Object? value) =>
      value == null ? null : copyOrmValue(value);
}

/// Reviewable generated SQL. Bound blobs are copied on every ownership boundary.
final class OrmQueryCommand {
  OrmQueryCommand._(this.sql, List<Object?> parameters)
      : _parameters = List.unmodifiable(parameters.map(copyOrmValue));

  OrmQueryCommand._template(this.sql, List<Object?> parameters)
      : _parameters = List.unmodifiable(
            parameters.map((p) => p is _OrmParameterUse ? p : copyOrmValue(p)));

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
      OrmOperationRunner? serialize,
      DbContext? context})
      : _context = context,
        _materialize = materialize,
        _serialize = serialize,
        _predicate = null,
        _ordering = const [],
        _offset = 0,
        _limit = null,
        _noTracking = false,
        _rank = false,
        _distance = false;

  TypedQuery._(
      this.type,
      this.connection,
      this._materialize,
      this._serialize,
      this._context,
      this._predicate,
      this._ordering,
      this._offset,
      this._limit,
      this._noTracking,
      this._rank,
      this._distance);

  /// Mapping this query reads.
  final EntityType<T> type;

  /// Connection that runs the statement.
  final OrmConnection connection;
  final T Function(RowReader)? _materialize;
  final OrmOperationRunner? _serialize;
  final DbContext? _context;
  final SqlPredicate<T>? _predicate;
  final List<SqlOrdering<T>> _ordering;
  final int _offset;
  final int? _limit;
  final bool _noTracking;
  final bool _rank;
  final bool _distance;

  TypedQuery<T> _copy(
          {SqlPredicate<T>? predicate,
          List<SqlOrdering<T>>? ordering,
          int? offset,
          int? limit,
          bool? noTracking,
          bool? rank,
          bool? distance}) =>
      TypedQuery._(
          type,
          connection,
          _materialize,
          _serialize,
          _context,
          predicate ?? _predicate,
          ordering ?? _ordering,
          offset ?? _offset,
          limit ?? _limit,
          noTracking ?? _noTracking,
          rank ?? _rank,
          distance ?? _distance);

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

  /// Same as [where]. Generated field closures call this name.
  TypedQuery<T> andWhere(SqlPredicate<T> predicate) => where(predicate);

  /// Binds [text] to `table MATCH ?` and orders by FTS rank first.
  TypedQuery<T> search(String text) {
    final predicate = _MatchPredicate<T>(type.tableName, text);
    return _copy(
        predicate: _predicate == null ? predicate : _predicate & predicate,
        rank: true,
        distance: false);
  }

  /// Binds [vector] to `column MATCH ? AND k = ?` and orders by distance.
  ///
  /// [k] is the number of neighbors, from 1 through
  /// [DbVectorLimits.maximumNeighbors]. The table must be [DbModules.vec0].
  TypedQuery<T> nearest(List<double> vector, {int k = 10}) {
    final column = type.vectorColumn;
    if (column == null) {
      throw const OrmMappingException('nearest needs one vector column');
    }
    if (k < 1 || k > DbVectorLimits.maximumNeighbors) {
      throw RangeError.range(k, 1, DbVectorLimits.maximumNeighbors, 'k');
    }
    final stored = column.encodeValue(vector);
    if (stored is! Uint8List) {
      throw const OrmCodecException('Vector did not encode to a BLOB');
    }
    final predicate = _NearestPredicate<T>(column, stored, k);
    return _copy(
        predicate: _predicate == null ? predicate : _predicate & predicate,
        rank: false,
        distance: true);
  }

  /// Replaces ordering; supply all ordering terms in their priority order.
  TypedQuery<T> orderBy(List<SqlOrdering<T>> ordering) {
    _validateColumns(
        [for (final term in ordering) ...term.expression._columns]);
    return _copy(ordering: List.unmodifiable(ordering));
  }

  /// Same as [orderBy]. Generated field closures call this name.
  TypedQuery<T> sortBy(List<SqlOrdering<T>> ordering) => orderBy(ordering);

  // A Dart int used as a row count must be exact on both VM and JavaScript.
  static const _maximumPagination = 9007199254740991;
  static void _validatePagination(int count) {
    if (count < 0 || count > _maximumPagination) {
      throw RangeError.range(count, 0, _maximumPagination, 'count');
    }
  }

  /// Skips [count] rows. [offset] is the same operation.
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

  /// Limits the query to [count] rows. [limit] is the same operation.
  TypedQuery<T> take(int count) {
    _validatePagination(count);
    return _copy(limit: _limit == null || count < _limit ? count : _limit);
  }

  /// Same as [skip].
  TypedQuery<T> offset(int count) => skip(count);

  /// Same as [take].
  TypedQuery<T> limit(int count) => take(count);

  /// Reads rows without placing them in the identity map.
  TypedQuery<T> asNoTracking() => _copy(noTracking: true);

  /// The SQL and parameters this query would run.
  OrmQueryCommand toSql() => _command();

  OrmQueryCommand _command({bool template = false}) {
    final parameters = <Object?>[];
    final sql = StringBuffer('SELECT ')
      ..write(type.columns
          .map((column) => quoteIdentifier(column.sqlName))
          .join(', '))
      ..write(' FROM ${quoteIdentifier(type.tableName)}');
    if (_predicate != null) {
      sql.write(' WHERE ${_predicate._sql(parameters)}');
    }
    if (_rank || _distance || _ordering.isNotEmpty) {
      sql.write(' ORDER BY ');
      sql.write([
        if (_distance) 'distance',
        if (_rank) 'rank',
        ..._ordering.map((term) => term._sql(parameters))
      ].join(', '));
    }
    if (_limit != null || _offset != 0) {
      sql.write(' LIMIT ?');
      parameters.add(BigInt.from(_limit ?? -1));
      if (_offset != 0) {
        sql.write(' OFFSET ?');
        parameters.add(BigInt.from(_offset));
      }
    }
    if (!template && parameters.any((p) => p is _OrmParameterUse)) {
      throw const OrmStateException(
          'QueryParameter requires prepare() and bindings');
    }
    return template
        ? OrmQueryCommand._template(sql.toString(), parameters)
        : OrmQueryCommand._(sql.toString(), parameters);
  }

  Future<R> _run<R>(Future<R> Function() operation) =>
      _serialize == null ? operation() : _serialize<R>(operation);

  Future<QueryResult> _rows() {
    registerOrmScalars(connection, [type]);
    final command = toSql();
    if ((_context?.preparedQueryCacheSize ?? 0) > 0) {
      return _context!._preparedRows(command);
    }
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

  DbContext get _watchOwner {
    final owner = _context ??
        (connection._owner is DbContext
            ? connection._owner as DbContext
            : null);
    if (owner == null ||
        !identical(owner.connection, connection) ||
        !owner.model.entities.contains(type)) {
      throw const OrmStateException(
          'Watch requires a query owned by a matching DbContext/DbSet');
    }
    return owner;
  }

  /// Committed, independent read snapshots; never mutates the identity map.
  ReactiveQuery<T> watch() => _watchOwner._watch(this);
  Stream<T?> watchFirst() => take(1).watch().map((s) => s.items.firstOrNull);
  Stream<BigInt> watchCount() => _watchOwner._watchCount(this);
  Stream<bool> watchAny() => take(1).watchCount().map((n) => n > BigInt.zero);

  /// Keyset page; mapped primary keys provide a deterministic tie-breaker.
  /// Cannot combine cursor paging with skip/take or expression/rank ordering.
  Future<SqlPage<T>> page(
          {int size = 30,
          PageCursor? after,
          PageCursor? before,
          String cursorScope = ''}) =>
      _run(() async {
        if (_offset != 0 || _limit != null) {
          throw const OrmStateException(
              'Cursor page cannot combine with skip/take');
        }
        if (_rank || _distance || type.scalars.any((s) => !s.deterministic)) {
          throw const OrmStateException(
              'Cursor page needs stable mapped-column ordering');
        }
        final order = <PageOrder>[];
        for (final term in _ordering) {
          final expression = term.expression;
          if (expression is! MappedField<T, dynamic>) {
            throw const OrmStateException(
                'Cursor page currently supports mapped-column ordering');
          }
          order.add(PageOrder(expression.column.sqlName,
              descending: term.descending, nullsFirst: term.nullsFirst));
        }
        final parameters = <Object?>[];
        final where = _predicate?._sql(parameters);
        registerOrmScalars(connection, [type]);
        final result =
            await SqlPagination((sql, args) => connection.query(sql, args))
                .page(
                    table: type.tableName,
                    keyColumns: type.keys.map((k) => k.sqlName).toList(),
                    orderBy: order,
                    columns: type.columns.map((c) => c.sqlName).toList(),
                    where: where,
                    parameters: parameters,
                    size: size,
                    after: after,
                    before: before,
                    cursorScope: cursorScope);
        return result.map((row) => (_noTracking
            ? type.create
            : _materialize ?? type.create)(RowReader(_copyOrmRow(row))));
      });

  /// Materializes every matching row.
  Future<List<T>> toList() => _run(() async {
        final result = await _rows();
        return [for (final row in result.rows) _read(result, row)];
      });

  /// Same as [toList].
  Future<List<T>> select() => toList();

  /// Same as [toList].
  Future<List<T>> get() => toList();

  /// Same as [toList].
  Future<List<T>> findAll() => toList();

  /// Same as [toList].
  Future<List<T>> all() => toList();

  /// The first row, or null when the query is empty.
  Future<T?> firstOrNull() => _run(() async {
        final result = await take(1)._rows();
        return result.rows.isEmpty ? null : _read(result, result.rows.first);
      });

  /// The first row. Fails when the query is empty.
  Future<T> first() => _run(() async {
        final result = await take(1)._rows();
        if (result.rows.isEmpty) {
          throw const OrmStateException(
              'Expected a first entity but the query returned none');
        }
        return _read(result, result.rows.first);
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

  /// The only row, or null when the query is empty. Fails when several match.
  Future<T?> singleOrNull() => _run(() async {
        final result = await take(2)._rows();
        if (result.rows.length > 1) {
          throw const OrmStateException(
              'Expected one entity but the query returned multiple');
        }
        return result.rows.isEmpty ? null : _read(result, result.rows.single);
      });

  /// Number of rows matching the filter, as [BigInt].
  Future<BigInt> count() => _run(() async {
        registerOrmScalars(connection, [type]);
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

  /// Whether at least one row matches. [exists] is the same operation.
  Future<bool> any() =>
      _run(() async => (await take(1)._rows()).rows.isNotEmpty);

  /// Same as [any].
  Future<bool> exists() => any();
}

/// Registers model scalars on the engine connection the ORM is using.
void registerOrmScalars(
    OrmConnection connection, Iterable<EntityType<dynamic>> entities) {
  final database = connection.engineDatabase;
  if (database == null) return;
  for (final entity in entities) {
    for (final scalar in entity.scalars) {
      database.functions.registerScalar(scalar.name, scalar.columns.length,
          (arguments) => publishOrmScalar(scalar.apply(arguments)),
          deterministic: scalar.deterministic);
    }
  }
}
