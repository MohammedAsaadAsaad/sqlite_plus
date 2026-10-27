import 'dart:async';
import 'dart:typed_data';

import '../btree/btree_reader.dart';
import 'catalog.dart';
import 'values.dart';
import 'parser.dart';
import 'tokenizer.dart';

/// A Pure Dart virtual-table module. There is no C ABI and no native entry
/// points. [read] returns one list per row, in [columns] order.
///
/// [xCreate] runs for `CREATE VIRTUAL TABLE`. [xConnect] and [xDisconnect]
/// bracket each statement that reads the table. [xDestroy] runs for `DROP TABLE`.
abstract class VirtualTableModule {
  String get name;
  List<String> get columns;

  /// Columns omitted from `SELECT *`. They remain readable by name.
  List<String> get hiddenColumns => const [];

  /// Table-specific columns. The registration lists stay non-empty defaults.
  List<String> columnsFor(String table, List<String> arguments) => columns;

  List<String> hiddenFor(String table, List<String> arguments) => hiddenColumns;

  /// Shadow tables to preload before a synchronous scan. Missing names are
  /// skipped, so contentless tables can omit a content shadow.
  List<String> shadowNames(String table, List<String> arguments) => const [];

  /// Shadows removed by DROP. External content tables stay out of this list.
  List<String> ownedShadows(String table, List<String> arguments) =>
      shadowNames(table, arguments);

  /// The scan is synchronous. Callers publish the WHERE clause here first.
  void prepareScan(CatalogTable table, Expr? where, List<Object?> parameters) {}

  /// When true, `SELECT * FROM name(...)` opens this module without CREATE.
  bool get eponymous => false;

  /// Whole-result helper used by the default cursor. A module that overrides
  /// [xOpen] does not need this.
  List<List<Object?>> read(String table, List<String> arguments) {
    throw const SqlException('Virtual table module did not implement read');
  }

  /// Choose which equality and range constraints this module will consume.
  /// Constraints left unused are still evaluated by SQL after a full scan.
  void bestIndex(VirtualTableIndexPlan plan) {}

  VirtualTableCursor xOpen(String table) => _MaterializedCursor(this);
  void xCreate(String table, List<String> arguments) {}
  void xConnect(String table, List<String> arguments) {}
  void xDisconnect(String table) {}
  void xDestroy(String table) {}
  void xBegin() {}
  void xCommit() {}
  void xRollback() {}
}

/// One comparison SQL can hand to [VirtualTableModule.bestIndex].
final class VirtualTableConstraint {
  VirtualTableConstraint(this.column, this.operator, this.value);
  final int column;
  final String operator;
  final Object? value;
}

/// The constraints visible to one scan. [use] marks those the module accepts.
final class VirtualTableIndexPlan {
  VirtualTableIndexPlan(this.constraints);
  final List<VirtualTableConstraint> constraints;
  final List<int> _used = [];

  List<VirtualTableConstraint> get used =>
      [for (final index in _used) constraints[index]];

  void use(int index) {
    if (index < 0 || index >= constraints.length || _used.contains(index)) {
      throw ArgumentError('Virtual table constraint index out of range');
    }
    _used.add(index);
  }
}

/// One scan position. Methods throw after [close].
abstract class VirtualTableCursor {
  void applyArguments(List<Object?> arguments) {}
  void applyConstraints(List<VirtualTableConstraint> constraints) {}
  void filter(String table, List<String> arguments);
  void next();
  bool get eof;
  Object? column(int index);
  BigInt get rowid;
  void close();
}

final class _MaterializedCursor extends VirtualTableCursor {
  _MaterializedCursor(this._module);
  final VirtualTableModule _module;
  var _closed = false;
  var _index = 0;
  List<List<Object?>> _rows = const [];

