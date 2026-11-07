import 'dart:convert';
import 'dart:typed_data';
import 'package:pointycastle/digests/sha256.dart';
import '../sql/database.dart';
import '../sql/mutable_database.dart';

String _lower(String value) => String.fromCharCodes(
    value.codeUnits.map((c) => c >= 65 && c <= 90 ? c + 32 : c));
String _quote(String value) {
  if (value.isEmpty || value.contains('\u0000')) {
    throw ArgumentError.value(value, 'identifier');
  }
  return '"${value.replaceAll('"', '""')}"';
}

Object? _copy(Object? value) =>
    value is Uint8List ? Uint8List.fromList(value) : value;
const _maxCursorLength = 65536;
final _minimum = -(BigInt.one << 63),
    _maximum = (BigInt.one << 63) - BigInt.one;

Object _encodeValue(Object? value) {
  if (value == null) return ['n'];
  if (value is int && (value < -9007199254740991 || value > 9007199254740991)) {
    throw ArgumentError(
        'Use BigInt for integers outside the portable exact range');
  }
  if (value is int || value is BigInt) {
    final integer = value is BigInt ? value : BigInt.from(value as int);
    if (integer < _minimum || integer > _maximum) {
      throw ArgumentError('Pagination integer is outside signed 64-bit range');
    }
    return ['i', integer.toString()];
  }
  if (value is double && value.isFinite) return ['r', value.toString()];
  if (value is String) return ['t', value];
  if (value is Uint8List) return ['b', base64Encode(value)];
  if (value is bool) return ['i', value ? '1' : '0'];
  throw ArgumentError('Pagination values must be finite SQLite scalar values');
}

Object? _decodeValue(Object? encoded) {
  if (encoded is! List || encoded.isEmpty) {
    throw const FormatException('Invalid cursor value');
  }
  if (encoded.length == 1 && encoded[0] == 'n') return null;
  if (encoded.length != 2 || encoded[1] is! String) {
    throw const FormatException('Invalid cursor value');
  }
  final text = encoded[1] as String;
  switch (encoded[0]) {
    case 'i':
      final value = BigInt.parse(text);
      if (value < _minimum || value > _maximum) {
        throw const FormatException('Integer overflow');
      }
      return value;
    case 'r':
      final value = double.parse(text);
      if (!value.isFinite) throw const FormatException('Non-finite real');
      return value;
    case 't':
      return text;
    case 'b':
      return base64Decode(text);
    default:
      throw const FormatException('Invalid cursor type');
  }
}

/// Portable, unsigned continuation token. Never use as authorization.
final class PageCursor {
  PageCursor._(this._scope, Iterable<Object?> values)
      : _values = List.unmodifiable(values.map(_copy));
  final String _scope;
  final List<Object?> _values;

  factory PageCursor.parse(String token) {
    try {
      if (token.length > _maxCursorLength) {
        throw const FormatException('Cursor too long');
      }
      final data =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token))));
      if (data is! List ||
          data.length != 3 ||
          data[0] is! int ||
          data[0] != 1 ||
          data[1] is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(data[1] as String) ||
          data[2] is! List ||
          (data[2] as List).isEmpty ||
          (data[2] as List).length > 16) {
        throw const FormatException('Invalid cursor format');
      }
      return PageCursor._(
          data[1] as String, (data[2] as List).map(_decodeValue));
    } on FormatException catch (error) {
      throw ArgumentError.value(
          token.length > 80 ? '<cursor>' : token, 'token', error.message);
    }
  }

  String encode() {
    final token = base64Url.encode(utf8
        .encode(jsonEncode([1, _scope, _values.map(_encodeValue).toList()])));
    if (token.length > _maxCursorLength) {
      throw ArgumentError('Cursor exceeds 64 KiB; use smaller ordering values');
    }
    return token;
  }
}

/// A column ordering, using its declared collation unless explicitly overridden.
final class PageOrder {
  PageOrder(this.column,
      {this.descending = false, this.nullsFirst, this.collation}) {
    _quote(column);
    if (collation != null) _quote(collation!);
  }
  final String column;
  final bool descending;
  final bool? nullsFirst;
  final String? collation;
  bool get _nullsFirst => nullsFirst ?? !descending;
  String get _expression =>
      '${_quote(column)}${collation == null ? '' : ' COLLATE ${_quote(collation!)}'}';
  String _order(bool reverse) =>
      '$_expression ${(descending != reverse) ? 'DESC' : 'ASC'} NULLS ${(_nullsFirst != reverse) ? 'FIRST' : 'LAST'}';
}

