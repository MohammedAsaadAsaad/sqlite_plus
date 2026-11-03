import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';

/// Registers the `vec0` virtual table on one connection.
abstract final class SqlitePlusVec {
  /// [database] is a [SqliteDatabase], a [MutableSqliteDatabase], or the
  /// connection's [SqlFunctionRegistry]. A second call keeps the existing
  /// module.
  ///
  /// Register it before creating or querying a `USING vec0` table. The module
  /// stores one little-endian float32 vector per row and answers
  /// `column MATCH ? AND k = ?` by scanning those rows. It does not read or
  /// write sqlite-vec database files, and it does not build an approximate
  /// index.
  static void register(Object database) {
    final functions = _functions(database);
    if (functions.virtualTables.find('vec0') is Vec0Module) return;
    functions.virtualTables.register(Vec0Module());
  }
}

SqlFunctionRegistry _functions(Object database) {
  if (database is SqliteDatabase) return database.functions;
  if (database is MutableSqliteDatabase) return database.functions;
  if (database is SqlFunctionRegistry) return database;
  throw ArgumentError('Expected a sqlite_plus database');
}

/// Euclidean or cosine distance. Both vectors have the same length.
double vecDistance(List<double> left, List<double> right, String metric) {
  if (left.length != right.length) {
    throw const SqlException('vec0 dimension mismatch');
  }
  final key = _lower(metric);
  if (key == 'l2') {
    var sum = 0.0;
    for (var index = 0; index < left.length; index++) {
      final delta = left[index] - right[index];
      sum += delta * delta;
    }
    return math.sqrt(sum);
  }
  if (key == 'cosine') {
    var dot = 0.0;
    var leftNorm = 0.0;
    var rightNorm = 0.0;
    for (var index = 0; index < left.length; index++) {
      dot += left[index] * right[index];
      leftNorm += left[index] * left[index];
      rightNorm += right[index] * right[index];
    }
    if (leftNorm == 0 && rightNorm == 0) return 0;
    if (leftNorm == 0 || rightNorm == 0) return 1;
    return 1 - (dot / (math.sqrt(leftNorm) * math.sqrt(rightNorm)));
  }
  throw SqlException('vec0: unknown distance metric: $metric');
}

/// Encodes [values] as little-endian float32. Every value must be finite.
Uint8List encodeVec(List<double> values) {
  if (values.isEmpty || values.length > 4096) {
    throw const SqlException('vec0 dimensions are outside 1 to 4096');
  }
  final bytes = Uint8List(values.length * 4);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < values.length; index++) {
    final value = values[index];
    if (!value.isFinite) {
      throw const SqlException('vec0 coordinate must be finite');
    }
    data.setFloat32(index * 4, value, Endian.little);
  }
  return bytes;
}

/// Decodes a little-endian float32 blob. A non-finite coordinate is rejected.
List<double> decodeVec(Uint8List bytes) {
  if (bytes.length < 4 || bytes.length > 4096 * 4 || bytes.length % 4 != 0) {
    throw const SqlException('vec0 dimension mismatch');
  }
  final data = ByteData.sublistView(bytes);
  return [
    for (var index = 0; index < bytes.length; index += 4)
      _finite(data.getFloat32(index, Endian.little))
  ];
}

double _finite(double value) {
  if (!value.isFinite) {
    throw const SqlException('vec0 coordinate must be finite');
  }
  return value;
}

final class Vec0Module extends VirtualTableModule {
  @override
  String get name => 'vec0';

  @override
  List<String> get columns => const ['embedding'];

  @override
  List<String> get hiddenColumns => const ['distance', 'k'];

  @override
  bool get storesRows => true;

  @override
  List<String> columnsFor(String table, List<String> arguments) =>
      [_spec(table, arguments).column];

  @override
  List<String> hiddenFor(String table, List<String> arguments) => hiddenColumns;