  void _live() {
    if (_closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    _rows = _module.read(table, arguments);
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
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    final row = _rows[_index];
    if (index < 0 || index >= row.length) {
      throw const SqlException('Virtual table column index out of range');
    }
    return row[index];
  }

  @override
  BigInt get rowid {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    return BigInt.from(_index + 1);
  }

  @override
  void close() {
    _closed = true;
    _rows = const [];
  }
}

void invokeVirtualTableCallback(String action, void Function() body) {
  try {
    body();
  } on SqlException {
    rethrow;
  } catch (_) {
    throw SqlException('Virtual table $action failed');
  }
}

/// Connection-local modules. Published on the function-registry zone while a
/// statement runs.
final class VirtualTableRegistry {
  static final Object _zoneKey = Object();
  final Map<String, VirtualTableModule> _modules = {};

  static VirtualTableRegistry? get current =>
      Zone.current[_zoneKey] as VirtualTableRegistry?;

  VirtualTableRegistry() {
    register(GenerateSeriesModule());
  }

  Iterable<VirtualTableModule> get modules => _modules.values;

  void register(VirtualTableModule module) {
    final key = asciiLower(module.name);
    if (module.name.isEmpty ||
        module.name.contains('\u0000') ||
        key.startsWith('sqlite_')) {
      throw ArgumentError('Invalid virtual table module name');
    }
    if (module.columns.isEmpty ||
        module.columns.length + module.hiddenColumns.length > 1000) {
      throw ArgumentError('Invalid virtual table column count');
    }
    final seen = <String>{};
    for (final column in [...module.columns, ...module.hiddenColumns]) {
      if (column.isEmpty ||
          column.contains('\u0000') ||
          !seen.add(asciiLower(column))) {
        throw ArgumentError('Invalid virtual table column');
      }
    }
    if (_modules.containsKey(key)) {
      throw ArgumentError('Virtual table module already registered');
    }
    _modules[key] = module;
  }

  VirtualTableModule? find(String name) => _modules[asciiLower(name)];

  static T run<T>(VirtualTableRegistry registry, T Function() action) =>
      runZoned(action, zoneValues: {_zoneKey: registry});
}

/// Parsed `CREATE VIRTUAL TABLE ... USING module(...)` text.
final class VirtualTableDeclaration {
  VirtualTableDeclaration(this.name, this.module, this.arguments,
      {this.ifNotExists = false, this.declaredColumns});
  final String name;
  final String module;
  final List<String> arguments;
  final bool ifNotExists;

  /// Null when the statement has no column list. Each entry is name and hidden.
  final List<(String, bool)>? declaredColumns;

  static bool isVirtual(String? sql) {
    if (sql == null) return false;
    final parser = SqlParser(sql);
    return parser.take('CREATE') && parser.take('VIRTUAL');
  }

  static VirtualTableDeclaration parse(String sql) {
    final parser = SqlParser(sql);
    parser.require('CREATE');
    parser.require('VIRTUAL');
    parser.require('TABLE');
    var ifNotExists = false;
    if (parser.take('IF')) {
      parser.require('NOT');
      parser.require('EXISTS');
      ifNotExists = true;
    }
    final name = parser.identifier();
    List<(String, bool)>? declaredColumns;
    if (parser.take('(')) {
      declaredColumns = [];
      if (!parser.take(')')) {
        do {
          final column = parser.identifier();
          declaredColumns.add((column, parser.take('HIDDEN')));
        } while (parser.take(','));
        parser.require(')');
      }
    }
    parser.require('USING');
    final module = parser.identifier();
    final arguments = <String>[];
    if (parser.take('(')) {
      if (!parser.take(')')) {
        do {
          arguments.add(_argument(parser));
        } while (parser.take(','));
        parser.require(')');
      }
    }
    parser.finish();
    return VirtualTableDeclaration(name, module, arguments,
        ifNotExists: ifNotExists, declaredColumns: declaredColumns);
  }