/// Immutable list container. Entity/map/BLOB values follow their normal APIs.
final class SqlPage<T> {
  SqlPage._(Iterable<T> items,
      {required this.hasNextPage,
      required this.hasPreviousPage,
      required this.nextCursor,
      required this.previousCursor})
      : items = List.unmodifiable(items);
  final List<T> items;
  final bool hasNextPage, hasPreviousPage;
  final PageCursor? nextCursor, previousCursor;
  SqlPage<R> map<R>(R Function(T) convert) => SqlPage._(items.map(convert),
      hasNextPage: hasNextPage,
      hasPreviousPage: hasPreviousPage,
      nextCursor: nextCursor,
      previousCursor: previousCursor);
}

typedef PageQueryRunner = Future<QueryResult> Function(
    String sql, List<Object?> parameters);

/// Keyset paging over a single table/view. The caller guarantees unique,
/// non-null [keyColumns]. No schema/index mutation or hidden COUNT query.
final class SqlPagination {
  const SqlPagination(this.query);
  final PageQueryRunner query;

  Future<SqlPage<Map<String, Object?>>> page(
      {required String table,
      required List<String> keyColumns,
      List<PageOrder> orderBy = const [],
      List<String>? columns,
      String? where,
      List<Object?> parameters = const [],
      int size = 30,
      PageCursor? after,
      PageCursor? before,
      String cursorScope = ''}) async {
    keyColumns = List.unmodifiable(keyColumns);
    columns = columns == null ? null : List.unmodifiable(columns);
    _quote(table);
    if (size < 1 || size > 10000) {
      throw RangeError.range(size, 1, 10000, 'size');
    }
    if (after != null && before != null) {
      throw ArgumentError('Supply after or before, not both');
    }
    final keys = keyColumns.map(_lower).toSet();
    if (keys.isEmpty || keys.length != keyColumns.length) {
      throw ArgumentError('Declare unique non-null key columns');
    }
    for (final key in keyColumns) {
      _quote(key);
    }
    final order = List<PageOrder>.of(orderBy);
    final ordered = order.map((o) => _lower(o.column)).toSet();
    if (ordered.length != order.length) {
      throw ArgumentError('Duplicate ordering column');
    }
    for (final key in keyColumns) {
      if (ordered.add(_lower(key))) {
        order.add(PageOrder(key));
      } else if (order
          .any((o) => _lower(o.column) == _lower(key) && o.collation != null)) {
        // An explicit collation can make otherwise unique text keys equal.
        // Preserve that requested order, then break its ties by key bytes.
        order.add(PageOrder(key, collation: 'BINARY'));
      }
    }
    if (order.length > 16) {
      throw ArgumentError('At most 16 effective ordering columns');
    }
    if (columns != null) {
      final selected = columns.map(_lower).toSet();
      if (selected.isEmpty ||
          selected.length != columns.length ||
          !ordered.every(selected.contains)) {
        throw ArgumentError(
            'Projection must contain every ordering/key column exactly once');
      }
      for (final column in columns) {
        _quote(column);
      }
    }
    if (where != null && where.trim().isEmpty) {
      throw ArgumentError('Empty where expression');
    }
    if (where == null && parameters.isNotEmpty) {
      throw ArgumentError('Parameters need a where expression');
    }
    final args = parameters.map(_copy).toList();
    final definition = jsonEncode([
      table,
      columns,
      where,
      args.map(_encodeValue).toList(),
      [
        for (final o in order)
          [o.column, o.descending, o._nullsFirst, o.collation]
      ],
      keyColumns,
      cursorScope
    ]);
    final scope = SHA256Digest()
        .process(Uint8List.fromList(utf8.encode(definition)))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final cursor = after ?? before;
    if (cursor != null &&
        (cursor._scope != scope || cursor._values.length != order.length)) {
      throw ArgumentError('Cursor belongs to a different query/order/scope');
    }
    final reverse = before != null;
    final clauses = <String>[if (where != null) '($where)'];
    if (cursor != null) {
      clauses.add(_seek(order, cursor._values, !reverse, args));
    }
    final sql =
        'SELECT ${columns == null ? '*' : columns.map(_quote).join(',')} FROM ${_quote(table)}'
        '${clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}'}'
        ' ORDER BY ${order.map((o) => o._order(reverse)).join(',')} LIMIT ?';
    args.add(BigInt.from(size + 1));
    final result = await query(sql, args);
    final names = result.columns.map(_lower).toList();
    if (names.toSet().length != names.length) {
      throw StateError('Pagination needs distinct projected names');
    }
    final positions = {
      for (final o in order) o.column: names.indexOf(_lower(o.column))
    };
    if (positions.values.any((i) => i < 0)) {
      throw StateError('Ordering/key column not projected');
    }
    final seen = <String>{};
    for (final row in result.rows) {
      final key = [
        for (final name in keyColumns) row[names.indexOf(_lower(name))]
      ];
      if (key.any((v) => v == null) ||
          !seen.add(jsonEncode(key.map(_encodeValue).toList()))) {
        throw StateError('Pagination keys must be unique and non-null');
      }
    }
    final more = result.rows.length > size;
    var rows = result.rows.take(size).toList();
    if (reverse) rows = rows.reversed.toList();
    PageCursor token(List<Object?> row) =>
        PageCursor._(scope, [for (final o in order) row[positions[o.column]!]]);
    final nonempty = rows.isNotEmpty;
    final hasNext = reverse ? nonempty : more;
    final hasPrevious = reverse ? more : cursor != null && nonempty;
    return SqlPage._([
      for (final row in rows)
        Map<String, Object?>.unmodifiable({
          for (var i = 0; i < result.columns.length; i++)
            result.columns[i]: _copy(row[i])
        })
    ],
        hasNextPage: hasNext,
        hasPreviousPage: hasPrevious,
        nextCursor: hasNext ? token(rows.last) : null,
        previousCursor: hasPrevious ? token(rows.first) : null);
  }
}