  @override
  List<String> shadowNames(String table, List<String> arguments) =>
      [shadowName(table, arguments)];

  @override
  List<String> ownedShadows(String table, List<String> arguments) =>
      shadowNames(table, arguments);

  @override
  List<({String name, String type})> shadowFields(
          String table, List<String> arguments) =>
      [(name: _spec(table, arguments).column, type: 'BLOB NOT NULL')];

  @override
  void xCreate(String table, List<String> arguments) {
    _spec(table, arguments);
  }

  @override
  void bestIndex(VirtualTableIndexPlan plan) {
    for (var index = 0; index < plan.constraints.length; index++) {
      final constraint = plan.constraints[index];
      if (constraint.operator == 'match' && constraint.column == 0) {
        plan.use(index);
      } else if (constraint.operator == '=' && constraint.column == 2) {
        plan.use(index);
      }
    }
  }

  @override
  VirtualTableCursor xOpen(String table) => _VecCursor();
}

final class _VecColumn {
  _VecColumn(this.table, this.column, this.dimensions, this.metric);
  final String table;
  final String column;
  final int dimensions;
  final String metric;
}

_VecColumn _spec(String table, List<String> arguments) {
  if (arguments.length != 1) {
    throw const SqlException('vec0 supports one vector column');
  }
  final parts = arguments.single
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.length < 2 || parts.length > 3) {
    throw const SqlException('vec0 column must be name float[N]');
  }
  final name = _unquote(parts.first);
  final size = RegExp(
    r'^[Ff][Ll][Oo][Aa][Tt]\[(\d+)\]$',
  ).firstMatch(parts[1]);
  if (!_identifier(name) || size == null) {
    throw const SqlException('vec0 column must be name float[N]');
  }
  final dimensions = int.parse(size.group(1)!);
  if (dimensions < 1 || dimensions > 4096) {
    throw const SqlException('vec0 dimensions are outside 1 to 4096');
  }
  if (const {'distance', 'k', 'rowid'}.contains(_lower(name))) {
    throw const SqlException('vec0 reserves distance, k, and rowid');
  }
  var metric = 'l2';
  if (parts.length == 3) {
    final split = parts[2].split('=');
    if (split.length != 2 || _lower(split[0]) != 'distance_metric') {
      throw const SqlException('vec0: unknown column option');
    }
    metric = _lower(split[1]);
    if (metric != 'l2' && metric != 'cosine') {
      throw SqlException('vec0: unknown distance metric: ${split[1]}');
    }
  }
  return _VecColumn(table, name, dimensions, metric);
}

String _unquote(String token) {
  if (token.length >= 2 && token.startsWith('"') && token.endsWith('"')) {
    return token.substring(1, token.length - 1).replaceAll('""', '"');
  }
  if (token.length >= 2 &&
      ((token.startsWith("'") && token.endsWith("'")) ||
          (token.startsWith('[') && token.endsWith(']')) ||
          (token.startsWith('`') && token.endsWith('`')))) {
    return token.substring(1, token.length - 1);
  }
  return token;
}

bool _identifier(String name) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);

String _lower(String value) => String.fromCharCodes(
    value.codeUnits.map((unit) => unit >= 65 && unit <= 90 ? unit + 32 : unit));

final class _VecCursor extends VirtualTableCursor {
  var _closed = false;
  var _index = 0;
  Uint8List? _query;
  int? _k;
  var _sawK = false;
  List<(BigInt, Uint8List, double?, BigInt?)> _rows = const [];