  static String _argument(SqlParser parser) {
    final start = parser.position;
    final startOffset = parser.current.offset;
    var depth = 0;
    while (parser.current.kind != SqlTokenKind.end) {
      final token = parser.current;
      final symbol = token.kind == SqlTokenKind.symbol;
      if (depth == 0 && symbol && (token.text == ',' || token.text == ')')) {
        break;
      }
      if (symbol && token.text == '(') depth++;
      if (symbol && token.text == ')') {
        if (depth == 0) break;
        depth--;
      }
      parser.position++;
    }
    if (parser.position == start) {
      throw SqlException('Unsupported virtual table argument', startOffset);
    }
    if (parser.position == start + 1) return parser.tokens[start].text;
    final source = parser.source;
    if (source == null) {
      return parser.tokens
          .sublist(start, parser.position)
          .map((token) => token.text)
          .join(' ');
    }
    return source.substring(startOffset, parser.current.offset).trim();
  }
}

/// Materializes module rows as synthetic table records. The module is resolved
/// from the connection that is executing the statement.
abstract final class VirtualTableRows {
  static const maximumRows = 100000;

  static List<BtreeRecord> records(CatalogTable table,
      {Expr? where,
      List<Object?> parameters = const [],
      bool allowUnqualified = false,
      String? alias}) {
    final moduleName = table.virtualModule;
    if (moduleName == null) {
      throw const SqlException('Not a virtual table');
    }
    final module = VirtualTableRegistry.current?.find(moduleName);
    if (module == null) {
      throw SqlException('No such module: $moduleName');
    }
    invokeVirtualTableCallback(
        'xConnect', () => module.xConnect(table.name, table.virtualArguments));
    module.prepareScan(table, where, parameters);
    final cursor = module.xOpen(table.name);
    final records = <BtreeRecord>[];
    Object? failure;
    try {
      try {
        final plan = VirtualTableIndexPlan([
          if (table.virtualPositionals != null)
            for (var index = 0;
                index < table.virtualPositionals!.length;
                index++)
              VirtualTableConstraint(module.columns.length + index, '=',
                  table.virtualPositionals![index]),
          ...virtualTableConstraints(where, table, parameters,
              allowUnqualified: allowUnqualified, alias: alias)
        ]);
        try {
          module.bestIndex(plan);
        } on ArgumentError {
          throw const SqlException(
              'Virtual table constraint index out of range');
        }
        cursor.applyArguments(table.virtualPositionals ?? const []);
        cursor.applyConstraints(plan.used);
        cursor.filter(table.name, table.virtualArguments);
        while (!cursor.eof) {
          if (records.length >= maximumRows) {
            throw const SqlException('Virtual table row limit exceeded');
          }
          final rowid = cursor.rowid;
          final values = [
            for (var index = 0; index < table.columns.length; index++)
              _value(cursor.column(index))
          ];
          records.add(BtreeRecord.synthetic(rowid, values));
          cursor.next();
        }
      } on SqlException catch (error) {
        failure = error;
      } catch (_) {
        failure = SqlException('Virtual table module $moduleName failed');
      }
    } finally {
      try {
        cursor.close();
      } on SqlException catch (error) {
        failure ??= error;
      } catch (_) {
        failure ??= const SqlException('Virtual table cursor close failed');
      }
      try {
        module.xDisconnect(table.name);
      } on SqlException catch (error) {
        failure ??= error;
      } catch (_) {
        failure ??= const SqlException('Virtual table xDisconnect failed');
      }
    }
    if (failure != null) throw failure;
    return records;
  }