String _seek(List<PageOrder> order, List<Object?> values, bool after,
    List<Object?> args) {
  final alternatives = <String>[];
  for (var i = 0; i < order.length; i++) {
    final terms = <String>[];
    for (var j = 0; j < i; j++) {
      terms.add('${order[j]._expression} IS ?');
      args.add(_copy(values[j]));
    }
    final o = order[i], value = values[i];
    final includeNull = after ? !o._nullsFirst : o._nullsFirst;
    if (value == null) {
      terms.add(includeNull ? '0' : '${o._expression} IS NOT NULL');
    } else {
      final comparison =
          '${o._expression} ${(after != o.descending) ? '>' : '<'} ?';
      args.add(_copy(value));
      terms.add(includeNull
          ? '($comparison OR ${o._expression} IS NULL)'
          : comparison);
    }
    alternatives.add('(${terms.join(' AND ')})');
  }
  return '(${alternatives.join(' OR ')})';
}

extension MutableDatabasePagination on MutableSqliteDatabase {
  /// See [SqlPagination.page].
  Future<SqlPage<Map<String, Object?>>> page(
          {required String table,
          required List<String> keyColumns,
          List<PageOrder> orderBy = const [],
          List<String>? columns,
          String? where,
          List<Object?> parameters = const [],
          int size = 30,
          PageCursor? after,
          PageCursor? before,
          String cursorScope = ''}) =>
      SqlPagination((sql, args) => query(sql, args)).page(
          table: table,
          keyColumns: keyColumns,
          orderBy: orderBy,
          columns: columns,
          where: where,
          parameters: parameters,
          size: size,
          after: after,
          before: before,
          cursorScope: cursorScope);
}

extension ReadOnlyDatabasePagination on SqliteDatabase {
  /// See [SqlPagination.page].
  Future<SqlPage<Map<String, Object?>>> page(
          {required String table,
          required List<String> keyColumns,
          List<PageOrder> orderBy = const [],
          List<String>? columns,
          String? where,
          List<Object?> parameters = const [],
          int size = 30,
          PageCursor? after,
          PageCursor? before,
          String cursorScope = ''}) =>
      SqlPagination((sql, args) => query(sql, args)).page(
          table: table,
          keyColumns: keyColumns,
          orderBy: orderBy,
          columns: columns,
          where: where,
          parameters: parameters,
          size: size,
          after: after,
          before: before,
          cursorScope: cursorScope);
}