  void _live() {
    if (_closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void applyConstraints(List<VirtualTableConstraint> constraints) {
    _live();
    for (final constraint in constraints) {
      if (constraint.operator == 'match' && constraint.column == 0) {
        final value = constraint.value;
        if (value is! Uint8List) {
          throw const SqlException('vec0 query must be a float32 blob');
        }
        _query = Uint8List.fromList(value);
      } else if (constraint.operator == '=' && constraint.column == 2) {
        _sawK = true;
        _k = _integer(constraint.value);
      }
    }
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    final spec = _spec(table, arguments);
    final shadow = SearchSnapshot.current.table('${table}_vec');
    final stored = <(BigInt, Uint8List)>[];
    if (shadow != null) {
      for (final row in shadow.rows) {
        final value = shadow.value(row, spec.column);
        if (value is! Uint8List || value.length != spec.dimensions * 4) {
          throw const SqlException('vec0 dimension mismatch');
        }
        stored.add((row.rowId, Uint8List.fromList(value)));
      }
    }
    final queryBytes = _query;
    if (queryBytes == null) {
      if (_sawK) throw const SqlException('vec0: k requires MATCH');
      _rows = [
        for (final row in stored) (row.$1, row.$2, null, null),
      ];
      _index = 0;
      return;
    }
    if (!_sawK || _k == null) throw const SqlException('vec0: k is required');
    if (_k! < 1 || _k! > 100000) {
      throw const SqlException('vec0: k is out of range');
    }
    final query = _decode(queryBytes, spec.dimensions);
    final ranked = <(BigInt, Uint8List, double)>[
      for (final row in stored)
        (
          row.$1,
          row.$2,
          vecDistance(_decode(row.$2, spec.dimensions), query, spec.metric)
        )
    ]..sort((left, right) {
        final distance = left.$3.compareTo(right.$3);
        return distance == 0 ? left.$1.compareTo(right.$1) : distance;
      });
    final kept = ranked.take(_k!).toList();
    final hits = <BigInt>{for (final row in kept) row.$1};
    final owned = <BigInt>{for (final row in stored) row.$1};
    final column = spec.column;
    final tableName = spec.table;
    VirtualMatchBoard.current?.handlers.add((qualifier, name, pattern, rowid) {
      if (name == null || _lower(name) != _lower(column)) return null;
      if (qualifier != null) {
        final scope = _lower(qualifier);
        final key = _lower(tableName);
        if (scope != key && scope != 'main.$key') return null;
      }
      if (rowid is! BigInt || !owned.contains(rowid)) return null;
      if (pattern is! Uint8List || !_bytesEqual(pattern, queryBytes)) {
        return BigInt.zero;
      }
      return hits.contains(rowid) ? BigInt.one : BigInt.zero;
    });
    _rows = [
      for (final row in kept) (row.$1, row.$2, row.$3, BigInt.from(_k!)),
    ];
    _index = 0;
  }

  @override
  void next() {
    _live();
    if (_index < _rows.length) _index++;
  }

  @override
  bool get eof {
    _live();
    return _index >= _rows.length;
  }

  @override
  Object? column(int index) {
    _live();
    if (eof || index < 0 || index > 2) {
      throw const SqlException('Virtual table column index out of range');
    }
    final row = _rows[_index];
    return switch (index) {
      0 => row.$2,
      1 => row.$3,
      _ => row.$4,
    };
  }

  @override
  BigInt get rowid {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    return _rows[_index].$1;
  }

  @override
  void close() {
    _closed = true;
    _rows = const [];
  }
}

int? _integer(Object? value) {
  if (value == null) return null;
  if (value is! int && value is! BigInt) {
    throw const SqlException('vec0: k must be an integer');
  }
  final parsed = value is int ? BigInt.from(value) : value as BigInt;
  if (parsed < BigInt.one || parsed > BigInt.from(100000)) {
    throw const SqlException('vec0: k is out of range');
  }
  return parsed.toInt();
}

List<double> _decode(Uint8List bytes, int dimensions) {
  if (bytes.length != dimensions * 4) {
    throw const SqlException('vec0 dimension mismatch');
  }
  final data = ByteData.sublistView(bytes);
  return [
    for (var index = 0; index < dimensions; index++)
      _finite(data.getFloat32(index * 4, Endian.little))
  ];
}

bool _bytesEqual(Uint8List left, Uint8List right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