  static Object? _value(Object? value) {
    if (value == null || value is BigInt || value is String) return value;
    if (value is int) return BigInt.from(value);
    if (value is double) return value.isNaN ? null : value;
    if (value is Uint8List) return Uint8List.fromList(value);
    throw const SqlException(
        'Virtual table module returned an unsupported value');
  }
}

CatalogTable virtualCatalogTable(VirtualTableModule module, String name,
    {List<String> arguments = const [], List<Object?>? positionals}) {
  return CatalogTable(
      name,
      0,
      [
        for (final column in module.columnsFor(name, arguments))
          CatalogColumn(column, ''),
        for (final column in module.hiddenFor(name, arguments))
          CatalogColumn(column, '', hidden: true)
      ],
      virtualModule: module.name,
      virtualArguments: arguments,
      virtualPositionals: positionals);
}

Object? evaluateVirtualArgument(Expr expression, List<Object?> parameters) {
  if (expression is Literal) return expression.value;
  if (expression is ParameterExpr) {
    if (expression.index < 0 || expression.index >= parameters.length) {
      throw const SqlException('Incorrect parameter count');
    }
    return parameters[expression.index];
  }
  if (expression is UnaryExpr &&
      (expression.op == '+' || expression.op == '-')) {
    final value = evaluateVirtualArgument(expression.operand, parameters);
    if (value is BigInt) return expression.op == '-' ? -value : value;
    if (value is int) {
      return expression.op == '-' ? -value : value;
    }
    if (value is double) return expression.op == '-' ? -value : value;
  }
  throw const SqlException('Virtual table argument must be constant');
}

List<VirtualTableConstraint> virtualTableConstraints(
    Expr? where, CatalogTable table, List<Object?> parameters,
    {required bool allowUnqualified, String? alias}) {
  final constraints = <VirtualTableConstraint>[];
  void walk(Expr? expression) {
    if (expression is! BinaryExpr) return;
    if (expression.op == 'AND') {
      walk(expression.left);
      walk(expression.right);
      return;
    }
    if (!['=', '==', '<', '<=', '>', '>='].contains(expression.op)) return;
    ColumnExpr? column;
    Expr? constant;
    var operator = expression.op == '==' ? '=' : expression.op;
    if (expression.left is ColumnExpr &&
        _constant(expression.right, parameters)) {
      column = expression.left as ColumnExpr;
      constant = expression.right;
    } else if (expression.right is ColumnExpr &&
        _constant(expression.left, parameters)) {
      column = expression.right as ColumnExpr;
      constant = expression.left;
      operator = _flip(operator);
    } else {
      return;
    }
    final index = _columnIndex(column, table, allowUnqualified, alias);
    if (index == null) return;
    constraints.add(VirtualTableConstraint(
        index, operator, evaluateVirtualArgument(constant, parameters)));
  }

  walk(where);
  return constraints;
}

bool _constant(Expr expression, List<Object?> parameters) {
  try {
    evaluateVirtualArgument(expression, parameters);
    return true;
  } on SqlException {
    return false;
  }
}

String _flip(String operator) => switch (operator) {
      '<' => '>',
      '<=' => '>=',
      '>' => '<',
      '>=' => '<=',
      _ => operator
    };

int? _columnIndex(ColumnExpr column, CatalogTable table, bool allowUnqualified,
    String? alias) {
  final qualifier =
      column.qualifier == null ? null : asciiLower(column.qualifier!);
  final tableName = asciiLower(table.name);
  final aliasName = alias == null ? null : asciiLower(alias);
  final matchesQualifier = qualifier == tableName ||
      qualifier == 'main.$tableName' ||
      aliasName != null &&
          (qualifier == aliasName || qualifier == 'main.$aliasName');
  if (qualifier != null && !matchesQualifier) return null;
  if (qualifier == null && !allowUnqualified) return null;
  final key = qualifier == null
      ? column.key
      : column.key.startsWith('$qualifier.')
          ? column.key.substring(qualifier.length + 1)
          : column.key;
  final index =
      table.columns.indexWhere((entry) => asciiLower(entry.name) == key);
  return index < 0 ? null : index;
}

void validateVirtualColumns(VirtualTableModule module, String name,
    List<String> arguments, List<(String, bool)>? declared) {
  if (declared == null) return;
  final expected = [
    for (final column in module.columnsFor(name, arguments))
      (asciiLower(column), false),
    for (final column in module.hiddenFor(name, arguments))
      (asciiLower(column), true)
  ];
  final actual = [
    for (final column in declared) (asciiLower(column.$1), column.$2)
  ];
  if (actual.length != expected.length) {
    throw const SqlException('Virtual table column mismatch');
  }
  for (var index = 0; index < actual.length; index++) {
    if (actual[index] != expected[index]) {
      throw const SqlException('Virtual table column mismatch');
    }
  }
}

/// SQLite's eponymous integer series. `value` is visible; `start`, `stop`,
/// and `step` are hidden. A zero step yields no rows. An omitted start is 0,
/// an omitted stop is 4294967295, and an omitted step is 1. The pinned
/// SQLite 3.53.1 library is not installed here, so this follows that
/// documented algorithm rather than a freshly generated 3.53.1 oracle.
final class GenerateSeriesModule extends VirtualTableModule {
  @override
  String get name => 'generate_series';
  @override
  List<String> get columns => const ['value'];
  @override
  List<String> get hiddenColumns => const ['start', 'stop', 'step'];
  @override
  bool get eponymous => true;

  @override
  void bestIndex(VirtualTableIndexPlan plan) {
    final seen = <int>{};
    for (var index = 0; index < plan.constraints.length; index++) {
      final constraint = plan.constraints[index];
      if (constraint.operator == '=' &&
          constraint.column >= 1 &&
          constraint.column <= 3 &&
          seen.add(constraint.column)) {
        plan.use(index);
      }
    }
  }

  @override
  VirtualTableCursor xOpen(String table) => _GenerateSeriesCursor();
}

final class _GenerateSeriesCursor extends VirtualTableCursor {
  static final BigInt _min = BigInt.parse('-9223372036854775808');
  static final BigInt _max = BigInt.parse('9223372036854775807');
  static final BigInt _defaultStop = BigInt.from(0xffffffff);
  BigInt? _start;
  BigInt? _stop;
  BigInt? _step;
  BigInt _value = BigInt.zero;
  var _row = 0;
  var _closed = false;
  var _empty = false;

  void _live() {
    if (_closed) throw const SqlException('Virtual table cursor is closed');
  }

  @override
  void applyConstraints(List<VirtualTableConstraint> constraints) {
    _live();
    for (final constraint in constraints) {
      final number = _integer(constraint.value);
      if (constraint.column == 1) _start = number;
      if (constraint.column == 2) _stop = number;
      if (constraint.column == 3) _step = number;
    }
  }

  @override
  void filter(String table, List<String> arguments) {
    _live();
    if (arguments.length > 3) {
      throw const SqlException('Too many arguments for generate_series');
    }
    if (arguments.isNotEmpty) _start ??= _integer(arguments[0]);
    if (arguments.length > 1) _stop ??= _integer(arguments[1]);
    if (arguments.length > 2) _step ??= _integer(arguments[2]);
    _start ??= BigInt.zero;
    _stop ??= _defaultStop;
    _step ??= BigInt.one;
    _value = _start!;
    _row = 1;
    _empty = _step == BigInt.zero ||
        (_step! > BigInt.zero && _value > _stop!) ||
        (_step! < BigInt.zero && _value < _stop!);
  }

  @override
  void next() {
    _live();
    if (_empty || eof) return;
    if (_overflows(_value, _step!)) {
      _empty = true;
      return;
    }
    _value += _step!;
    _row++;
    if (_step! > BigInt.zero && _value > _stop! ||
        _step! < BigInt.zero && _value < _stop!) {
      _empty = true;
    }
  }

  @override
  bool get eof {
    _live();
    return _empty;
  }

  @override
  Object? column(int index) {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    return switch (index) {
      0 => _value,
      1 => _start,
      2 => _stop,
      3 => _step,
      _ => throw const SqlException('Virtual table column index out of range')
    };
  }

  @override
  BigInt get rowid {
    _live();
    if (eof) {
      throw const SqlException('Virtual table cursor is past the last row');
    }
    return BigInt.from(_row);
  }

  @override
  void close() {
    _closed = true;
  }

  static bool _overflows(BigInt value, BigInt step) =>
      step > BigInt.zero && value > _max - step ||
      step < BigInt.zero && value < _min - step;

  static BigInt _integer(Object? value) {
    if (value == null) return BigInt.zero;
    if (value is BigInt) return value;
    if (value is int) return BigInt.from(value);
    if (value is String) {
      final parsed = BigInt.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw const SqlException('generate_series bounds must be integers');
  }
}
