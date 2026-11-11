import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import '../btree/btree_reader.dart';
import '../pager/read_only_pager.dart';
import '../storage/storage_backend.dart';
import 'catalog.dart';
import 'column_rewriter.dart' show prepareSubqueryWidths;
import 'parser.dart';
import 'functions.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'expressions.dart';
import 'function_registry.dart';
import 'image_mutations.dart';
import 'index_definition.dart';
import 'planner_statistics.dart';
import 'bounded_sort_heap.dart';
import 'windows.dart';
import 'search_modules.dart';
import 'search_runtime.dart';
import 'virtual_table.dart';

part 'relational.dart';
part 'join_groups.dart';
part 'dml_subqueries.dart';
part 'lazy_views.dart';
part 'query_execution.dart';
part 'query_diagnostics.dart';
part 'pragma_tables.dart';

/// Header write version 1 is rollback. Version 2 is wal. Other values throw.
String sqlJournalMode(int writeVersion) {
  if (writeVersion == 1) return 'rollback';
  if (writeVersion == 2) return 'wal';
  throw ArgumentError('Unsupported journal write version');
}

/// Materialized rows from one SQL statement.
final class QueryResult implements SqlRows {
  /// Columns and rows. Affinity, declared type, and collation follow [columns].
  QueryResult(List<String> columns, List<List<Object?>> rows,
      [List<String>? affinities,
      List<String>? declaredTypes,
      List<String>? collations])
      : columnDeclaredTypes =
            List.unmodifiable(declaredTypes ?? List.filled(columns.length, '')),
        columnCollations =
            List.unmodifiable(collations ?? List.filled(columns.length, '')),
        columnAffinities = List.unmodifiable(
            affinities ?? List.filled(columns.length, 'none')),
        columns = List.unmodifiable(columns),
        rows = List.unmodifiable(rows.map(List<Object?>.unmodifiable));

  /// Storage affinity for each column, or `none` when the statement has none.
  @override
  final List<String> columnAffinities;

  /// Declared type text for each column. Empty when the statement has none.
  final List<String> columnDeclaredTypes;

  /// Collation name for each column.
  @override
  final List<String> columnCollations;

  /// Column names in result order.
  @override
  final List<String> columns;

  /// Row values. Integers are [BigInt].
  @override
  final List<List<Object?>> rows;
}

/// How one statement reached its rows. This is not SQLite bytecode.
final class QueryPlan {
  /// A scan described by [access], optional [rootPage], and optional [rowid].
  const QueryPlan(this.access, this.rootPage, this.rowid,
      {this.scanSatisfiesOrder = false,
      this.scanReverse = false,
      this.orderedPrefix = 0})
      : _index = null,
        covering = false,
        coveredColumns = const [];
  const QueryPlan._indexed(this.rootPage, this._index, this.access,
      {this.covering = false,
      this.coveredColumns = const [],
      this.scanSatisfiesOrder = false,
      this.scanReverse = false,
      this.orderedPrefix = 0})
      : rowid = null;
  final _IndexAccess? _index;

  /// Whether the chosen index contains every selected column.
  final bool covering;

  /// Columns the chosen index can satisfy without the table row.
  final List<String> coveredColumns;

  /// Secondary index name, or null for a table scan.
  String? get indexName => _index?.table == false ? _index?.name : null;

  /// Short description of the access path.
  final String access;

  /// B-tree root page, when the plan names one.
  final int? rootPage;

  /// Point-lookup rowid, when the plan is a single row.
  final BigInt? rowid;

  /// Whether the scan of this plan already yields [SelectStatement.order].
  ///
  /// This is a delivery fact for the direct single-table reader. It does not
  /// mean every SQL shape can skip sorting. [scanReverse] means the reader
  /// walks that scan from the opposite end.
  final bool scanSatisfiesOrder;

  /// Walk the chosen full scan from its last key back to its first.
  final bool scanReverse;

  /// Leading [SelectStatement.order] terms this scan already groups.
  ///
  /// Zero means the scan does not feed a block sort. A positive value shorter
  /// than the full order sorts each equal-prefix run and leaves the other
  /// shapes on the existing sort.
  final int orderedPrefix;
}

/// One `EXPLAIN QUERY PLAN` row. [id] is the compared opcode address,
/// [notused] is the compared `rRun` cost, and [detail] is the plan text.
final class ExplainPlanRow {
  const ExplainPlanRow(this.id, this.parent, this.notused, this.detail);
  final int id;
  final int parent;
  final int notused;
  final String detail;
}

/// Default `nRowLogEst` when `sqlite_stat1` is absent: `sqlite3LogEst(1048576)`.
const _defaultRowLogEst = 200;

/// SQLite 3.53.1 `sqlite3LogEst` for the costs compared in the B3 plan tests.
int _sqliteLogEst(int value) {
  const adjustments = <int>[0, 2, 3, 5, 6, 7, 8, 9];
  var estimate = 40;
  var number = value;
  if (number < 2) return 0;
  if (number < 8) {
    while (number < 8) {
      estimate -= 10;
      number <<= 1;
    }
  } else {
    while (number > 255) {
      estimate += 40;
      number >>= 4;
    }
    while (number > 15) {
      estimate += 10;
      number >>= 1;
    }
  }
  return adjustments[number & 7] + estimate - 10;
}

/// SQLite 3.53.1 `sqlite3LogEstAdd`.
int _sqliteLogEstAdd(int left, int right) {
  const extra = <int>[
    10, 10, 9, 9, 8, 8, 7, 7, 7, 6, 6, 6, 5, 5, 5, 4, 4, 4, 4, //
    3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2
  ];
  if (left >= right) {
    if (left > right + 49) return left;
    if (left > right + 31) return left + 1;
    return left + extra[left - right];
  }
  if (right > left + 49) return right;
  if (right > left + 31) return right + 1;
  return right + extra[right - left];
}

int _estLog(int rows) => rows <= 10 ? 0 : _sqliteLogEst(rows) - 33;

final class _IndexAccess {
  _IndexAccess(this.name, this.compare,
      {this.table = false, this.empty = false, this.probes});
  final String name;
  final int Function(List<Object?>) compare;
  final bool table, empty;

  /// One equality probe per constant in an `IN` list or same-column `OR`.
  final List<int Function(List<Object?>)>? probes;
}

/// M3 read-only single-table SELECT API. Unsupported SQL fails explicitly.
final class SqliteDatabase {
  SqliteDatabase._(this._pager, this.catalog, this._statistics,
      [SqlFunctionRegistry? registry])
      : functions = registry ?? SqlFunctionRegistry();
  final ReadOnlyPager _pager;

  /// Parsed schema for this image.
  final DatabaseCatalog catalog;
  final PlannerStatistics _statistics;

  /// Scalar, aggregate, and collation callbacks for this connection.
  final SqlFunctionRegistry functions;

  /// Unresolved double-quoted expression identifiers become strings when this
  /// is true. The default is false.
  bool get doubleQuotedStrings => functions.doubleQuotedStrings;
  set doubleQuotedStrings(bool value) => functions.doubleQuotedStrings = value;
  bool _closed = false;

  /// Opens a read-only database on [storage].
  static Future<SqliteDatabase> openReadOnly(StorageBackend storage,
      {SqlFunctionRegistry? functions}) async {
    final pager = await ReadOnlyPager.open(storage);
    try {
      final catalog = await DatabaseCatalog.read(pager);
      return SqliteDatabase._(pager, catalog,
          await PlannerStatistics.read(pager, catalog), functions);
    } catch (_) {
      await pager.close();
      rethrow;
    }
  }

  /// Releases the pager. Later reads fail.
  Future<void> close() async {
    _closed = true;
    await _pager.close();
  }

  bool _planningConstant(Expr expression) {
    // Fallback boolean names can become real columns in the prepared scope.
    if (expression is BoolNameExpr) return false;
    if (expression.containsAggregate ||
        expression.containsWindow ||
        expression is SubqueryExpr ||
        expression is InSelectExpr ||
        expression is FunctionExpr && expression.registered != null) {
      return false;
    }
    if (expression.children.any((child) => !_planningConstant(child))) {
      return false;
    }
    try {
      expression.validate({});
      return true;
    } on SqlException {
      return false;
    }
  }

  /// Distinct non-null constants for `column IN (...)` or `column = a OR
  /// column = b` on the leading index column. A subquery, column, or `NOT`
  /// form returns null so the ordinary filter remains responsible.
  List<Object?>? _constantEqualityProbes(
      Expr? where, Expr column, String collation, EvalContext context) {
    final constants =
        _inConstants(where, column) ?? _orConstants(where, column);
    if (constants == null || constants.length > 32) return null;
    final values = <Object?>[];
    for (final constant in constants) {
      if (!_planningConstant(constant)) return null;
      final value =
          applyAffinity(constant.evaluate(context), column.affinity(context));
      if (value == null) continue;
      if (values.any((existing) =>
          compareValues(existing, value, context.encoding, collation) == 0)) {
        continue;
      }
      values.add(value);
    }
    return values.isEmpty ? null : values;
  }

  List<Expr>? _inConstants(Expr? where, Expr column) {
    InExpr? found;
    var duplicate = false;
    void walk(Expr? expr) {
      if (duplicate || expr == null) return;
      if (expr is BinaryExpr && expr.op == 'AND') {
        walk(expr.left);
        walk(expr.right);
        return;
      }
      if (expr is InExpr &&
          !expr.negate &&
          sameExpression(indexOperand(expr.operand), indexOperand(column))) {
        if (found != null) duplicate = true;
        found = expr;
      }
    }

    walk(where);
    return duplicate || found == null ? null : found!.values;
  }

  List<Expr>? _orConstants(Expr? where, Expr column) {
    List<Expr>? found;
    var duplicate = false;
    void walk(Expr? expr) {
      if (duplicate || expr == null) return;
      if (expr is BinaryExpr && expr.op == 'AND') {
        walk(expr.left);
        walk(expr.right);
        return;
      }
      if (expr is BinaryExpr && expr.op == 'OR') {
        final values = _flatOrEquals(expr, column);
        if (values == null) return;
        if (found != null) duplicate = true;
        found = values;
      }
    }

    walk(where);
    return duplicate || found == null ? null : found;
  }

  List<Expr>? _flatOrEquals(Expr expr, Expr column) {
    if (expr is BinaryExpr && expr.op == 'OR') {
      final left = _flatOrEquals(expr.left, column);
      final right = _flatOrEquals(expr.right, column);
      if (left == null || right == null) return null;
      return [...left, ...right];
    }
    if (expr is! BinaryExpr || (expr.op != '=' && expr.op != '==')) return null;
    if (sameExpression(indexOperand(expr.left), indexOperand(column)) &&
        _planningConstant(expr.right)) {
      return [expr.right];
    }
    if (sameExpression(indexOperand(expr.right), indexOperand(column)) &&
        _planningConstant(expr.left)) {
      return [expr.left];
    }
    return null;
  }

  Stream<BtreeRecord> _indexMatches(
      BtreeReader reader, QueryPlan plan, _IndexAccess access) async* {
    final probes =
        access.probes ?? <int Function(List<Object?>)>[access.compare];
    final seen = <BigInt>{};
    for (final probe in probes) {
      await for (final entry in reader.seekIndex(plan.rootPage!, probe,
          reverse: probes.length == 1 && plan.scanReverse)) {
        if (probes.length > 1) {
          final rowid = entry.values.last;
          if (rowid is! BigInt || !seen.add(rowid)) continue;
        }
        yield entry;
      }
    }
  }

  CatalogEntry? _hintIndex(QuerySource source, Expr? where,
      {bool physical = true}) {
    if (source.indexedBy == null) return null;
    var entry = physical
        ? catalog.entries
            .where((entry) =>
                entry.type == 'index' &&
                asciiLower(entry.tableName) == asciiLower(source.table!) &&
                asciiLower(entry.name) == asciiLower(source.indexedBy!))
            .firstOrNull
        : null;
    if (entry == null && physical) {
      final table = catalog.table(source.table!);
      if (table.withoutRowid) {
        final ordinal = table.autoIndexPrimary.indexOf(true) + 1;
        final name = 'sqlite_autoindex_${table.name}_$ordinal';
        if (asciiLower(name) == asciiLower(source.indexedBy!)) {
          entry = CatalogEntry('index', name, table.name, table.rootPage, null);
        }
      }
    }
    if (entry == null) throw SqlException('No such index: ${source.indexedBy}');
    final table = catalog.table(entry.tableName);
    final definition =
        entry.sql == null ? null : IndexDefinition.parse(entry.sql!, table);
    if (!impliesIndexPredicate(where, definition?.predicate,
        columnKey: (column) =>
            indexColumnKey(column, source.alias ?? source.table!))) {
      throw const SqlException('No query solution for required index');
    }
    return entry;
  }

  bool _coveredByIndex(SelectStatement statement, CatalogTable table,
      List<String> indexColumns) {
    if (statement.items.any((item) => item.expression == null)) return false;
    if (table.columns.any((column) => column.generatedExpression != null)) {
      return false;
    }
    final available = indexColumns.toSet();
    final referenced = <String>{};
    void walk(Expr? expression) {
      if (expression == null) return;
      if (expression is ColumnExpr) {
        final key = expression.key;
        referenced.add(key.contains('.') ? key.split('.').last : key);
        return;
      }
      for (final child in expression.children) {
        walk(child);
      }
    }

    for (final item in statement.items) {
      walk(item.expression);
    }
    walk(statement.where);
    final rowids = {
      'rowid',
      '_rowid_',
      'oid',
      if (table.rowidAlias != null) asciiLower(table.rowidAlias!)
    };
    for (final name in referenced) {
      if (!available.contains(name) && !rowids.contains(name)) return false;
    }
    return true;
  }

  /// Distinct inner keys kept for one join probe. Past this, the join scans.
  static const _maxJoinLookupKeys = 1024;

  List<List<RowValues>>? _equalGroups(
      List<RowValues> rows, String key, CatalogColumn column) {
    final groups = <List<RowValues>>[];
    final representatives = <Object?>[];
    for (final row in rows) {
      final value = row[key];
      var placed = false;
      for (var i = 0; i < representatives.length; i++) {
        if (value != null &&
            compareValues(
                    applyAffinity(representatives[i], column.affinity),
                    applyAffinity(value, column.affinity),
                    _pager.header.textEncoding,
                    column.collation) ==
                0) {
          groups[i].add(row);
          placed = true;
          break;
        }
      }
      if (!placed) {
        if (groups.length >= _maxJoinLookupKeys) return null;
        representatives.add(value);
        groups.add([row]);
      }
    }
    return groups;
  }

  List<QuerySource> _orderedJoinSources(SelectStatement statement) {
    final sources = [...statement.normalizedSources];
    if (statement.order.isEmpty || sources.length < 2 || sources.length > 4) {
      return sources;
    }
    if (sources.any((source) =>
        source.on != null ||
        source.using.isNotEmpty ||
        source.natural ||
        source.query != null ||
        source.group.isNotEmpty ||
        source.table == null)) {
      return sources;
    }
    if (sources.skip(1).any((source) => source.join != 'CROSS')) {
      return sources;
    }
    final counts = [
      for (final source in sources) _statistics.rowCount(source.table!)
    ];
    if (counts.any((count) => count == null)) return sources;
    final best = counts.reduce((a, b) => a! <= b! ? a : b);
    if (counts.first == best) return sources;
    final ordered = [...sources];
    ordered.sort((a, b) => _statistics
        .rowCount(a.table!)!
        .compareTo(_statistics.rowCount(b.table!)!));
    return ordered;
  }

  /// Moves `json_each` and `json_tree` after the tables their arguments name
  /// when every join in between is an inner join. Outer joins stay in place.
  List<QuerySource> _orderCorrelatedTableFunctions(
      List<QuerySource> sources, List<Object?> parameters) {
    final ordered = [...sources];
    for (var guard = 0; guard < ordered.length; guard++) {
      var moved = false;
      for (var index = 0; index < ordered.length; index++) {
        final source = ordered[index];
        if (!_correlatedJsonFunction(source, parameters)) continue;
        final dependencies = <int>[];
        for (final argument in source.pragmaArguments!) {
          for (final name in argument.unaggregatedColumns) {
            for (var other = 0; other < ordered.length; other++) {
              if (other != index &&
                  _sourceProvidesColumn(ordered[other], name)) {
                dependencies.add(other);
              }
            }
          }
        }
        if (dependencies.isEmpty) continue;
        final destination = dependencies.reduce((a, b) => a > b ? a : b);
        if (destination <= index) continue;
        if (ordered
            .sublist(index + 1, destination + 1)
            .any((later) => !const {'INNER', 'CROSS'}.contains(later.join))) {
          continue;
        }
        ordered.removeAt(index);
        ordered.insert(destination, source);
        moved = true;
        break;
      }
      if (!moved) break;
    }
    return ordered;
  }

  bool _perCallTableFunction(QuerySource source) {
    final name = asciiLower(source.table ?? '');
    return source.pragmaArguments != null &&
        (name == 'json_each' || name == 'json_tree');
  }

  bool _correlatedJsonFunction(QuerySource source, List<Object?> parameters) {
    final arguments = source.pragmaArguments;
    final table = source.table;
    if (arguments == null || table == null) return false;
    final name = asciiLower(table);
    if (name != 'json_each' && name != 'json_tree') return false;
    if (_isPragmaTableSource(source)) return false;
    for (final argument in arguments) {
      try {
        evaluateVirtualArgument(argument, parameters);
      } on SqlException {
        return true;
      }
    }
    return false;
  }

  /// A later FROM item exposes [key] when the alias and the real column match.
  /// An aliased table does not keep its original name.
  bool _laterSourceHasColumn(QuerySource source, String key) {
    final alias = asciiLower(source.alias ?? source.table ?? '');
    if (alias.isEmpty || source.table == null || source.query != null) {
      return false;
    }
    String? column;
    if (key.startsWith('$alias.')) {
      column = key.substring(alias.length + 1);
    } else if (key.startsWith('main.$alias.')) {
      column = key.substring(alias.length + 6);
    } else if (!key.contains('.')) {
      column = key;
    }
    if (column == null || column.isEmpty || column.contains('.')) return false;
    try {
      final table = catalog.table(source.table!);
      if (table.columns.any((c) => asciiLower(c.name) == column)) return true;
      return !table.withoutRowid &&
          const {'rowid', '_rowid_', 'oid'}.contains(column) &&
          !table.columns.any((c) => asciiLower(c.name) == column);
    } on SqlException {
      return false;
    }
  }

  bool _sourceProvidesColumn(QuerySource source, String key) {
    final alias = asciiLower(source.alias ?? source.table ?? '');
    if (alias.isNotEmpty &&
        (key == alias ||
            key.startsWith('$alias.') ||
            key.startsWith('main.$alias.'))) {
      return true;
    }
    final table = source.table == null ? '' : asciiLower(source.table!);
    if (table.isNotEmpty &&
        alias != table &&
        (key == table || key.startsWith('$table.'))) {
      return true;
    }
    if (key.contains('.') || source.table == null) return false;
    try {
      return catalog
          .table(source.table!)
          .columns
          .any((column) => asciiLower(column.name) == key);
    } on SqlException {
      return false;
    }
  }

  /// Plans this statement from the catalog visible now. The result is not stored.
  QueryPlan _plan(
      SelectStatement statement, CatalogTable? table, List<Object?> bound,
      [_SqlDiagnosticTrace? diagnostics]) {
    if (table == null) {
      diagnostics?.record('constant', 'constant-source',
          estimate: 1, chosen: true);
      return const QueryPlan('constant', null, null);
    }
    if (table.virtual) return const QueryPlan('virtual-table-scan', null, null);
    final source = statement.sources.firstOrNull;
    final forced = source == null ? null : _hintIndex(source, statement.where);
    final notIndexed = source?.notIndexed ?? false;
    if (!table.withoutRowid && forced == null) {
      BigInt? lookup(Expr? expr) {
        if (expr is! BinaryExpr) return null;
        if (expr.op == 'AND') return lookup(expr.left) ?? lookup(expr.right);
        if (!['=', '=='].contains(expr.op)) return null;
        ColumnExpr? column;
        Expr? constant;
        if (expr.left is ColumnExpr) {
          column = expr.left as ColumnExpr;
          constant = expr.right;
        } else if (expr.right is ColumnExpr) {
          column = expr.right as ColumnExpr;
          constant = expr.left;
        }
        if (column == null) return null;
        final alias = table.rowidAlias;
        final actual =
            table.columns.where((c) => asciiLower(c.name) == column!.key);
        if (!(alias != null && column.key == asciiLower(alias)) &&
            (!['rowid', '_rowid_', 'oid'].contains(column.key) ||
                actual.isNotEmpty)) {
          return null;
        }
        try {
          constant!.validate({});
        } on SqlException {
          return null;
        }
        if (!_planningConstant(constant)) return null;
        var value = applyAffinity(
            constant.evaluate(
                EvalContext({}, {}, bound, _pager.header.textEncoding)),
            'numeric');
        if (value is double &&
            value.isFinite &&
            value == value.truncateToDouble()) {
          value = BigInt.from(value);
        }
        return value is BigInt &&
                value >= -(BigInt.one << 63) &&
                value < BigInt.one << 63
            ? value
            : null;
      }

      final key = lookup(statement.where);
      if (key != null) {
        diagnostics?.record('rowid-lookup', 'rowid-equality-priority',
            estimate: 1, chosen: true);
        return QueryPlan('rowid-lookup', table.rootPage, key,
            scanSatisfiesOrder: _queryCanReuseIndexOrder(statement));
      }
    }
    {
      final constraints = <BinaryExpr>[];
      void collect(Expr? expr) {
        if (expr is BinaryExpr && expr.op == 'AND') {
          collect(expr.left);
          collect(expr.right);
        } else if (expr is BinaryExpr &&
            ['=', '==', '<', '<=', '>', '>='].contains(expr.op)) {
          constraints.add(expr);
        } else if (expr is BetweenExpr && !expr.negate) {
          constraints
            ..add(BinaryExpr('>=', expr.operand, expr.low))
            ..add(BinaryExpr('<=', expr.operand, expr.high));
        }
      }

      collect(statement.where);
      final context = EvalContext(
          {},
          {for (final c in table.columns) asciiLower(c.name): c.affinity},
          bound,
          _pager.header.textEncoding)
        ..collations = {
          for (final c in table.columns) asciiLower(c.name): c.collation
        };
      List<(String, Object?)> bounds(
          Expr sought, String affinity, String collation) {
        final result = <(String, Object?)>[];
        for (final expr in constraints) {
          Expr? constant;
          var op = expr.op;
          if (sameExpression(indexOperand(expr.left), indexOperand(sought))) {
            constant = expr.right;
          } else if (sameExpression(
              indexOperand(expr.right), indexOperand(sought))) {
            constant = expr.left;
            op = const {
              '<': '>',
              '<=': '>=',
              '>': '<',
              '>=': '<=',
              '=': '=',
              '==': '=='
            }[op]!;
          }
          if (constant == null || !_planningConstant(constant)) continue;
          final otherAffinity = constant.affinity(context);
          if (otherAffinity == 'numeric' && affinity != 'numeric' ||
              otherAffinity == 'text' && affinity == 'none') {
            continue;
          }
          final comparisonCollation = expr.left.explicitCollation(context) ??
              expr.right.explicitCollation(context) ??
              expr.left.collation(context) ??
              expr.right.collation(context) ??
              'binary';
          if (comparisonCollation != collation) continue;
          result.add((op, applyAffinity(constant.evaluate(context), affinity)));
        }
        return result;
      }

      int comparison(
          Object? value, List<(String, Object?)> bounds, String collation) {
        for (final bound in bounds) {
          final c = compareValues(value, bound.$2, context.encoding, collation);
          switch (bound.$1) {
            case '=':
            case '==':
              if (c != 0) return c;
            case '>':
              if (c <= 0) return -1;
            case '>=':
              if (c < 0) return -1;
            case '<':
              if (c >= 0) return 1;
            case '<=':
              if (c > 0) return 1;
          }
        }
        return 0;
      }

      final rowidNames = [
        if (table.rowidAlias != null) table.rowidAlias!,
        for (final alias in ['rowid', '_rowid_', 'oid'])
          if (!table.columns.any((c) => asciiLower(c.name) == alias)) alias
      ];
      final rowBounds = [
        for (final name in rowidNames)
          ...bounds(ColumnExpr(name), 'numeric', 'binary')
      ];
      if (rowBounds.isNotEmpty && forced == null && !table.withoutRowid) {
        diagnostics?.record('rowid-range', 'rowid-range-priority',
            chosen: true);
        return QueryPlan._indexed(
            table.rootPage,
            _IndexAccess('@rowid',
                (values) => comparison(values.single, rowBounds, 'binary'),
                table: true, empty: rowBounds.any((b) => b.$2 == null)),
            'rowid-range',
            scanSatisfiesOrder: _primaryScanSatisfiesOrder(statement, table));
      }
      if (notIndexed && !table.withoutRowid) {
        diagnostics?.record('table-scan', 'NOT-INDEXED',
            estimate: _statistics.rowCount(table.name), chosen: true);
        final delivery = _primaryFullScanDelivery(statement, table);
        return QueryPlan('table-scan', table.rootPage, null,
            scanSatisfiesOrder: delivery != null,
            scanReverse: delivery?.reverse ?? false);
      }
      QueryPlan? best;
      var bestScore = -1;
      double? bestEstimate;
      for (final entry in catalog.entries.where((e) =>
          !notIndexed &&
          e.type == 'index' &&
          asciiLower(e.tableName) == asciiLower(table.name) &&
          (forced == null || asciiLower(e.name) == asciiLower(forced.name)))) {
        try {
          if (table.withoutRowid && entry.rootPage == table.rootPage) continue;
          final parsed = entry.sql == null
              ? null
              : IndexDefinition.parse(entry.sql!, table);
          if (!impliesIndexPredicate(statement.where, parsed?.predicate,
              strongerNumeric: true)) {
            diagnostics?.record(
                'secondary-index', 'partial-predicate-not-proved',
                index: entry.name, eligible: false);
            continue;
          }
          final definition = _indexDefinition(entry);
          final prefix = <List<(String, Object?)>>[];
          var range = false;
          for (var i = 0; i < definition.$1.length; i++) {
            final expression =
                parsed?.terms[i].expression ?? ColumnExpr(definition.$1[i]);
            final matches = bounds(
                expression, expression.affinity(context), definition.$3[i]);
            if (matches.isEmpty) break;
            prefix.add(matches);
            if (!matches.any((b) => b.$1 == '=' || b.$1 == '==')) {
              range = true;
              break;
            }
          }
          final probeValues =
              prefix.isEmpty && !table.withoutRowid && definition.$1.isNotEmpty
                  ? _constantEqualityProbes(
                      statement.where,
                      parsed?.terms.isNotEmpty == true
                          ? parsed!.terms.first.expression
                          : ColumnExpr(definition.$1.first),
                      definition.$3.first,
                      context)
                  : null;
          if (prefix.isEmpty && probeValues == null) {
            diagnostics?.record(
                'secondary-index', 'no-compatible-leading-prefix',
                index: entry.name, eligible: false);
            continue;
          }
          int equalityProbe(Object? bound, List<Object?> values) {
            if (values.isEmpty) {
              throw const FormatException('Short secondary index key');
            }
            final compared = compareValues(
                values[0], bound, context.encoding, definition.$3[0]);
            if (compared != 0) return definition.$2[0] ? -compared : compared;
            return 0;
          }

          final access = probeValues != null
              ? _IndexAccess(entry.name,
                  (values) => equalityProbe(probeValues.first, values),
                  probes: [
                      for (final bound in probeValues)
                        (values) => equalityProbe(bound, values)
                    ])
              : _IndexAccess(entry.name, (values) {
                  if (values.length <= prefix.length) {
                    throw const FormatException('Short secondary index key');
                  }
                  for (var i = 0; i < prefix.length; i++) {
                    final c =
                        comparison(values[i], prefix[i], definition.$3[i]);
                    if (c != 0) return definition.$2[i] ? -c : c;
                  }
                  return 0;
                },
                  empty: prefix
                      .any((list) => list.any((bound) => bound.$2 == null)));
          final equalityPrefix = range ? prefix.length - 1 : prefix.length;
          final indexDefinition = parsed ??
              IndexDefinition(
                  entry.name,
                  table.name,
                  definition.$5,
                  [
                    for (var i = 0; i < definition.$1.length; i++)
                      IndexTerm(ColumnExpr(definition.$1[i]), definition.$1[i],
                          definition.$3[i], definition.$2[i])
                  ],
                  null);
          final satisfies = probeValues == null &&
              _indexScanSatisfiesOrder(
                  statement, table, indexDefinition, equalityPrefix);
          final score = (probeValues == null ? prefix.length : 1) * 10 +
              (definition.$5 && !range && probeValues == null ? 1 : 0);
          final rangeTerms = range ? prefix.last : <(String, Object?)>[];
          final rangeBounds =
              (rangeTerms.any((bound) => ['>', '>='].contains(bound.$1))
                      ? 1
                      : 0) +
                  (rangeTerms.any((bound) => ['<', '<='].contains(bound.$1))
                      ? 1
                      : 0);
          final estimate = probeValues != null
              ? probeValues.length.toDouble()
              : _statistics.estimate(table.name, entry.name,
                  columns: definition.$1.length,
                  equalities: prefix.length - (range ? 1 : 0),
                  rangeBounds: rangeBounds,
                  unique: definition.$5);
          final names = [
            for (final column in definition.$1) asciiLower(column)
          ];
          final covered = names.every((name) => name.isNotEmpty) &&
              _coveredByIndex(statement, table, names);
          final orderPrefix = probeValues != null || satisfies
              ? 0
              : _forwardIndexOrderPrefix(
                  statement, table, indexDefinition, equalityPrefix);
          final counted = _statistics.rowCount(table.name);
          final indexed = _statistics.indexEntries(table.name, entry.name);
          final tableRows =
              counted ?? (indexed != null && indexed > 0 ? indexed : null);
          if (estimate != null &&
              tableRows != null &&
              estimate >= tableRows &&
              !satisfies &&
              orderPrefix == 0 &&
              !covered) {
            diagnostics?.record(
                range ? 'secondary-index-range' : 'secondary-index-lookup',
                'not-cheaper-than-table-scan',
                index: entry.name,
                estimate: estimate,
                eligible: false);
            continue;
          }
          final ordinal = diagnostics?.record(
              range ? 'secondary-index-range' : 'secondary-index-lookup',
              estimate == null ? 'prefix-heuristic' : 'STAT1-assisted-estimate',
              index: entry.name,
              estimate: estimate,
              score: score);
          final onlyOneEstimate =
              best != null && (estimate == null) != (bestEstimate == null);
          final sameEstimate = best != null && estimate == bestEstimate;
          final prefer = best == null ||
              estimate != null &&
                  bestEstimate != null &&
                  estimate < bestEstimate ||
              onlyOneEstimate && score > bestScore ||
              sameEstimate &&
                  (satisfies != best.scanSatisfiesOrder
                      ? satisfies
                      : covered != best.covering
                          ? covered
                          : orderPrefix != best.orderedPrefix
                              ? orderPrefix > best.orderedPrefix
                              : score > bestScore);
          if (prefer) {
            diagnostics?.select(ordinal!, estimate);
            bestScore = score;
            bestEstimate = estimate;
            best = QueryPlan._indexed(entry.rootPage, access,
                range ? 'secondary-index-range' : 'secondary-index-lookup',
                covering: covered,
                coveredColumns: covered ? names : const [],
                scanSatisfiesOrder: satisfies,
                orderedPrefix: orderPrefix);
          }
        } on Exception {
          diagnostics?.record('secondary-index', 'index-analysis-unavailable',
              index: entry.name, eligible: false);
          continue;
        }
      }
      if (best != null) return best;
    }
    if (forced != null) {
      final forcedDefinition =
          forced.sql == null ? null : IndexDefinition.parse(forced.sql!, table);
      final forcedDelivery = forcedDefinition == null
          ? null
          : _indexScanDelivery(statement, table, forcedDefinition, 0);
      diagnostics?.record('secondary-index-scan', 'INDEXED-BY-scan',
          index: forced.name, chosen: true);
      return QueryPlan._indexed(forced.rootPage,
          _IndexAccess(forced.name, (_) => 0), 'secondary-index-scan',
          scanSatisfiesOrder: forcedDelivery != null,
          scanReverse: forcedDelivery?.reverse ?? false);
    }
    final primaryDelivery = _primaryFullScanDelivery(statement, table);
    if (primaryDelivery == null && !notIndexed) {
      final ordered = _coveringIndexOrderPlan(statement, table, diagnostics);
      if (ordered != null) return ordered;
    }
    diagnostics?.record(table.withoutRowid ? 'index-tree-scan' : 'table-scan',
        'no-eligible-narrowing-access',
        estimate: _statistics.rowCount(table.name), chosen: true);
    return QueryPlan(table.withoutRowid ? 'index-tree-scan' : 'table-scan',
        table.rootPage, null,
        scanSatisfiesOrder: primaryDelivery != null,
        scanReverse: primaryDelivery?.reverse ?? false);
  }

  CatalogTable _resolveTable(
      String name, QuerySource? source, List<Object?> parameters) {
    final key = asciiLower(name);
    final physical = catalog.entries.any(
        (entry) => entry.type != 'trigger' && asciiLower(entry.name) == key);
    final arguments = source?.pragmaArguments;
    if (arguments != null) {
      if (physical) {
        throw SqlException('$name is not a table-valued function');
      }
      final module = VirtualTableRegistry.current?.find(name);
      if (module == null || !module.eponymous) {
        throw SqlException('$name is not a table-valued function');
      }
      if (arguments.length > module.hiddenColumns.length) {
        throw SqlException('Too many arguments for $name');
      }
      final jsonModule =
          module.name == 'json_each' || module.name == 'json_tree';
      final values = <Object?>[];
      if (jsonModule) {
        try {
          for (final argument in arguments) {
            values.add(evaluateVirtualArgument(argument, parameters));
          }
        } on SqlException {
          // A column or other non-constant is evaluated once per outer row.
          return virtualCatalogTable(module, source!.table ?? name,
              argumentExprs: arguments);
        }
      } else {
        for (final argument in arguments) {
          values.add(evaluateVirtualArgument(argument, parameters));
        }
      }
      return virtualCatalogTable(module, source!.table ?? name,
          positionals: values);
    }
    if (!physical) {
      final module = VirtualTableRegistry.current?.find(name);
      if (module != null && module.eponymous) {
        return virtualCatalogTable(module, name);
      }
    }
    return catalog.table(name);
  }

  /// True when a packed FTS lookup must also read stored column text.
  bool _ftsQueryReadsText(SelectStatement statement, CatalogTable table) {
    if (table.virtualModule != 'fts5') return true;
    final hidden = {
      asciiLower(table.name),
      'rank',
      'rowid',
      'oid',
      '_rowid_',
    };
    bool walk(Expr expr) {
      if (expr is FunctionExpr &&
          (expr.key == 'highlight' || expr.key == 'snippet')) {
        return true;
      }
      if (expr is ColumnExpr) {
        final name = asciiLower(expr.name.split('.').last);
        if (!hidden.contains(name)) return true;
      }
      return expr.children.any(walk);
    }

    for (final item in statement.items) {
      if (item.expression == null || walk(item.expression!)) return true;
    }
    for (final order in statement.order) {
      if (walk(order.expression)) return true;
    }
    for (final group in statement.groupBy) {
      if (walk(group)) return true;
    }
    final having = statement.having;
    return having != null && walk(having);
  }

  Stream<BtreeRecord> _planRecords(CatalogTable table, QueryPlan plan,
      {Expr? where,
      List<Object?> parameters = const [],
      bool allowUnqualified = false,
      String? alias,
      bool ftsText = true}) async* {
    if (plan.access == 'virtual-table-scan') {
      final directed = await directedFts5Snapshot(
          _pager, catalog, table, where, parameters,
          requireText: ftsText);
      final snapshot =
          directed ?? await readSearchShadows(_pager, catalog, table);
      yield* Stream<BtreeRecord>.fromIterable(runZoned(
          () => VirtualTableRows.records(table,
              where: where,
              parameters: parameters,
              allowUnqualified: allowUnqualified,
              alias: alias),
          zoneValues: {
            searchSnapshotKey: snapshot,
            if (directed != null) ftsDirectedSnapshotKey: true,
          }));
      return;
    }
    final reader = BtreeReader(_pager);
    if (plan.access == 'rowid-lookup') {
      final record = await reader.findRowid(table.rootPage, plan.rowid!);
      if (record != null) yield record;
      return;
    }
    final access = plan._index;
    if (access == null) {
      yield* table.withoutRowid
          ? reader.scanIndex(table.rootPage, reverse: plan.scanReverse)
          : reader.scanTable(table.rootPage, reverse: plan.scanReverse);
      return;
    }
    if (access.empty) return;
    if (access.table) {
      yield* reader.seekTable(
          plan.rootPage!, (rowid) => access.compare([rowid]));
      return;
    }
    if (!table.withoutRowid && plan.covering) {
      final stored = table.storageColumns;
      await for (final entry in _indexMatches(reader, plan, access)) {
        final rowid = entry.values.last;
        if (rowid is! BigInt) {
          throw const FormatException('Secondary index rowid missing');
        }
        final values = List<Object?>.filled(stored.length, null);
        for (var i = 0;
            i < plan.coveredColumns.length && i < entry.values.length - 1;
            i++) {
          final position = stored.indexWhere(
              (column) => asciiLower(column.name) == plan.coveredColumns[i]);
          if (position >= 0) values[position] = entry.values[i];
        }
        yield BtreeRecord.synthetic(rowid, values);
      }
      return;
    }
    if (!table.withoutRowid) {
      await for (final entry in _indexMatches(reader, plan, access)) {
        final rowid = entry.values.last;
        if (rowid is! BigInt) {
          throw const FormatException('Secondary index rowid missing');
        }
        final record = await reader.findRowid(table.rootPage, rowid);
        if (record == null) {
          throw const FormatException(
              'Secondary index references missing rowid');
        }
        yield record;
      }
      return;
    }
    if (plan.rootPage == table.rootPage) {
      yield* reader.scanIndex(table.rootPage, reverse: plan.scanReverse);
      return;
    }
    final entry = catalog.entries.firstWhere((entry) =>
        entry.type == 'index' &&
        asciiLower(entry.name) == asciiLower(access.name));
    final definition = _indexDefinition(entry);
    final primary = table.columns.where((c) => c.primaryKey != 0).toList()
      ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
    var suffix = definition.$1.length;
    final positions = <int>[];
    for (final column in primary) {
      final position = List.generate(definition.$1.length, (i) => i)
          .where((i) =>
              asciiLower(definition.$1[i]) == asciiLower(column.name) &&
              definition.$3[i] ==
                  table.primaryKeyCollations[column.primaryKey - 1])
          .firstOrNull;
      positions.add(position ?? suffix++);
    }
    final records = await reader.scanIndex(table.rootPage).toList();
    await for (final indexed in _indexMatches(reader, plan, access)) {
      if (positions.any((position) => position >= indexed.values.length)) {
        throw const FormatException('Secondary index primary key missing');
      }
      BtreeRecord? found;
      for (final record in records) {
        var matches = true;
        for (var i = 0; i < primary.length; i++) {
          final stored = table.storageColumns.indexOf(primary[i]);
          if (stored >= record.values.length ||
              compareValues(
                      record.values[stored],
                      indexed.values[positions[i]],
                      _pager.header.textEncoding,
                      table.primaryKeyCollations[i]) !=
                  0) {
            matches = false;
            break;
          }
        }
        if (matches) {
          found = record;
          break;
        }
      }
      if (found == null) {
        throw const FormatException(
            'Secondary index references missing primary key');
      }
      yield found;
    }
  }

  /// Pages fetched from storage since this database was opened.
  int get pagesRead => _pager.pagesRead;

  /// Detail text for one statement. Callers that need the compared cost use
  /// [explainQueryPlan].
  List<String> describeQueryPlan(String sql) =>
      functions.run(() => _describeQueryPlan(sql));

  /// `EXPLAIN QUERY PLAN` rows for one statement.
  ///
  /// Costs use the SQLite 3.53.1 no-stat formulas for the single-table plans
  /// compared against the pinned CLI. A multi-table row keeps this engine's
  /// join order. Its address and cost were not compared.
  List<ExplainPlanRow> explainQueryPlan(String sql) =>
      functions.run(() => _explainQueryPlan(sql));

  /// Access path for one statement. [parameters] are bound values.
  QueryPlan explain(String sql, [List<Object?> parameters = const []]) =>
      functions.run(() => _explain(sql, parameters));
  List<String> _describeQueryPlan(String sql) =>
      [for (final row in _explainQueryPlan(sql)) row.detail];

  /// Leading index column for an `INNER JOIN` whose `ON` equality can seek it.
  ///
  /// The equality has to sit in the `AND` spine. An `OR`, a partial index, or
  /// an expression index stays a scan.
  ({String index, String column, Expr equality, String leftKey})?
      _innerJoinIndex(QuerySource source, [List<QuerySource>? sources]) {
    if (source.join != 'INNER' ||
        source.on == null ||
        source.notIndexed ||
        source.table == null) {
      return null;
    }
    final alias = asciiLower(source.alias ?? source.table!);
    final found = _innerIndexedColumn(source.on!, alias);
    if (found == null) return null;
    final CatalogTable table;
    try {
      table = catalog.table(source.table!);
    } on SqlException {
      return null;
    }
    for (final entry in catalog.entries) {
      if (entry.type != 'index' ||
          asciiLower(entry.tableName) != asciiLower(table.name) ||
          entry.sql == null) {
        continue;
      }
      IndexDefinition parsed;
      try {
        parsed = IndexDefinition.parse(entry.sql!, table);
      } on Exception {
        continue;
      }
      final term = parsed.terms.firstOrNull;
      if (parsed.predicate != null ||
          term == null ||
          term.columnName == null ||
          asciiLower(term.columnName!) != found.column) {
        continue;
      }
      if (sources != null) {
        final rightColumn = _joinColumn(sources, '$alias.${found.column}');
        final leftColumn = _joinColumn(sources, found.leftKey);
        if (rightColumn == null ||
            leftColumn == null ||
            rightColumn.affinity != leftColumn.affinity ||
            rightColumn.collation != leftColumn.collation) {
          continue;
        }
      }
      final entries = _statistics.indexEntries(table.name, entry.name);
      if (entries != null && entries > _maxJoinLookupKeys) continue;
      return (
        index: entry.name,
        column: found.column,
        equality: found.equality,
        leftKey: found.leftKey
      );
    }
    return null;
  }

  CatalogColumn? _joinColumn(List<QuerySource> sources, String key) {
    final dot = key.indexOf('.');
    if (dot <= 0) return null;
    final alias = key.substring(0, dot);
    final name = key.substring(dot + 1);
    for (final source in sources) {
      if (asciiLower(source.alias ?? source.table ?? '') != alias ||
          source.table == null) {
        continue;
      }
      try {
        for (final column in catalog.table(source.table!).columns) {
          if (asciiLower(column.name) == name) return column;
        }
      } on SqlException {
        return null;
      }
    }
    return null;
  }

  ({String column, Expr equality, String leftKey})? _innerIndexedColumn(
      Expr expression, String alias) {
    if (expression is BinaryExpr && expression.op == 'AND') {
      return _innerIndexedColumn(expression.left, alias) ??
          _innerIndexedColumn(expression.right, alias);
    }
    if (expression is! BinaryExpr ||
        (expression.op != '=' && expression.op != '==') ||
        expression.left is! ColumnExpr ||
        expression.right is! ColumnExpr) {
      return null;
    }
    final left = expression.left as ColumnExpr;
    final right = expression.right as ColumnExpr;
    final leftHere =
        left.qualifier != null && asciiLower(left.qualifier!) == alias;
    final rightHere =
        right.qualifier != null && asciiLower(right.qualifier!) == alias;
    if (leftHere == rightHere) return null;
    final indexed = leftHere ? left : right;
    final other = leftHere ? right : left;
    if (other.qualifier == null) return null;
    final qualifier = indexed.qualifier!;
    final column = asciiLower(indexed.name.substring(qualifier.length + 1));
    final otherColumn =
        asciiLower(other.name.substring(other.qualifier!.length + 1));
    return (
      column: column,
      equality: expression,
      leftKey: '${asciiLower(other.qualifier!)}.$otherColumn'
    );
  }

  List<ExplainPlanRow> _explainQueryPlan(String sql) {
    final statement = SqlParser(sql).select();
    final sources = _orderedJoinSources(statement);
    if (sources.length > 1) {
      return [
        for (final source in sources)
          () {
            final indexed = _innerJoinIndex(source, sources);
            final label = source.alias ?? source.table ?? '';
            return ExplainPlanRow(
                2,
                0,
                _defaultRowLogEst + 16,
                indexed == null
                    ? 'SCAN $label'
                    : 'SEARCH $label USING INDEX ${indexed.index} (${indexed.column}=?)');
          }()
      ];
    }
    if (sources.isEmpty || sources.single.table == null) {
      return const [ExplainPlanRow(1, 0, 0, 'SCAN CONSTANT ROW')];
    }
    final source = sources.single;
    final table = _planTable(source.table!);
    final name = source.alias ?? source.table!;
    final plan = _plan(statement, table, const []);
    final covering = _explainCovering(statement, table, plan);
    return [
      ExplainPlanRow(
          _planAddress(plan, covering),
          0,
          _planCost(statement, table, plan, covering),
          _planDetail(statement, table, plan, name, covering))
    ];
  }

  /// `SELECT *` is covering when every stored column is the rowid or an index
  /// column. The read path still uses [QueryPlan.covering].
  bool _explainCovering(
      SelectStatement statement, CatalogTable table, QueryPlan plan) {
    if (plan.covering || plan.indexName == null) return plan.covering;
    final star = statement.items.length == 1 &&
        statement.items.single.expression == null &&
        statement.items.single.label == '*';
    if (!star || table.rowidAlias == null) return false;
    final entry = catalog.entries
        .where((item) =>
            item.type == 'index' &&
            asciiLower(item.name) == asciiLower(plan.indexName!))
        .firstOrNull;
    if (entry == null) return false;
    final available = _indexDefinition(entry).$1.map(asciiLower).toSet();
    for (final column in table.columns) {
      if (column.generatedExpression != null) return false;
      final key = asciiLower(column.name);
      if (key == asciiLower(table.rowidAlias!)) continue;
      if (!available.contains(key)) return false;
    }
    return true;
  }

  CatalogTable _planTable(String name) {
    try {
      return catalog.table(name);
    } on SqlException catch (error) {
      if (error.errorCode == SqlErrorCode.missingTable) {
        throw SqlException(
            'no such table: $name', error.offset, SqlErrorCode.missingTable);
      }
      rethrow;
    }
  }

  int _planAddress(QueryPlan plan, bool covering) {
    if (plan.access == 'constant' || plan.access == 'virtual-table-scan') {
      return plan.access == 'constant' ? 1 : 2;
    }
    final opensTable = plan.access.startsWith('secondary-index') &&
        !covering &&
        plan.access != 'secondary-index-scan';
    return opensTable ? 3 : 2;
  }

  int _planCost(SelectStatement statement, CatalogTable table, QueryPlan plan,
      bool covering) {
    switch (plan.access) {
      case 'rowid-lookup':
        return 33;
      case 'rowid-range':
        final bounds = _rowidBounds(statement, table);
        return _rowidRangeCost(bounds.$1, bounds.$2);
      case 'table-scan':
      case 'index-tree-scan':
      case 'virtual-table-scan':
        return _defaultRowLogEst + 16;
      case 'secondary-index-lookup':
      case 'secondary-index-range':
      case 'secondary-index-scan':
        return _secondaryCost(statement, table, plan, covering);
      default:
        return _defaultRowLogEst + 16;
    }
  }

  int _secondaryCost(SelectStatement statement, CatalogTable table,
      QueryPlan plan, bool covering) {
    final entry = catalog.entries
        .where((item) =>
            item.type == 'index' &&
            asciiLower(item.name) == asciiLower(plan.indexName ?? ''))
        .firstOrNull;
    if (entry == null) return _defaultRowLogEst + 16;
    final definition = _indexDefinition(entry);
    final bounds = _indexBounds(statement, definition.$1);
    final estimates = <int>[_defaultRowLogEst];
    const selectivity = [33, 32, 30, 28, 26];
    for (var i = 0; i < definition.$1.length; i++) {
      estimates.add(i < selectivity.length ? selectivity[i] : 23);
    }
    if (definition.$5) estimates[definition.$1.length] = 0;
    var visited = estimates[0];
    for (var equal = 1; equal <= bounds.$1; equal++) {
      visited += estimates[equal] - estimates[equal - 1];
    }
    if (bounds.$2 || bounds.$3) {
      var narrowed = visited;
      if (bounds.$2) narrowed -= 20;
      if (bounds.$3) narrowed -= 20;
      if (bounds.$2 && bounds.$3) narrowed -= 20;
      var adjusted = visited - (bounds.$2 ? 1 : 0) - (bounds.$3 ? 1 : 0);
      if (narrowed < 10) narrowed = 10;
      if (narrowed < adjusted) adjusted = narrowed;
      visited = adjusted;
    }
    final indexWidth = _indexWidth(table, definition.$1);
    final tableWidth = _tableWidth(table);
    var cost = visited + 1 + (15 * indexWidth) ~/ tableWidth;
    cost = _sqliteLogEstAdd(_estLog(estimates[0]), cost);
    if (!covering && plan.access != 'secondary-index-scan') {
      cost = _sqliteLogEstAdd(cost, visited + 16);
    }
    return cost;
  }

  String _planDetail(SelectStatement statement, CatalogTable table,
      QueryPlan plan, String name, bool explainCovering) {
    switch (plan.access) {
      case 'rowid-lookup':
        return 'SEARCH $name USING INTEGER PRIMARY KEY (rowid=?)';
      case 'rowid-range':
        final bounds = _rowidBounds(statement, table);
        final parts = <String>[
          if (bounds.$1) 'rowid>?',
          if (bounds.$2) 'rowid<?',
        ];
        return 'SEARCH $name USING INTEGER PRIMARY KEY (${parts.join(' AND ')})';
      case 'table-scan':
      case 'index-tree-scan':
        return 'SCAN $name';
      case 'virtual-table-scan':
        return 'SCAN $name';
      case 'secondary-index-lookup':
      case 'secondary-index-range':
      case 'secondary-index-scan':
        final entry = catalog.entries
            .where((item) =>
                item.type == 'index' &&
                asciiLower(item.name) == asciiLower(plan.indexName ?? ''))
            .firstOrNull;
        final index = plan.indexName ?? '';
        final covering = explainCovering ? 'COVERING ' : '';
        final search =
            plan.access == 'secondary-index-scan' ? 'SCAN' : 'SEARCH';
        if (entry == null) {
          return '$search $name USING ${covering}INDEX $index';
        }
        final definition = _indexDefinition(entry);
        final bounds = _indexBounds(statement, definition.$1);
        final parts = <String>[];
        for (var i = 0; i < bounds.$1 && i < definition.$1.length; i++) {
          parts.add('${_declaredColumn(table, definition.$1[i])}=?');
        }
        if (bounds.$1 < definition.$1.length && (bounds.$2 || bounds.$3)) {
          final column = _declaredColumn(table, definition.$1[bounds.$1]);
          if (bounds.$2) parts.add('$column>?');
          if (bounds.$3) parts.add('$column<?');
        }
        final constraint = parts.isEmpty ? '' : ' (${parts.join(' AND ')})';
        return '$search $name USING ${covering}INDEX $index$constraint';
      default:
        return 'SCAN $name';
    }
  }

  (bool, bool) _rowidBounds(SelectStatement statement, CatalogTable table) {
    final names = <String>{
      if (table.rowidAlias != null) asciiLower(table.rowidAlias!),
      for (final alias in const ['rowid', '_rowid_', 'oid'])
        if (!table.columns.any((column) => asciiLower(column.name) == alias))
          alias,
    };
    var lower = false;
    var upper = false;
    for (final name in names) {
      for (final op in _comparisonOps(statement.where, name)) {
        if (op == '>' || op == '>=') lower = true;
        if (op == '<' || op == '<=') upper = true;
      }
    }
    return (lower, upper);
  }

  (int, bool, bool) _indexBounds(
      SelectStatement statement, List<String> columns) {
    var equalities = 0;
    for (final column in columns) {
      final ops = _comparisonOps(statement.where, column);
      if (ops.any((op) => op == '=' || op == '==')) {
        equalities++;
        continue;
      }
      return (
        equalities,
        ops.any((op) => op == '>' || op == '>='),
        ops.any((op) => op == '<' || op == '<='),
      );
    }
    return (equalities, false, false);
  }

  List<String> _comparisonOps(Expr? where, String column) {
    final key = asciiLower(column);
    final ops = <String>[];
    void visit(Expr? expr) {
      if (expr is BinaryExpr && expr.op == 'AND') {
        visit(expr.left);
        visit(expr.right);
        return;
      }
      if (expr is! BinaryExpr ||
          !const {'=', '==', '<', '<=', '>', '>='}.contains(expr.op)) {
        return;
      }
      Expr? other;
      var op = expr.op;
      if (expr.left is ColumnExpr && (expr.left as ColumnExpr).key == key) {
        other = expr.right;
      } else if (expr.right is ColumnExpr &&
          (expr.right as ColumnExpr).key == key) {
        other = expr.left;
        op = const {
          '<': '>',
          '<=': '>=',
          '>': '<',
          '>=': '<=',
          '=': '=',
          '==': '=='
        }[op]!;
      } else {
        return;
      }
      if (!_planningConstant(other)) return;
      ops.add(op);
    }

    visit(where);
    return ops;
  }

  String _declaredColumn(CatalogTable table, String name) {
    for (final column in table.columns) {
      if (asciiLower(column.name) == asciiLower(name)) return column.name;
    }
    return name;
  }

  int _columnSzEst(CatalogColumn column) {
    final type = column.declaredType.trim();
    if (type.isEmpty) return 1;
    final open = type.indexOf('(');
    if (open >= 0) {
      final digits = RegExp(r'\d+').firstMatch(type.substring(open));
      if (digits != null) {
        final scaled = int.parse(digits.group(0)!) ~/ 4 + 1;
        return scaled > 255 ? 255 : scaled;
      }
    }
    final affinity = column.affinity;
    if (affinity == 'text' || affinity == 'blob') return 5;
    return 1;
  }

  int _tableWidth(CatalogTable table) {
    var width = 0;
    for (final column in table.columns) {
      width += _columnSzEst(column);
    }
    if (table.rowidAlias == null && !table.withoutRowid) width++;
    if (width < 1) width = 1;
    return _sqliteLogEst(width * 4);
  }

  int _indexWidth(CatalogTable table, List<String> columns) {
    var width = 0;
    for (final name in columns) {
      CatalogColumn? column;
      for (final candidate in table.columns) {
        if (asciiLower(candidate.name) == asciiLower(name)) {
          column = candidate;
          break;
        }
      }
      width += column == null ? 1 : _columnSzEst(column);
    }
    if (!table.withoutRowid) width++;
    if (width < 1) width = 1;
    return _sqliteLogEst(width * 4);
  }

  int _rowidRangeCost(bool lower, bool upper) {
    var visited = _defaultRowLogEst;
    var narrowed = visited;
    if (lower) narrowed -= 20;
    if (upper) narrowed -= 20;
    if (lower && upper) narrowed -= 20;
    visited -= (lower ? 1 : 0) + (upper ? 1 : 0);
    if (narrowed < 10) narrowed = 10;
    if (narrowed < visited) visited = narrowed;
    return _sqliteLogEstAdd(_estLog(_defaultRowLogEst), visited + 16);
  }

  QueryPlan _explain(String sql, List<Object?> parameters) {
    if (_closed) throw StateError('Database is closed');
    final statement = SqlParser(sql).select();
    if (parameters.length != statement.parameterCount) {
      throw const SqlException('Incorrect parameter count');
    }
    return _plan(
        statement,
        statement.table == null ? null : catalog.table(statement.table!),
        parameters.map(sqlValue).toList());
  }

  /// Validate reusable ordinary SELECT syntax without scanning rows or binding
  /// user values. Physical access planning remains binding-aware at execution.
  void validatePreparation(SqlPreparation preparation) => functions.run(() {
        final statement = preparation.selectSyntax();
        if (!preparation.reusableSelect || _needsRelational(statement)) {
          throw UnsupportedError(
              'Prepared SELECT currently requires a simple ordinary-table query');
        }
        final table =
            statement.table == null ? null : catalog.table(statement.table!);
        if (table != null &&
            (table.virtual ||
                table.columns.any((c) => c.generatedExpression != null))) {
          throw UnsupportedError(
              'Prepared SELECT does not support virtual/generated sources');
        }
        final metadata = SelectStatement(
            statement.items,
            statement.table,
            statement.where,
            statement.order,
            Literal(BigInt.zero),
            null,
            statement.distinct,
            statement.parameterCount)
          ..sources.addAll(statement.sources);
        _evaluate(metadata, List.filled(statement.parameterCount, null), table,
            const <RowValues>[]);
      });

  /// Execute retained safe syntax with fresh bindings, rows and access planning.
  Future<QueryResult> queryPreparation(
          SqlPreparation preparation, List<Object?> parameters) =>
      functions.run(() async {
        final statement = preparation.selectSyntax();
        if (!preparation.reusableSelect || _needsRelational(statement)) {
          throw UnsupportedError(
              'Prepared SELECT requires simple ordinary sources');
        }
        final table =
            statement.table == null ? null : catalog.table(statement.table!);
        if (table != null &&
            (table.virtual ||
                table.columns.any((c) => c.generatedExpression != null))) {
          throw UnsupportedError(
              'Prepared SELECT requires ordinary non-generated sources');
        }
        return (await _prepareQuery(
                preparation.sql, parameters, null, statement))
            .materialize();
      });

  /// Runs one read statement. [parameters] bind `?`, `?NNN`, and named placeholders.
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      functions.run(() => _query(sql, parameters));

  /// Runs one read statement inside an existing evaluation context.
  Future<QueryResult> queryWithContext(
          String sql, List<Object?> parameters, EvalContext context) =>
      functions.run(() => _query(sql, parameters, context));
  Future<QueryResult> _query(String sql, List<Object?> parameters,
      [EvalContext? outer]) async {
    if (_closed) throw StateError('Database is closed');
    final pragmaParser = SqlParser(sql);
    if (pragmaParser.take('PRAGMA')) {
      if (parameters.isNotEmpty) {
        throw const SqlException('PRAGMA does not accept bindings');
      }
      return _pragma(pragmaParser);
    }
    return (await _prepareQuery(sql, parameters, outer)).materialize();
  }

  /// One window of a single-table read. [query] still materializes its input.
  ///
  /// A `LIMIT`/`OFFSET` table or WITHOUT ROWID scan stops after the window.
  /// Anything else uses [query]. Stored records may be as large as SQLite's
  /// default `SQLITE_MAX_LENGTH` (1000000000 bytes). The size is rejected
  /// before that buffer is allocated.
  Future<QueryResult> browse(String sql,
          [List<Object?> parameters = const []]) =>
      functions.run(() => _browse(sql, parameters));

  Future<QueryResult> _browse(String sql, List<Object?> parameters,
      [EvalContext? outer]) async {
    final paged = await _pageQuery(sql, parameters, outer);
    if (paged != null) return paged;
    return _query(sql, parameters, outer);
  }

  Future<QueryResult?> _pageQuery(String sql, List<Object?> parameters,
      [EvalContext? outer]) async {
    if (_closed || outer != null) return null;
    final pragmaParser = SqlParser(sql);
    if (pragmaParser.take('PRAGMA') || SqlParser(sql).take('EXPLAIN')) {
      return null;
    }
    final statement = SqlParser(sql).select();
    if (parameters.length != statement.parameterCount) {
      throw const SqlException('Incorrect parameter count');
    }
    if (!_singleTablePage(statement, allowRowidLowerBound: true)) return null;
    final bound = parameters.map(sqlValue).toList();
    final limit = _sqlCount(statement.limit, bound);
    final offset =
        statement.offset == null ? 0 : _sqlCount(statement.offset, bound);
    if (limit == null || offset == null || limit < 0 || offset < 0) {
      return null;
    }
    if (limit > 0x3fffffff || offset > 0x3fffffff) return null;
    final table =
        _resolveTable(statement.table!, statement.sources.single, bound);
    final entry = catalog.entries
        .where((entry) =>
            entry.type == 'table' &&
            asciiLower(entry.name) == asciiLower(table.name))
        .firstOrNull;
    if (entry == null) return null;
    final lower = statement.where == null
        ? null
        : _rowidLowerBound(statement.where!, table, bound);
    if (statement.where != null && lower == null) return null;
    final plan = _plan(statement, table, bound);
    final ranged = lower != null;
    if (plan.rootPage == null ||
        (ranged
            ? plan.access != 'rowid-range'
            : plan.access != 'table-scan' &&
                plan.access != 'index-tree-scan')) {
      return null;
    }
    if (statement.order.isNotEmpty && !plan.scanSatisfiesOrder) return null;
    if (limit == 0) {
      return _evaluate(statement, bound, table, <RowValues>[]).materialize();
    }
    final need = offset + limit;
    final reader = BtreeReader(_pager, maxPayloadBytes: 1000000000);
    final input = <RowValues>[];
    final stored = table.storageColumns;
    final columns = table.columns;
    void addRecord(BtreeRecord record) {
      if (record.values.length > stored.length) {
        throw const FormatException('More stored columns than catalog columns');
      }
      final row = <String, Object?>{};
      for (var i = 0; i < stored.length; i++) {
        final column = stored[i];
        row[asciiLower(column.name)] = table.rowidAlias == column.name
            ? record.rowId
            : i < record.values.length
                ? record.values[i]
                : column.defaultValue;
      }
      row.updateAll(
          (name, value) => value is double && value.isNaN ? null : value);
      for (final column in columns) {
        final type = column.declaredType.toUpperCase();
        final key = asciiLower(column.name);
        if (!type.contains('INT') &&
            ['REAL', 'FLOA', 'DOUB'].any(type.contains) &&
            row[key] is BigInt) {
          row[key] = (row[key] as BigInt).toDouble();
        }
      }
      if (!table.withoutRowid) {
        for (final name in ['rowid', '_rowid_', 'oid']) {
          row.putIfAbsent(name, () => record.rowId);
        }
      }
      table.evaluateGenerated(row, _pager.header.textEncoding, lazy: true);
      input.add(row);
    }

    final resume = lower;
    late final Stream<BtreeRecord> stream;
    if (resume == null) {
      stream = plan.access == 'index-tree-scan'
          ? reader.scanIndex(plan.rootPage!, reverse: plan.scanReverse)
          : reader.scanTable(plan.rootPage!, reverse: plan.scanReverse);
    } else {
      final boundRowid = resume.$1;
      final inclusive = resume.$2;
      stream = reader.seekTable(plan.rootPage!, (rowid) {
        final comparison = rowid.compareTo(boundRowid);
        if (inclusive ? comparison < 0 : comparison <= 0) return -1;
        return 0;
      });
    }
    await for (final record in stream) {
      addRecord(record);
      if (input.length >= need) break;
    }
    return _evaluate(statement, bound, table, input).materialize();
  }

  /// `rowid > constant` or `rowid >= constant`, including a rowid alias.
  (BigInt, bool)? _rowidLowerBound(
      Expr where, CatalogTable table, List<Object?> bound) {
    if (where is! BinaryExpr) return null;
    var op = where.op;
    Expr? columnExpr;
    Expr? constant;
    if (where.left is ColumnExpr) {
      columnExpr = where.left;
      constant = where.right;
    } else if (where.right is ColumnExpr) {
      columnExpr = where.right;
      constant = where.left;
      op = const {'<': '>', '<=': '>=', '>': '<', '>=': '<='}[op] ?? op;
    }
    if (columnExpr is! ColumnExpr ||
        constant == null ||
        (op != '>' && op != '>=')) {
      return null;
    }
    final column = columnExpr;
    if (column.qualifier != null) return null;
    final alias = table.rowidAlias;
    final actual =
        table.columns.where((entry) => asciiLower(entry.name) == column.key);
    if (!(alias != null && column.key == asciiLower(alias)) &&
        (!['rowid', '_rowid_', 'oid'].contains(column.key) ||
            actual.isNotEmpty)) {
      return null;
    }
    try {
      constant.validate({});
    } on SqlException {
      return null;
    }
    if (!_planningConstant(constant)) return null;
    var value = applyAffinity(
        constant
            .evaluate(EvalContext({}, {}, bound, _pager.header.textEncoding)),
        'numeric');
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      value = BigInt.from(value);
    }
    if (value is! BigInt ||
        value < -(BigInt.one << 63) ||
        value >= BigInt.one << 63) {
      return null;
    }
    return (value, op == '>=');
  }

  bool _singleTablePage(SelectStatement statement,
      {bool allowRowidLowerBound = false}) {
    final source = statement.sources.singleOrNull;
    return statement.table != null &&
        source != null &&
        source.query == null &&
        source.group.isEmpty &&
        (statement.where == null || allowRowidLowerBound) &&
        !statement.distinct &&
        statement.groupBy.isEmpty &&
        statement.having == null &&
        statement.compounds.isEmpty &&
        statement.ctes.isEmpty &&
        !statement.valuesQuery &&
        statement.windowDefinitions.isEmpty &&
        statement.limit != null &&
        statement.items.every((item) =>
            item.expression?.containsAggregate != true &&
            item.expression?.containsWindow != true) &&
        statement.order.every((term) =>
            !term.expression.containsAggregate &&
            !term.expression.containsWindow);
  }

  int? _sqlCount(Expr? expr, List<Object?> bound) {
    if (expr == null) return null;
    var value =
        expr.evaluate(EvalContext({}, {}, bound, _pager.header.textEncoding));
    if (value is String) value = numeric(value);
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      value = BigInt.from(value);
    }
    if (value is! BigInt || value.bitLength > 63) {
      throw const SqlException('LIMIT/OFFSET datatype mismatch');
    }
    if (value > BigInt.from(0x7fffffff)) return 0x7fffffff;
    if (value < BigInt.from(-0x7fffffff)) return -0x7fffffff;
    return value.toInt();
  }

  /// Resolve physical table reads through view and CTE source scopes.
  bool queryReadsTable(SelectStatement query, String table) =>
      _queryReadsTable(query, table);

  /// Internal mutation cursor; public query results remain materialized.
  Future<({List<String> columns, Iterable<List<Object?>> rows})>
      prepareInsertSelect(String sql, List<Object?> parameters,
              [EvalContext? outer]) =>
          functions.run(() async {
            final execution = await _prepareQuery(sql, parameters, outer);
            return (columns: execution.columns, rows: execution.rows);
          });

  Future<_QueryExecution> _prepareQuery(String sql, List<Object?> parameters,
      [EvalContext? outer,
      SelectStatement? preparedSyntax,
      _SqlDiagnosticTrace? diagnostics]) async {
    if (_closed) throw StateError('Database is closed');
    final statement = preparedSyntax ?? SqlParser(sql).select();
    _foldConstants(statement);
    if (parameters.length != statement.parameterCount) {
      throw const SqlException('Incorrect parameter count');
    }
    final bound = parameters.map(sqlValue).toList();
    if (outer != null || _needsRelational(statement)) {
      final cache = <String, (CatalogTable, List<RowValues>)>{};
      await _loadRelations(statement, cache, <String>{}, const {}, bound);
      prepareSubqueryWidths(statement, {
        for (final entry in cache.entries)
          for (final name in {
            entry.key,
            if (entry.key.startsWith('main.')) entry.key.substring(5)
          })
            name: (
              columns: entry.value.$1.columns
                  .where((c) => !c.hidden)
                  .map((c) => c.name)
                  .toList(),
              rowid: !entry.value.$1.withoutRowid
            )
      });
      if (statement.limit is Literal &&
          (statement.limit as Literal).value == BigInt.zero) {
        return _relationalExecution(
            _pragmaMetadataQuery(statement, canonicalCasts: false),
            bound,
            {
              for (final entry in cache.entries)
                entry.key: (entry.value.$1, <RowValues>[])
            },
            outer);
      }
      return _relationalExecution(statement, bound, cache, outer);
    }
    var table = statement.table == null
        ? null
        : _resolveTable(
            statement.table!, statement.sources.singleOrNull, bound);
    if (table != null && table.virtualArgumentExprs != null) {
      final context = EvalContext({}, {}, bound, _pager.header.textEncoding);
      final values = [
        for (final argument in table.virtualArgumentExprs!)
          argument.evaluate(context)
      ];
      table = CatalogTable(table.name, table.rootPage, table.columns,
          virtualModule: table.virtualModule,
          virtualArguments: table.virtualArguments,
          virtualPositionals: values);
    }
    final columns = table?.columns ?? <CatalogColumn>[];
    final input = <RowValues>[];
    var scanSatisfiesOrder = false;
    var orderedPrefix = 0;
    if (table == null) {
      input.add({});
      if (diagnostics != null) {
        diagnostics.record('constant', 'constant-source',
            estimate: 1, chosen: true);
        diagnostics.plan =
            SqlDiagnosticPlan._(const QueryPlan('constant', null, null));
      }
    } else {
      diagnostics?.planningClock.start();
      final plan = _plan(statement, table, bound, diagnostics);
      scanSatisfiesOrder = plan.scanSatisfiesOrder;
      orderedPrefix = plan.orderedPrefix;
      diagnostics?.planningClock.stop();
      final prefixLimit =
          _orderedPrefixLimit(statement, bound, scanSatisfiesOrder);
      final unorderedLimit =
          plan.access == 'table-scan' || plan.access == 'index-tree-scan'
              ? _unorderedScanLimit(statement, bound)
              : null;
      if (diagnostics != null) diagnostics.plan = SqlDiagnosticPlan._(plan);
      final primaryExtreme = _primaryKeyExtreme(statement, table);
      if (primaryExtreme != null) {
        diagnostics?.record(
            'primary-key-extreme', primaryExtreme ? 'max' : 'min',
            chosen: true);
      }
      if (_whereIsFalse(statement.where)) {
        // A proved false filter yields no rows. Aggregates still run on
        // the empty input below, so count(*) stays 0.
      } else {
        final stream = primaryExtreme == null
            ? _planRecords(table, plan,
                where: statement.where,
                parameters: bound,
                allowUnqualified: true,
                alias: statement.sources.singleOrNull?.alias,
                ftsText: _ftsQueryReadsText(statement, table))
            : BtreeReader(_pager)
                .scanTable(table.rootPage, reverse: primaryExtreme);
        final stored = table.storageColumns;
        await for (final record in stream) {
          if (prefixLimit == 0 || unorderedLimit == 0) break;
          if (record.values.length > stored.length) {
            throw const FormatException(
                'More stored columns than catalog columns');
          }
          final row = <String, Object?>{};
          for (var i = 0; i < stored.length; i++) {
            final column = stored[i];
            row[asciiLower(column.name)] = table.rowidAlias == column.name
                ? record.rowId
                : i < record.values.length
                    ? record.values[i]
                    : column.defaultValue;
          }
          row.updateAll(
              (name, value) => value is double && value.isNaN ? null : value);
          for (final column in columns) {
            final type = column.declaredType.toUpperCase();
            final key = asciiLower(column.name);
            if (!type.contains('INT') &&
                ['REAL', 'FLOA', 'DOUB'].any(type.contains) &&
                row[key] is BigInt) {
              row[key] = (row[key] as BigInt).toDouble();
            }
          }
          if (!table.withoutRowid) {
            for (final name in ['rowid', '_rowid_', 'oid']) {
              row.putIfAbsent(name, () => record.rowId);
            }
          }
          table.evaluateGenerated(row, _pager.header.textEncoding, lazy: true);
          input.add(row);
          if (primaryExtreme != null ||
              prefixLimit != null && input.length >= prefixLimit ||
              unorderedLimit != null && input.length >= unorderedLimit) {
            break;
          }
        }
      }
    }
    diagnostics?.loaded = input.length;
    if (!scanSatisfiesOrder && orderedPrefix > 0 && table != null) {
      _blockSortRows(input, statement, table, orderedPrefix);
      scanSatisfiesOrder = true;
    }
    final scanOrder = scanSatisfiesOrder || table == null
        ? null
        : _physicalScanOrder(statement, table);
    if (scanOrder != null) _sortPhysicalRows(input, scanOrder);
    return _evaluate(statement, bound, table, input,
        inputOrdered: scanSatisfiesOrder || scanOrder != null,
        diagnostics: diagnostics);
  }

  /// Replace an expression that has no column, parameter, or function with its
  /// value. A function stays in place so its side effect still runs.
  void _foldConstants(SelectStatement statement) {
    final seen = <SelectStatement>{};
    void fold(SelectStatement query) {
      if (!seen.add(query)) return;
      final encoding = _pager.header.textEncoding;
      for (var i = 0; i < query.items.length; i++) {
        final item = query.items[i];
        final expression = item.expression;
        if (expression == null) continue;
        final folded = _foldedLiteral(expression, encoding);
        if (folded == null) continue;
        query.items[i] = SelectItem(folded, item.label,
            explicitAlias: item.explicitAlias,
            qualifierOffset: item.qualifierOffset);
      }
      final where = _foldedLiteral(query.where, encoding);
      if (where != null) query.where = where;
      final having = _foldedLiteral(query.having, encoding);
      if (having != null) query.having = having;
      for (final source in query.sources) {
        if (source.query != null) fold(source.query!);
      }
      for (final part in query.compounds) {
        fold(part.$2);
      }
      for (final cte in query.ctes.values) {
        fold(cte.$2);
      }
      for (final expr in _expressions(query)) {
        for (final nested in _nested(expr)) {
          fold(nested);
        }
      }
    }

    fold(statement);
  }

  Literal? _foldedLiteral(Expr? expression, int encoding) {
    if (expression == null ||
        expression is Literal ||
        _constantImpure(expression)) {
      return null;
    }
    try {
      return Literal(expression
          .evaluate(EvalContext(const {}, const {}, const [], encoding)));
    } on SqlException {
      return null;
    }
  }

  bool _constantImpure(Expr expression) =>
      expression is FunctionExpr ||
      expression is ColumnExpr ||
      expression is ParameterExpr ||
      expression is SubqueryExpr ||
      expression is InSelectExpr ||
      expression.containsAggregate ||
      expression.containsWindow ||
      expression.children.any(_constantImpure);

  /// True when [where] cannot match a row and has no function or parameter.
  bool _whereIsFalse(Expr? where) {
    if (where == null || _whereHasCall(where)) return false;
    return _provesFalse(where);
  }

  bool _whereHasCall(Expr expression) =>
      expression is FunctionExpr ||
      expression is ParameterExpr ||
      expression is SubqueryExpr ||
      expression is InSelectExpr ||
      expression.containsAggregate ||
      expression.containsWindow ||
      expression.children.any(_whereHasCall);

  bool _provesFalse(Expr expression) {
    if (expression is Literal) {
      return truth(expression.value, _pager.header.textEncoding) == false;
    }
    if (expression is BinaryExpr && expression.op == 'OR') {
      return _provesFalse(expression.left) && _provesFalse(expression.right);
    }
    final bounds = <String, _ColumnBound>{};
    if (!_andBounds(expression, bounds)) return false;
    return bounds.values.any((bound) => bound.empty);
  }

  bool _andBounds(Expr expression, Map<String, _ColumnBound> bounds) {
    if (expression is BinaryExpr && expression.op == 'AND') {
      return _andBounds(expression.left, bounds) &&
          _andBounds(expression.right, bounds);
    }
    if (expression is Literal) {
      if (truth(expression.value, _pager.header.textEncoding) == false) {
        bounds[''] = (_ColumnBound()..empty = true);
      }
      return true;
    }
    final comparison = _simpleComparison(expression);
    if (comparison == null) return false;
    final bound = bounds.putIfAbsent(comparison.$1, _ColumnBound.new);
    return bound.tighten(
        comparison.$2, comparison.$3, _pager.header.textEncoding);
  }

  (String, String, Object?)? _simpleComparison(Expr expression) {
    if (expression is! BinaryExpr) return null;
    const ops = {'>', '>=', '<', '<=', '=', '=='};
    if (!ops.contains(expression.op)) return null;
    final left = expression.left;
    final right = expression.right;
    if (left is CollateExpr || right is CollateExpr) return null;
    ColumnExpr? column;
    Literal? literal;
    var op = expression.op;
    if (left is ColumnExpr && right is Literal) {
      column = left;
      literal = right;
    } else if (right is ColumnExpr && left is Literal) {
      column = right;
      literal = left;
      op = switch (op) {
        '>' => '<',
        '>=' => '<=',
        '<' => '>',
        '<=' => '>=',
        _ => op,
      };
    } else {
      return null;
    }
    if (literal.value == null) return null;
    final name = column.qualifier == null
        ? column.name
        : column.name.substring(column.qualifier!.length + 1);
    return (asciiLower(name), op, literal.value);
  }

  /// True when [statement] is `MAX` of the integer primary key, false for `MIN`.
  ///
  /// Null keeps the ordinary scan. A `WHERE`, another selected expression, or
  /// a non-key column still reads every row. `COUNT` is not answered from
  /// statistics.
  bool? _primaryKeyExtreme(SelectStatement statement, CatalogTable table) {
    if (table.withoutRowid ||
        statement.where != null ||
        statement.distinct ||
        statement.groupBy.isNotEmpty ||
        statement.having != null ||
        statement.order.isNotEmpty ||
        statement.compounds.isNotEmpty ||
        statement.ctes.isNotEmpty ||
        statement.limit != null ||
        statement.offset != null ||
        statement.sources.length != 1 ||
        statement.items.length != 1) {
      return null;
    }
    final expression = statement.items.single.expression;
    if (expression is! FunctionExpr ||
        expression.distinct ||
        expression.star ||
        expression.filter != null ||
        expression.arguments.length != 1) {
      return null;
    }
    if (expression.key != 'min' && expression.key != 'max') return null;
    final argument = expression.arguments.single;
    if (argument is! ColumnExpr || argument.qualifier != null) return null;
    final name = asciiLower(argument.name);
    final alias =
        table.rowidAlias == null ? null : asciiLower(table.rowidAlias!);
    if (name != alias && !const {'rowid', 'oid', '_rowid_'}.contains(name)) {
      return null;
    }
    return expression.key == 'max';
  }

  /// Rows to read before [statement]'s `LIMIT`/`OFFSET` when [ordered] is true.
  ///
  /// A later `WHERE`, aggregate, window, or compound can reject a scanned row,
  /// so those statements still read the whole input. A null return means no
  /// early stop.
  int? _orderedPrefixLimit(
      SelectStatement statement, List<Object?> bound, bool ordered) {
    if (!ordered ||
        statement.where != null ||
        statement.distinct ||
        statement.groupBy.isNotEmpty ||
        statement.having != null ||
        statement.compounds.isNotEmpty ||
        statement.ctes.isNotEmpty ||
        statement.valuesQuery ||
        statement.limit == null ||
        statement.items.any((item) =>
            item.expression?.containsAggregate == true ||
            item.expression?.containsWindow == true)) {
      return null;
    }
    final limit = _sqlCount(statement.limit, bound);
    final offset =
        statement.offset == null ? 0 : _sqlCount(statement.offset, bound);
    if (limit == null ||
        offset == null ||
        limit < 0 ||
        offset < 0 ||
        limit > 0x3fffffff ||
        offset > 0x3fffffff ||
        offset + limit > 0x3fffffff) {
      return null;
    }
    return offset + limit;
  }

  /// Rows to read for `LIMIT` when no `ORDER BY` or `WHERE` can change them.
  int? _unorderedScanLimit(SelectStatement statement, List<Object?> bound) {
    if (statement.order.isNotEmpty ||
        statement.where != null ||
        statement.distinct ||
        statement.groupBy.isNotEmpty ||
        statement.having != null ||
        statement.compounds.isNotEmpty ||
        statement.ctes.isNotEmpty ||
        statement.valuesQuery ||
        statement.limit == null ||
        statement.items.any((item) =>
            item.expression?.containsAggregate == true ||
            item.expression?.containsWindow == true)) {
      return null;
    }
    final limit = _sqlCount(statement.limit, bound);
    final offset =
        statement.offset == null ? 0 : _sqlCount(statement.offset, bound);
    if (limit == null ||
        offset == null ||
        limit < 0 ||
        offset < 0 ||
        limit > 0x3fffffff ||
        offset > 0x3fffffff ||
        offset + limit > 0x3fffffff) {
      return null;
    }
    return offset + limit;
  }

  /// True when a forward primary scan already yields [query]'s order.
  /// A fully reversed primary order is reported by [_primaryFullScanDelivery].
  bool _primaryScanSatisfiesOrder(SelectStatement query, CatalogTable table) {
    final delivery = _primaryFullScanDelivery(query, table);
    return delivery != null && !delivery.reverse;
  }

  /// Full primary scan direction that already yields [query]'s order.
  ///
  /// [reverse] walks the tree from its last key. Mixed directions, a range
  /// seek, and explicit non-default NULLS placement stay on the sort.
  ({bool reverse})? _primaryFullScanDelivery(
      SelectStatement query, CatalogTable table) {
    if (!_queryCanReuseIndexOrder(query)) return null;
    if (!table.withoutRowid) {
      if (query.order.isEmpty) return null;
      final first = query.order.first;
      final resolved = _resolvedOrderExpression(query, first);
      final name = _bareOrderColumn(resolved);
      if (name == null) return null;
      final rowids = {
        if (table.rowidAlias != null) asciiLower(table.rowidAlias!),
        for (final key in ['rowid', '_rowid_', 'oid'])
          if (!table.columns.any((column) => asciiLower(column.name) == key))
            key
      };
      if (!rowids.contains(name) ||
          _orderCollation(first, resolved!, table) != 'binary') {
        return null;
      }
      // The rowid is unique, so terms after it cannot change the order.
      return (reverse: first.descending);
    }
    final primary = table.columns
        .where((column) => column.primaryKey > 0)
        .toList()
      ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
    final matched = query.order.length > primary.length
        ? primary.length
        : query.order.length;
    if (matched == 0) return null;
    final stored = <bool>[];
    for (var i = 0; i < matched; i++) {
      final resolved = _resolvedOrderExpression(query, query.order[i]);
      final name = _bareOrderColumn(resolved);
      if (name != asciiLower(primary[i].name) ||
          _orderCollation(query.order[i], resolved!, table) !=
              table.primaryKeyCollations[i]) {
        return null;
      }
      stored.add(table.primaryKeyDescending[i]);
    }
    if (query.order.length > primary.length && matched != primary.length) {
      return null;
    }
    return _orderDirection(
        stored,
        query.order.length > primary.length
            ? query.order.sublist(0, primary.length)
            : query.order);
  }

  /// Every requested term matches [stored] directions, or every term is flipped.
  ({bool reverse})? _orderDirection(List<bool> stored, List<OrderTerm> terms) {
    if (terms.isEmpty || terms.length != stored.length) return null;
    var forward = true;
    var backward = true;
    for (var i = 0; i < terms.length; i++) {
      if (terms[i].descending == stored[i]) {
        backward = false;
      } else {
        forward = false;
      }
    }
    if (forward) return (reverse: false);
    if (backward) return (reverse: true);
    return null;
  }

  /// True when a forward index scan already yields [query]'s order.
  ///
  /// [equalityPrefix] columns are fixed by the seek. Their direction does not
  /// change the delivered rows. A descending request, a mismatched collation,
  /// an expression that is not the index expression, or an explicit NULLS
  /// placement other than SQLite's default stays on the existing sort.
  bool _indexScanSatisfiesOrder(SelectStatement query, CatalogTable table,
      IndexDefinition definition, int equalityPrefix) {
    final delivery =
        _indexScanDelivery(query, table, definition, equalityPrefix);
    return delivery != null && !delivery.reverse;
  }

  /// Forward, or a full-scan reverse, of [definition] yields [query]'s order.
  ///
  /// Reversing a range or equality seek is not claimed here: those plans keep
  /// the existing sort when the requested direction is flipped.
  ({bool reverse})? _indexScanDelivery(SelectStatement query,
      CatalogTable table, IndexDefinition definition, int equalityPrefix) {
    if (!_queryCanReuseIndexOrder(query) ||
        equalityPrefix < 0 ||
        equalityPrefix > definition.terms.length) {
      return null;
    }
    ({bool reverse})? matchFrom(int start, {required bool allowReverse}) {
      if (query.order.length > definition.terms.length - start) return null;
      final stored = <bool>[];
      final terms = <OrderTerm>[];
      for (var i = 0; i < query.order.length; i++) {
        final term = query.order[i];
        final resolved = _resolvedOrderExpression(query, term);
        final key = definition.terms[start + i];
        if (resolved == null || !_sameIndexOrder(resolved, key)) return null;
        if (_orderCollation(term, resolved, table) !=
            asciiLower(key.collation)) {
          return null;
        }
        if (start + i < equalityPrefix) continue;
        stored.add(key.descending);
        terms.add(term);
      }
      if (stored.isEmpty) return (reverse: false);
      final direction = _orderDirection(stored, terms);
      if (direction == null || direction.reverse && !allowReverse) return null;
      return direction;
    }

    return matchFrom(equalityPrefix, allowReverse: equalityPrefix == 0) ??
        (equalityPrefix > 0 ? matchFrom(0, allowReverse: false) : null);
  }

  /// How many leading order terms a forward index scan already groups.
  ///
  /// A full match stays on [scanSatisfiesOrder]. A proper prefix feeds the
  /// block sort. A flipped direction does not, because range seeks stay forward.
  int _forwardIndexOrderPrefix(SelectStatement query, CatalogTable table,
      IndexDefinition definition, int equalityPrefix) {
    if (!_queryCanReuseIndexOrder(query) ||
        equalityPrefix < 0 ||
        equalityPrefix > definition.terms.length ||
        query.order.length <= 1 ||
        query.order.any((term) {
          final resolved = _resolvedOrderExpression(query, term);
          return resolved == null || _bareOrderColumn(resolved) == null;
        })) {
      return 0;
    }
    var count = 0;
    for (var i = 0; i < query.order.length; i++) {
      if (equalityPrefix + i >= definition.terms.length) break;
      final term = query.order[i];
      final resolved = _resolvedOrderExpression(query, term);
      final key = definition.terms[equalityPrefix + i];
      if (resolved == null ||
          _bareOrderColumn(resolved) == null ||
          !_sameIndexOrder(resolved, key) ||
          _orderCollation(term, resolved, table) != asciiLower(key.collation) ||
          term.descending != key.descending) {
        break;
      }
      count++;
    }
    if (count == 0 || count == query.order.length) return 0;
    return count;
  }

  /// Sorts each run that is already equal on the first [prefix] order terms.
  void _blockSortRows(List<RowValues> rows, SelectStatement query,
      CatalogTable table, int prefix) {
    int compareAt(RowValues a, RowValues b, int index) {
      final term = query.order[index];
      final resolved = _resolvedOrderExpression(query, term);
      final name = resolved == null ? null : _bareOrderColumn(resolved);
      if (name == null) return 0;
      final comparison = compareValues(a[name], b[name],
          _pager.header.textEncoding, _orderCollation(term, resolved!, table));
      return term.descending ? -comparison : comparison;
    }

    var run = 0;
    for (var end = 1; end <= rows.length; end++) {
      final split = end == rows.length ||
          List.generate(prefix, (index) => index)
              .any((index) => compareAt(rows[end - 1], rows[end], index) != 0);
      if (!split) continue;
      final indexed = [
        for (var slot = run; slot < end; slot++) (rows[slot], slot)
      ];
      indexed.sort((a, b) {
        for (var index = prefix; index < query.order.length; index++) {
          final comparison = compareAt(a.$1, b.$1, index);
          if (comparison != 0) return comparison;
        }
        return a.$2.compareTo(b.$2);
      });
      for (var slot = 0; slot < indexed.length; slot++) {
        rows[run + slot] = indexed[slot].$1;
      }
      run = end;
    }
  }

  /// A covering secondary index whose forward order is exactly the requested
  /// order. Non-covering order scans stay on the table scan plus the sort,
  /// because a rowid lookup per row is not assumed to be cheaper.
  QueryPlan? _coveringIndexOrderPlan(SelectStatement statement,
      CatalogTable table, _SqlDiagnosticTrace? diagnostics) {
    if (table.virtual || !_queryCanReuseIndexOrder(statement)) return null;
    QueryPlan? best;
    var bestWidth = 1 << 30;
    var bestName = '';
    for (final entry in catalog.entries.where((entry) =>
        entry.type == 'index' &&
        asciiLower(entry.tableName) == asciiLower(table.name))) {
      IndexDefinition? parsed;
      try {
        parsed =
            entry.sql == null ? null : IndexDefinition.parse(entry.sql!, table);
      } on Exception {
        continue;
      }
      final definition = parsed ??
          () {
            final raw = _indexDefinition(entry);
            return IndexDefinition(
                entry.name,
                table.name,
                raw.$5,
                [
                  for (var i = 0; i < raw.$1.length; i++)
                    IndexTerm(
                        ColumnExpr(raw.$1[i]), raw.$1[i], raw.$3[i], raw.$2[i])
                ],
                null);
          }();
      final delivery = _indexScanDelivery(statement, table, definition, 0);
      if (definition.terms.any((term) => term.columnName == null) ||
          !impliesIndexPredicate(statement.where, definition.predicate,
              strongerNumeric: true) ||
          delivery == null) {
        continue;
      }
      final names = [
        for (final term in definition.terms) asciiLower(term.columnName!)
      ];
      if (!_coveredByIndex(statement, table, names)) continue;
      if (definition.terms.length > bestWidth ||
          definition.terms.length == bestWidth &&
              entry.name.compareTo(bestName) > 0) {
        continue;
      }
      bestWidth = definition.terms.length;
      bestName = entry.name;
      best = QueryPlan._indexed(entry.rootPage,
          _IndexAccess(entry.name, (_) => 0), 'secondary-index-scan',
          covering: true,
          coveredColumns: names,
          scanSatisfiesOrder: true,
          scanReverse: delivery.reverse);
    }
    if (best == null) return null;
    diagnostics?.record('secondary-index-scan', 'covering-index-order',
        index: bestName, chosen: true);
    return best;
  }

  bool _queryCanReuseIndexOrder(SelectStatement query) {
    if (query.order.isEmpty ||
        query.groupBy.isNotEmpty ||
        query.having != null ||
        query.sources.length != 1 ||
        query.sources.single.alias != null ||
        query.sources.single.query != null ||
        query.items.any((item) =>
            item.expression?.containsAggregate == true ||
            item.expression?.containsWindow == true) ||
        query.order.any((term) =>
            term.expression.containsAggregate ||
            term.expression.containsWindow ||
            _nested(term.expression).isNotEmpty) ||
        _expressions(query).any(_qualified)) {
      return false;
    }
    for (final term in query.order) {
      if (term.nullsFirst != null && term.nullsFirst == term.descending) {
        return false;
      }
    }
    return true;
  }

  Expr? _resolvedOrderExpression(SelectStatement query, OrderTerm term) {
    var expression = term.expression;
    final ordinal = expressionOrdinal(expression);
    if (ordinal != null) {
      if (ordinal < BigInt.one ||
          ordinal > BigInt.from(query.items.length) ||
          query.items[ordinal.toInt() - 1].expression == null) {
        return null;
      }
      expression = query.items[ordinal.toInt() - 1].expression!;
    } else {
      final operand = indexOperand(expression);
      if (operand is ColumnExpr && operand.qualifier == null) {
        final output = query.items
            .where((item) =>
                item.explicitAlias && asciiLower(item.label) == operand.key)
            .firstOrNull;
        if (output?.expression != null) expression = output!.expression!;
      }
    }
    return expression;
  }

  String? _bareOrderColumn(Expr? expression) {
    final operand = expression == null ? null : indexOperand(expression);
    if (operand is! ColumnExpr || operand.qualifier != null) return null;
    return operand.key;
  }

  bool _sameIndexOrder(Expr order, IndexTerm term) {
    final left = indexOperand(order);
    final right = indexOperand(term.expression);
    if (left is ColumnExpr && right is ColumnExpr) {
      String bare(String key) =>
          asciiLower(key.contains('.') ? key.split('.').last : key);
      return bare(left.key) == bare(right.key);
    }
    return sameExpression(left, right);
  }

  String _orderCollation(OrderTerm term, Expr resolved, CatalogTable table) {
    final context = EvalContext({}, {
      for (final column in table.columns)
        asciiLower(column.name): column.affinity
    }, const [], _pager.header.textEncoding)
      ..collations = {
        for (final column in table.columns)
          asciiLower(column.name): column.collation
      };
    return asciiLower(term.expression.explicitCollation(context) ??
        resolved.collation(context) ??
        'binary');
  }

  /// A primary B-tree can supply these orders before projection callbacks.
  /// The caller chooses the key prefix used by its bound source rows.
  List<(String, bool, String)>? _physicalScanOrder(
      SelectStatement query, CatalogTable table,
      {String prefix = ''}) {
    if (query.order.isEmpty ||
        query.groupBy.isNotEmpty ||
        query.items.any((item) =>
            item.expression?.containsAggregate == true ||
            item.expression?.containsWindow == true)) {
      return null;
    }
    final source = query.sources.singleOrNull;
    final alias = asciiLower(source?.alias ?? source?.table ?? table.name);
    final primary = table.columns
        .where((column) => column.primaryKey > 0)
        .toList()
      ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
    if (table.withoutRowid && query.order.length > primary.length ||
        !table.withoutRowid && query.order.length != 1) {
      return null;
    }
    String? physicalName(Expr expression) {
      final operand = indexOperand(expression);
      if (operand is! ColumnExpr) return null;
      final key = operand.key;
      if (operand.qualifier == null) return key;
      for (final qualifier in ['$alias.', 'main.$alias.']) {
        if (key.startsWith(qualifier)) return key.substring(qualifier.length);
      }
      return null;
    }

    final context = EvalContext({}, {
      for (final column in table.columns) ...{
        asciiLower(column.name): column.affinity,
        '$alias.${asciiLower(column.name)}': column.affinity,
        'main.$alias.${asciiLower(column.name)}': column.affinity
      }
    }, const [], _pager.header.textEncoding)
      ..collations = {
        for (final column in table.columns) ...{
          asciiLower(column.name): column.collation,
          '$alias.${asciiLower(column.name)}': column.collation,
          'main.$alias.${asciiLower(column.name)}': column.collation
        }
      };
    bool? reversed;
    for (var i = 0; i < query.order.length; i++) {
      final term = query.order[i];
      var expression = term.expression;
      final ordinal = expressionOrdinal(expression);
      if (ordinal != null) {
        if (ordinal < BigInt.one ||
            ordinal > BigInt.from(query.items.length) ||
            query.items[ordinal.toInt() - 1].expression == null) {
          return null;
        }
        expression = query.items[ordinal.toInt() - 1].expression!;
      } else {
        final operand = indexOperand(expression);
        if (operand is ColumnExpr && operand.qualifier == null) {
          final output = query.items
              .where((item) =>
                  item.explicitAlias && asciiLower(item.label) == operand.key)
              .firstOrNull;
          if (output != null) expression = output.expression!;
        }
      }
      final name = physicalName(expression);
      if (name == null) return null;
      if (!table.withoutRowid) {
        final rowids = {
          if (table.rowidAlias != null) asciiLower(table.rowidAlias!),
          for (final key in ['rowid', '_rowid_', 'oid'])
            if (!table.columns.any((column) => asciiLower(column.name) == key))
              key
        };
        if (!rowids.contains(name)) return null;
        return [('$prefix$name', term.descending, 'binary')];
      }
      final collation = term.expression.explicitCollation(context) ??
          expression.collation(context) ??
          'binary';
      if (name != asciiLower(primary[i].name) ||
          collation != table.primaryKeyCollations[i]) {
        return null;
      }
      final direction = term.descending != table.primaryKeyDescending[i];
      reversed ??= direction;
      if (direction != reversed) return null;
    }
    return [
      for (var i = 0; i < primary.length; i++)
        (
          '$prefix${asciiLower(primary[i].name)}',
          table.primaryKeyDescending[i] != (reversed ?? false),
          table.primaryKeyCollations[i]
        )
    ];
  }

  void _sortPhysicalRows(
      List<RowValues> rows, List<(String, bool, String)> order) {
    rows.sort((a, b) {
      for (final term in order) {
        final comparison = compareValues(
            a[term.$1], b[term.$1], _pager.header.textEncoding, term.$3);
        if (comparison != 0) return term.$2 ? -comparison : comparison;
      }
      return 0;
    });
  }

  _QueryExecution _evaluate(SelectStatement statement, List<Object?> bound,
      CatalogTable? table, Iterable<RowValues> input,
      {SqlRows Function(SelectStatement, EvalContext)? subquery,
      bool inTrigger = false,
      bool inputOrdered = false,
      bool deferredProjection = false,
      bool omitProjection = false,
      _SqlDiagnosticTrace? diagnostics}) {
    final order =
        inputOrdered || omitProjection ? const <OrderTerm>[] : statement.order;
    final distinct = !omitProjection && statement.distinct;
    final columns = table?.columns ?? <CatalogColumn>[];
    final collations = {
      for (final column in columns) asciiLower(column.name): column.collation
    };
    final names = columns.map((c) => asciiLower(c.name)).toSet();
    final affinities = {
      for (final c in columns) asciiLower(c.name): c.affinity
    };
    if (table != null && !table.withoutRowid) {
      for (final name in ['rowid', '_rowid_', 'oid']) {
        names.add(name);
        affinities.putIfAbsent(name, () => 'numeric');
      }
    }
    final items = <SelectItem>[];
    for (final item in statement.items) {
      if (item.expression == null) {
        if (table == null) {
          throw const SqlException('SELECT * requires a table');
        }
        items.addAll(columns
            .where((column) => !column.hidden)
            .map((c) => SelectItem(ColumnExpr(c.name), c.name)));
      } else {
        items.add(item);
      }
    }
    for (final item in items) {
      item.expression!.validate(names);
    }
    final aliasExpressions = {
      for (final item in items) asciiLower(item.label): item.expression!
    };
    final unambiguousAliases = aliasExpressions.keys
        .where((name) =>
            names.contains(name) ||
            !names.any((field) => field.endsWith('.$name')))
        .toSet();
    statement.where?.validate({...names, ...unambiguousAliases});
    void validateWhereAliases(Expr expression) {
      if (expression is ColumnExpr && !names.contains(expression.key)) {
        final alias = aliasExpressions[expression.key];
        if (alias != null &&
            (alias.containsAggregate || alias.containsWindow)) {
          throw const SqlException('Aggregate or window alias in WHERE');
        }
      }
      for (final child in expression.children) {
        validateWhereAliases(child);
      }
    }

    if (statement.where != null) validateWhereAliases(statement.where!);
    if ((statement.where?.containsAggregate ?? false) ||
        (statement.where?.containsWindow ?? false)) {
      throw const SqlException('Aggregate in WHERE');
    }
    final groupBy = <Expr>[];
    for (var expr in statement.groupBy) {
      final ordinal = expressionOrdinal(expr);
      if (ordinal != null) {
        if (ordinal < BigInt.one || ordinal > BigInt.from(items.length)) {
          throw const SqlException('GROUP BY index out of range');
        }
        final collation = expr.explicitCollation(
            EvalContext({}, {}, [], _pager.header.textEncoding));
        expr = items[ordinal.toInt() - 1].expression!;
        if (collation != null) expr = CollateExpr(expr, collation);
      } else if (expr is ColumnExpr &&
          !names.contains(expr.key) &&
          unambiguousAliases.contains(expr.key)) {
        expr = aliasExpressions[expr.key]!;
      }
      expr.validate(names);
      if (expr.containsAggregate || expr.containsWindow) {
        throw const SqlException('Aggregate or window in GROUP BY');
      }
      groupBy.add(expr);
    }
    final aggregate = groupBy.isNotEmpty ||
        items.any((item) => item.expression!.containsAggregate) ||
        order.any((term) => term.expression.containsAggregate) ||
        (statement.having?.containsAggregate ?? false);
    if (statement.having != null && !aggregate) {
      throw const SqlException('HAVING requires aggregate query');
    }
    statement.having?.validate({...names, ...unambiguousAliases});
    if (statement.having?.containsWindow ?? false) {
      throw const SqlException('Window in HAVING');
    }
    final windowCache = <Expr, Object>{};

    final aliases = items.map((item) => asciiLower(item.label)).toSet();
    for (final term in statement.order) {
      term.expression.validate({...names, ...aliases});
    }
    int projectionSlot(Expr expression) {
      final operand = indexOperand(expression);
      final ordinal = expressionOrdinal(expression);
      if (ordinal != null) {
        if (ordinal < BigInt.one || ordinal > BigInt.from(items.length)) {
          throw const SqlException('ORDER BY index out of range');
        }
        return ordinal.toInt() - 1;
      }
      if (operand is ColumnExpr) {
        final alias =
            items.indexWhere((item) => asciiLower(item.label) == operand.key);
        if (alias >= 0) return alias;
      }
      return items.indexWhere(
          (item) => sameExpression(indexOperand(item.expression!), operand));
    }

    if (omitProjection) {
      for (final term in statement.order) {
        projectionSlot(term.expression);
      }
    }
    final orderSlots =
        order.map((term) => projectionSlot(term.expression)).toList();
    final havingAliases = <String>{};
    void havingReferences(Expr expr) {
      havingAliases.addAll(expr.unaggregatedColumns);
      for (final query in _nested(expr)) {
        for (final item in _expressions(query)) {
          havingReferences(item);
        }
      }
    }

    if (statement.having != null) havingReferences(statement.having!);
    statement.limit?.validate({});
    statement.offset?.validate({});
    final constantContext =
        EvalContext({}, affinities, bound, _pager.header.textEncoding)
          ..inTrigger = inTrigger
          ..subquery = subquery
          ..collations = collations;
    int? count(Expr? expr) {
      if (expr == null) return null;
      var value = expr.evaluate(constantContext);
      if (value is String) value = numeric(value);
      if (value is double &&
          value.isFinite &&
          value == value.truncateToDouble()) {
        value = BigInt.from(value);
      }
      if (value is! BigInt || value.bitLength > 63) {
        throw const SqlException('LIMIT/OFFSET datatype mismatch');
      }
      // Saturate to a safe in-memory list index; no rows can exceed this count.
      if (value > BigInt.from(0x7fffffff)) return 0x7fffffff;
      if (value < BigInt.from(-0x7fffffff)) return -0x7fffffff;
      return value.toInt();
    }

    Iterable<List<Object?>> rows([_QueryOffset? consumerOffset]) sync* {
      final windowed = items.any((item) => item.expression!.containsWindow) ||
          (omitProjection ? statement.order : order)
              .any((term) => term.expression.containsWindow);
      final limit = count(statement.limit);
      final offset = count(statement.offset) ?? 0;
      if (diagnostics != null) {
        diagnostics.hasOrder = order.isNotEmpty;
        diagnostics.inputOrdered = inputOrdered && statement.order.isNotEmpty;
        diagnostics.distinct = distinct;
        diagnostics.bounded = statement.limit != null &&
            !distinct &&
            !statement.subqueryFirstRowOnly;
        diagnostics.limit = limit;
        diagnostics.offset = offset;
      }
      if (limit == 0) return;
      final source = diagnostics == null ? input : diagnostics.source(input);
      final selected = source.where((row) {
        final ctx =
            EvalContext(row, affinities, bound, _pager.header.textEncoding)
              ..inTrigger = inTrigger
              ..subquery = subquery
              ..columnAliases = aliasExpressions
              ..collations = collations;
        return statement.where == null ||
            truth(statement.where!.evaluate(ctx), _pager.header.textEncoding) ==
                true;
      });
      final matching =
          diagnostics == null ? selected : diagnostics.matches(selected);
      final filtered = windowed && !aggregate ? matching.toList() : matching;
      final groups = <(List<Object?>, Iterable<RowValues>)>[];
      if (aggregate && groupBy.isEmpty) {
        groups.add(([], filtered));
      } else if (aggregate) {
        final groupCollations =
            groupBy.map((expr) => expr.collation(constantContext)).toList();
        var groupsArriveSorted = true;
        for (final row in filtered) {
          final ctx =
              EvalContext(row, affinities, bound, _pager.header.textEncoding)
                ..inTrigger = inTrigger
                ..subquery = subquery
                ..collations = collations;
          final keys = groupBy.map((expr) => expr.evaluate(ctx)).toList();
          if (groups.isNotEmpty &&
              _same(groups.last.$1, keys, groupCollations)) {
            (groups.last.$2 as List<RowValues>).add(row);
            continue;
          }
          final index = groups
              .indexWhere((group) => _same(group.$1, keys, groupCollations));
          if (index < 0) {
            if (groups.isNotEmpty) {
              for (var i = 0; i < keys.length; i++) {
                final comparison = compareValues(groups.last.$1[i], keys[i],
                    _pager.header.textEncoding, groupCollations[i]);
                if (comparison > 0) {
                  groupsArriveSorted = false;
                }
                if (comparison != 0) {
                  break;
                }
              }
            }
            groups.add((keys, <RowValues>[row]));
          } else {
            groupsArriveSorted = false;
            (groups[index].$2 as List<RowValues>).add(row);
          }
        }
        if (!groupsArriveSorted) {
          groups.sort((a, b) {
            for (var i = 0; i < groupBy.length; i++) {
              final comparison = compareValues(a.$1[i], b.$1[i],
                  _pager.header.textEncoding, groupCollations[i]);
              if (comparison != 0) return comparison;
            }
            return 0;
          });
        }
      }
      final aggregateReferences = <FunctionExpr>[
        for (final expr in [
          ...items.map((item) => item.expression!),
          if (statement.having != null) statement.having!,
          ...order.map((term) => term.expression)
        ])
          ...aggregateFunctions(expr)
      ];
      final functions = <FunctionExpr>[];
      final aggregateSlots = <FunctionExpr, int>{};
      for (final function in aggregateReferences) {
        var slot = functions.indexWhere((previous) =>
            identical(previous, function) ||
            sameExpression(previous, function));
        if (slot < 0) {
          slot = functions.length;
          functions.add(function);
        }
        aggregateSlots[function] = slot;
      }
      final groupProjectionSlots = [
        for (final item in items)
          groupBy.indexWhere(
              (expression) => sameExpression(expression, item.expression!))
      ];
      final preparedGroupKeys = <EvalContext, List<Object?>>{};
      final windowGroups = <RowValues, List<RowValues>>{};
      final windowAggregates = <RowValues, Map<Expr, Object?>>{};
      bool referencesStoredRow(Expr expression) {
        if (expression is FunctionExpr && expression.isAggregate) return false;
        if (expression is ColumnExpr) {
          return !groupBy.any((key) => sameExpression(key, expression));
        }
        return expression.children.any(referencesStoredRow);
      }

      final storeGroupRows = !aggregate ||
          windowed ||
          (statement.having != null &&
              referencesStoredRow(statement.having!)) ||
          items.any((item) => referencesStoredRow(item.expression!)) ||
          order.any((term) => referencesStoredRow(term.expression));
      Iterable<EvalContext> prepare() sync* {
        final Iterable<(List<Object?>, Iterable<RowValues>)> inputs = aggregate
            ? groups
            : filtered.map((row) => (<Object?>[], <RowValues>[row]));
        for (final group in inputs) {
          final groupRows = <RowValues>[];
          final base =
              EvalContext({}, affinities, bound, _pager.header.textEncoding)
                ..inTrigger = inTrigger
                ..subquery = subquery
                ..collations = collations;
          final accumulators = aggregate
              ? functions.map((fn) => PreparedSqlAggregate(fn, base)).toList()
              : <PreparedSqlAggregate>[];
          for (final candidate in group.$2) {
            if (storeGroupRows) groupRows.add(candidate);
            if (aggregate) {
              final context = base.forRow(candidate);
              for (final accumulator in accumulators) {
                accumulator.step(context);
              }
            }
          }
          var row = groupRows.isEmpty
              ? <String, Object?>{for (final name in names) name: null}
              : groupRows.first;
          final extrema = accumulators
              .where((accumulator) =>
                  accumulator.function.registered == null &&
                  ['min', 'max'].contains(accumulator.function.key))
              .toList();
          if (extrema.length == 1 && groupRows.isNotEmpty) {
            row = extrema.single.representative ?? groupRows.first;
          }
          row = {...row};
          final ctx =
              EvalContext(row, affinities, bound, _pager.header.textEncoding)
                ..group = aggregate ? groupRows : null
                ..windowRow = groupRows.firstOrNull
                ..windowCache = windowCache
                ..inTrigger = inTrigger
                ..subquery = subquery
                ..collations = collations;
          if (aggregate) {
            final values = [
              for (final accumulator in accumulators) accumulator.finish()
            ];
            for (final entry in aggregateSlots.entries) {
              ctx.aggregateValues[entry.key] = values[entry.value];
            }
            preparedGroupKeys[ctx] = group.$1;
          }
          for (final item in items) {
            if (!item.expression!.containsWindow &&
                havingAliases.contains(asciiLower(item.label)) &&
                !names.contains(asciiLower(item.label))) {
              row[asciiLower(item.label)] = item.expression!.evaluate(ctx);
            }
          }
          if (statement.having != null &&
              truth(statement.having!.evaluate(ctx),
                      _pager.header.textEncoding) !=
                  true) {
            continue;
          }
          if (windowed) {
            if (ctx.group != null) windowGroups[row] = ctx.group!;
            windowAggregates[row] = ctx.aggregateValues;
          }
          yield ctx;
        }
      }

      var prepared = windowed ? prepare().toList() : prepare();
      final windowRows =
          windowed ? prepared.map((ctx) => ctx.row).toList() : <RowValues>[];
      WindowProgram? windowProgram;
      if (windowed) {
        for (final ctx in prepared) {
          ctx.windowRows = windowRows;
          ctx.windowGroups = windowGroups;
          ctx.windowAggregates = windowAggregates;
        }
        bool orderedWindowInput(WindowExpr window) {
          if (aggregate || statement.sources.length != 1) return false;
          final source = statement.sources.single;
          if (source.query != null ||
              source.group.isNotEmpty ||
              source.table == null ||
              statement.ctes.containsKey(asciiLower(source.table!))) {
            return false;
          }
          final physicalEntry = catalog.entries
              .where((entry) =>
                  entry.type == 'table' &&
                  asciiLower(entry.name) == asciiLower(source.table!))
              .firstOrNull;
          final physical =
              physicalEntry == null ? null : catalog.table(physicalEntry.name);
          if (physical == null ||
              physical.withoutRowid ||
              window.partition.isNotEmpty) {
            return false;
          }
          if (window.order.isEmpty) return true;
          if (window.order.length != 1) return false;
          final expression = indexOperand(window.order.single.expression);
          if (expression is! ColumnExpr) return false;
          final key = expression.key.split('.').last;
          return key == asciiLower(physical.rowidAlias ?? '') ||
              ['rowid', '_rowid_', 'oid'].contains(key) &&
                  !physical.columns
                      .any((column) => asciiLower(column.name) == key);
        }

        windowProgram = WindowProgram(
            prepared.toList(),
            [
              ...items.map((item) => item.expression!),
              ...(omitProjection ? statement.order : order)
                  .map((term) => term.expression)
            ],
            orderedWindowInput);
        prepared = windowProgram.contexts;
      }
      final sortTerms = [
        for (var i = 0; i < order.length; i++)
          OrderTerm(
              CollateExpr(
                  order[i].expression,
                  order[i].expression.explicitCollation(constantContext) ??
                      (orderSlots[i] >= 0
                          ? items[orderSlots[i]]
                              .expression!
                              .collation(constantContext)
                          : order[i].expression.collation(constantContext)) ??
                      'binary'),
              order[i].descending,
              order[i].nullsFirst)
      ];
      int compareKeys(List<Object?> a, List<Object?> b) {
        for (var i = 0; i < order.length; i++) {
          final comparison = sortTerms[i].compare(a[i], b[i], constantContext);
          if (comparison != 0) return comparison;
        }
        return 0;
      }

      final output = <(List<Object?>, List<Object?>, int)>[];
      BoundedSortHeap<(List<Object?>, List<Object?>, int)>? selection;
      final unsorted = order.isEmpty;
      final streamLimit = !distinct && unsorted;
      var emitted = 0;
      var sequence = 0;
      var skipped = 0;
      for (final ctx in prepared) {
        windowProgram?.advance(ctx);
        if (streamLimit && skipped < offset) {
          skipped++;
          continue;
        }
        if (streamLimit && (consumerOffset?.remaining ?? 0) > 0) {
          consumerOffset!.remaining--;
          emitted++;
          if (limit != null && limit >= 0 && emitted >= limit) return;
          continue;
        }
        final row = ctx.row;
        ctx.windowRows = windowRows;
        ctx.windowRow = row;
        ctx.windowGroups = windowGroups;
        ctx.windowAggregates = windowAggregates;
        final defer = deferredProjection &&
            !aggregate &&
            !windowed &&
            !distinct &&
            order.isEmpty &&
            statement.offset == null;
        if (omitProjection && windowed) {
          void evaluateWindows(Expr expression) {
            if (expression is WindowExpr) {
              expression.evaluate(ctx);
              return;
            }
            for (final child in expression.children) {
              evaluateWindows(child);
            }
          }

          for (final expression in [
            ...items.map((item) => item.expression!),
            ...statement.order.map((term) => term.expression)
          ]) {
            evaluateWindows(expression);
          }
        }
        final values = List<Object?>.filled(items.length, null);
        final evaluated = <int>{};
        Object? project(int slot) {
          if (evaluated.add(slot)) {
            final grouped = aggregate ? groupProjectionSlots[slot] : -1;
            values[slot] = omitProjection
                ? BigInt.one
                : grouped >= 0
                    ? preparedGroupKeys[ctx]![grouped]
                    : defer
                        ? SqlValueBinding(
                            () => items[slot].expression!.evaluate(ctx))
                        : items[slot].expression!.evaluate(ctx);
          }
          return values[slot];
        }

        final earlyKeys = !unsorted &&
            statement.limit != null &&
            !distinct &&
            !statement.subqueryFirstRowOnly;
        List<Object?>? candidateKeys;
        if (earlyKeys) {
          ctx.columnAliases = aliasExpressions;
          candidateKeys = [
            for (var i = 0; i < order.length; i++)
              orderSlots[i] >= 0
                  ? project(orderSlots[i])
                  : order[i].expression.evaluate(ctx)
          ];
          final capacity = limit != null && limit >= 0
              ? limit + (offset > 0 ? offset : 0)
              : null;
          if (capacity != null && output.length >= capacity) {
            // Tiny K keeps the existing linear path. Build lazily only when
            // the retained set fills; large LIMITs over short inputs pay no
            // heap construction cost. Sequence preserves the last-worst tie.
            if (capacity >= 32) {
              selection ??= BoundedSortHeap(output, (a, b) {
                final keys = compareKeys(a.$2, b.$2);
                return keys != 0 ? keys : a.$3.compareTo(b.$3);
              });
              if (compareKeys(candidateKeys, selection.worst.$2) >= 0) continue;
              selection.removeWorst();
            } else {
              var worst = 0;
              for (var i = 1; i < output.length; i++) {
                if (compareKeys(output[i].$2, output[worst].$2) >= 0) worst = i;
              }
              if (compareKeys(candidateKeys, output[worst].$2) >= 0) continue;
              output.removeAt(worst);
            }
          }
        }
        for (var i = 0; i < items.length; i++) {
          project(i);
        }
        if (distinct) {
          final distinctCollations =
              items.map((item) => item.expression!.collation(ctx)).toList();
          final duplicate = inputOrdered &&
                  _orderPrefixCovers(statement.order, items)
              ? output.isNotEmpty &&
                  _same(output.last.$1, values, distinctCollations)
              : output
                  .any((entry) => _same(entry.$1, values, distinctCollations));
          if (duplicate) continue;
        }
        if (unsorted) {
          if (distinct) {
            output.add((values, const [], output.length));
            if (skipped < offset) {
              skipped++;
              continue;
            }
          }
          yield values;
          emitted++;
          if (limit != null && limit >= 0 && emitted >= limit) return;
          continue;
        }
        final orderRow = {...row};
        for (var i = 0; i < items.length; i++) {
          orderRow[asciiLower(items[i].label)] = values[i];
        }
        final orderCtx =
            EvalContext(orderRow, affinities, bound, _pager.header.textEncoding)
              ..group = ctx.group
              ..windowRows = windowRows
              ..windowRow = row
              ..windowCache = windowCache
              ..inTrigger = inTrigger
              ..subquery = subquery
              ..collations = collations;
        orderCtx.windowGroups = windowGroups;
        orderCtx.windowAggregates = windowAggregates;
        orderCtx.aggregateValues.addAll(ctx.aggregateValues);
        final keys = candidateKeys ?? <Object?>[];
        for (var i = 0; candidateKeys == null && i < order.length; i++) {
          final slot = orderSlots[i];
          keys.add(slot >= 0
              ? values[slot]
              : order[i].expression.evaluate(orderCtx));
        }
        final entry = (values, keys, sequence++);
        if (selection == null) {
          output.add(entry);
        } else {
          selection.add(entry);
        }
        if (streamLimit &&
            limit != null &&
            limit >= 0 &&
            output.length >= limit) {
          break;
        }
      }
      if (unsorted) return;
      output.sort((a, b) {
        for (var i = 0; i < order.length; i++) {
          final comparison =
              sortTerms[i].compare(a.$2[i], b.$2[i], constantContext);
          if (comparison != 0) return comparison;
        }
        return a.$3.compareTo(b.$3);
      });
      var rows = output
          .map((entry) => entry.$1)
          .skip(streamLimit || offset < 0 ? 0 : offset);
      if (limit != null && limit >= 0) rows = rows.take(limit);
      yield* rows;
    }

    final metadata = _QueryExecution(
        _labels(items, columns, table),
        rows(),
        items
            .map((item) => item.expression!.affinity(constantContext))
            .toList(),
        items.map((item) {
          final expr = indexOperand(item.expression!);
          if (expr is CastExpr) return expr.type;
          if (expr is SubqueryExpr && !expr.exists) {
            return expr.preparedColumnDeclaredTypes?.singleOrNull ?? '';
          }
          return expr is ColumnExpr
              ? columns
                      .where((c) => asciiLower(c.name) == expr.key)
                      .firstOrNull
                      ?.declaredType ??
                  ''
              : '';
        }).toList(),
        items
            .map((item) => item.expression!.collation(constantContext) ?? '')
            .toList(),
        skipRows: rows);

    return metadata;
  }

  List<String> _labels(List<SelectItem> items, List<CatalogColumn> columns,
      CatalogTable? table) {
    String label(SelectItem item) {
      final expr = item.expression;
      if (expr is ColumnExpr && !item.explicitAlias) {
        for (final column in columns) {
          if (asciiLower(column.name) == expr.key) {
            return column.name;
          }
        }
        if (table != null &&
            !table.withoutRowid &&
            ['rowid', '_rowid_', 'oid'].contains(expr.key)) {
          return table.rowidAlias ?? 'rowid';
        }
      }
      return item.label;
    }

    return items.map(label).toList();
  }

  (List<String>, List<bool>, List<String>, String, bool) _indexDefinition(
      CatalogEntry entry) {
    final table = catalog.table(entry.tableName);
    if (entry.sql == null) {
      final number = int.parse(entry.name.split('_').last) - 1;
      final keys = table.autoIndexKeys[number];
      return (
        keys,
        table.autoIndexDescending[number],
        table.autoIndexCollations[number],
        table.autoIndexPrimary[number] ? 'pk' : 'u',
        true
      );
    }
    final definition = IndexDefinition.parse(entry.sql!, table);
    return (
      definition.terms.map((t) => t.columnName ?? '').toList(),
      definition.terms.map((t) => t.descending).toList(),
      definition.terms.map((t) => t.collation).toList(),
      'c',
      definition.unique
    );
  }

  static const _pragmaNames = [
    'application_id',
    'collation_list',
    'database_list',
    'encoding',
    'foreign_key_check',
    'foreign_key_list',
    'foreign_keys',
    'freelist_count',
    'function_list',
    'index_info',
    'index_list',
    'index_xinfo',
    'integrity_check',
    'page_count',
    'page_size',
    'pragma_list',
    'quick_check',
    'recursive_triggers',
    'schema_version',
    'table_info',
    'table_list',
    'table_xinfo',
    'user_version'
  ];

  // Metadata preparation must not scan rows, invoke callbacks, or evaluate a
  // view's WHERE, projection, LIMIT, CTEs, or derived sources.
  SelectStatement _pragmaMetadataQuery(SelectStatement source,
      {bool canonicalCasts = true}) {
    Expr projection(Expr expression) {
      if (!canonicalCasts) return expression;
      if (expression is CollateExpr) {
        return CollateExpr(projection(expression.operand), expression.name);
      }
      if (expression is! CastExpr) return expression;
      final type = expression.type.toUpperCase();
      final canonical = type.contains('INT')
          ? 'INT'
          : ['CHAR', 'CLOB', 'TEXT'].any(type.contains)
              ? 'TEXT'
              : type.isEmpty || type.contains('BLOB')
                  ? 'BLOB'
                  : ['REAL', 'FLOA', 'DOUB'].any(type.contains)
                      ? 'REAL'
                      : 'NUM';
      return CastExpr(expression.operand, canonical);
    }

    QuerySource sourceMetadata(QuerySource s) => QuerySource(
        table: s.table,
        tableOffset: s.tableOffset,
        schema: s.schema,
        indexedBy: s.indexedBy,
        notIndexed: s.notIndexed,
        rowIdentity: s.rowIdentity,
        pragmaArguments: s.pragmaArguments,
        query: s.query == null
            ? null
            : _pragmaMetadataQuery(s.query!, canonicalCasts: canonicalCasts),
        group: s.group.map(sourceMetadata).toList(),
        alias: s.alias,
        join: s.join,
        on: s.on,
        using: s.using,
        natural: s.natural);

    return SelectStatement([
      for (final item in source.items)
        SelectItem(
            item.expression == null ? null : projection(item.expression!),
            item.label,
            explicitAlias: item.explicitAlias)
    ], source.table, source.where, source.order, Literal(BigInt.zero), null,
        source.distinct, source.parameterCount)
      ..valuesQuery = source.valuesQuery
      ..sources.addAll(source.sources.map(sourceMetadata))
      ..cteMaterialization.addAll(source.cteMaterialization)
      ..ctes.addAll({
        for (final c in source.ctes.entries)
          c.key: (
            c.value.$1,
            _pragmaMetadataQuery(c.value.$2, canonicalCasts: canonicalCasts)
          )
      })
      ..compounds.addAll([
        for (final part in source.compounds)
          (
            part.$1,
            _pragmaMetadataQuery(part.$2, canonicalCasts: canonicalCasts)
          )
      ])
      ..groupBy.addAll(source.groupBy)
      ..having = source.having
      ..windowDefinitions.addAll(source.windowDefinitions);
  }

  void _prepareScalarMetadata(
      SelectStatement query,
      Map<String, (CatalogTable, List<RowValues>)> metadata,
      List<CatalogColumn> columns) {
    final scope = <String, CatalogColumn?>{
      for (final column in columns) asciiLower(column.name): column
    };
    void prepare(Expr expression) {
      if (expression is SubqueryExpr) {
        if (expression.preparedColumnAffinities == null) {
          final output = _pragmaColumnMetadata(
              expression.statement, metadata, scope, const {}, true);
          expression.preparedColumnAffinities =
              output.map((column) => column.affinity).toList();
          expression.preparedColumnDeclaredTypes =
              output.map((column) => column.declaredType).toList();
        }
        return;
      }
      for (final child in expression.children) {
        prepare(child);
      }
    }

    _expressions(query).forEach(prepare);
  }

  List<CatalogColumn> _pragmaColumnMetadata(SelectStatement query,
      Map<String, (CatalogTable, List<RowValues>)> metadata,
      [Map<String, CatalogColumn?> outer = const {},
      Map<String, List<CatalogColumn> Function()> inheritedCtes = const {},
      bool rightmost = false]) {
    final ctes = {...inheritedCtes};
    final cached = <String, List<CatalogColumn>>{};
    final loading = <String>{};
    List<CatalogColumn> materialize(List<CatalogColumn> columns,
        [List<String>? labels]) {
      final names = _relationColumnNames(
          labels ?? columns.map((column) => column.name).toList());
      return [
        for (var i = 0; i < columns.length; i++)
          CatalogColumn(names[i], columns[i].declaredType,
              affinityOverride: columns[i].affinity,
              collation: columns[i].collation.isEmpty
                  ? 'binary'
                  : columns[i].collation)
      ];
    }

    for (final entry in query.ctes.entries) {
      ctes[entry.key] = () {
        if (cached.containsKey(entry.key)) return cached[entry.key]!;
        if (!loading.add(entry.key)) {
          throw const SqlException('Circular CTE metadata');
        }
        try {
          // Compound output types come from the anchor, so a recursive term
          // never needs to execute or resolve itself to describe the output.
          final columns =
              _pragmaColumnMetadata(entry.value.$2, metadata, outer, ctes);
          final names = entry.value.$1;
          if (names.isNotEmpty && names.length != columns.length) {
            throw const SqlException('CTE column width mismatch');
          }
          return cached[entry.key] =
              materialize(columns, names.isEmpty ? null : names);
        } finally {
          loading.remove(entry.key);
        }
      };
    }
    if (rightmost && query.compounds.isNotEmpty) {
      return _pragmaColumnMetadata(
          query.compounds.last.$2, metadata, outer, ctes, true);
    }
    final local = <String, CatalogColumn?>{};
    final star = <CatalogColumn>[];
    final qualified = <String, List<CatalogColumn>>{};
    final implicit = <String, CatalogColumn?>{};
    if (query.sources.any((source) => source.group.isNotEmpty)) {
      // Use the executor's binding frame for joined groups, retaining hidden
      // child qualifiers as well as visible USING/NATURAL wildcard columns.
      // Every relation supplied here is empty: preparing metadata cannot run
      // a projection, ON callback, recursive queue, or a lazy view's rows.
      final prepared = <String, (CatalogTable, List<RowValues>)>{};
      final descriptors = <CatalogTable, (CatalogTable, List<RowValues>)>{};
      for (final entry in metadata.entries) {
        final original = entry.value.$1;
        final descriptor = descriptors.putIfAbsent(original, () {
          final table = original.rootPage <= 0
              ? original
              : CatalogTable(
                  original.name,
                  original.rootPage,
                  [
                    for (final column in original.columns)
                      CatalogColumn(
                          column.name,
                          column.declaredType.isEmpty
                              ? 'BLOB'
                              : column.declaredType,
                          affinityOverride: column.affinity,
                          collation: column.collation)
                  ],
                  withoutRowid: original.withoutRowid,
                  rowidAlias: original.rowidAlias);
          return (table, <RowValues>[]);
        });
        prepared[entry.key] = descriptor;
        if (!entry.key.startsWith('main.')) {
          prepared['main.${entry.key}'] = descriptor;
        }
      }
      var ordinal = 0;
      QuerySource describe(QuerySource source) {
        String? table = source.table;
        final key = asciiLower(source.table ?? '');
        final cte = source.schema == null ? ctes[key] : null;
        if (_isPragmaTableSource(source) && cte == null) {
          table = '\u0000metadata${ordinal++}';
          prepared[table] = (_pragmaSourceTable(source), []);
        } else if (source.query != null || cte != null) {
          final columns = source.query != null
              ? materialize(
                  _pragmaColumnMetadata(source.query!, metadata, outer, ctes))
              : cte!();
          table = '\u0000metadata${ordinal++}';
          prepared[table] =
              (CatalogTable(table, 0, columns, withoutRowid: true), []);
        }
        return QuerySource(
            table: table,
            tableOffset: source.tableOffset,
            schema: source.schema,
            indexedBy: source.indexedBy,
            notIndexed: source.notIndexed,
            rowIdentity: source.rowIdentity,
            group: source.group.map(describe).toList(),
            alias: source.alias ??
                (cte != null || _isPragmaTableSource(source)
                    ? source.table
                    : null),
            join: source.join,
            on: source.on,
            using: source.using,
            natural: source.natural);
      }

      final preparedQuery = SelectStatement(query.items, null, null, [],
          Literal(BigInt.zero), null, false, query.parameterCount)
        ..sources.addAll(query.sources.map(describe));
      final outerContext = EvalContext({
        for (final name in outer.keys) name: null
      }, {
        for (final entry in outer.entries)
          if (entry.value != null) entry.key: entry.value!.affinity
      }, const [], _pager.header.textEncoding)
        ..collations = {
          for (final entry in outer.entries)
            if (entry.value != null) entry.key: entry.value!.collation
        };
      final frame = _JoinedGroup('@metadata');
      _relational(preparedQuery, const [], prepared, outerContext,
          sourceGroup: frame);
      CatalogColumn renamed(CatalogColumn column, String label) =>
          CatalogColumn(label, column.declaredType,
              affinityOverride: column.affinity, collation: column.collation);
      for (final entry in frame.declared.entries) {
        local[entry.key] =
            renamed(entry.value, frame.labels[entry.key] ?? entry.value.name);
      }
      for (final entry in frame.refs.entries) {
        local[entry.key] =
            entry.value.length == 1 ? local[entry.value.single] : null;
      }
      for (final slot in frame.star) {
        star.add(renamed(frame.declared[slot.$2]!, slot.$1));
      }
      for (final entry in frame.sourceStars.entries) {
        qualified[entry.key] = [
          for (final slot in entry.value)
            renamed(frame.declared[slot.$2]!, slot.$1)
        ];
      }
    } else {
      for (var i = 0; i < query.sources.length; i++) {
        final source = query.sources[i];
        final key = source.schema == null
            ? asciiLower(source.table ?? '')
            : 'main.${asciiLower(source.table!)}';
        final table = metadata[key]?.$1;
        var columns = _isPragmaTableSource(source) &&
                (source.schema != null || !ctes.containsKey(key))
            ? _pragmaSourceTable(source).columns
            : source.query != null
                ? materialize(
                    _pragmaColumnMetadata(source.query!, metadata, outer, ctes))
                : source.schema == null && ctes.containsKey(key)
                    ? ctes[key]!()
                    : table?.columns;
        if (columns == null) {
          throw SqlException('Unknown metadata source: ${source.table}');
        }
        if (source.query == null && table != null && table.rootPage > 0) {
          columns = [
            for (final column in columns)
              CatalogColumn(column.name,
                  column.declaredType.isEmpty ? 'BLOB' : column.declaredType,
                  affinityOverride: column.affinity,
                  collation: column.collation)
          ];
        }
        final alias = asciiLower(source.alias ?? source.table ?? '@$i');
        qualified[alias] = columns.where((column) => !column.hidden).toList();
        final physical = source.table != null &&
            (source.schema != null || !ctes.containsKey(key));
        if (physical) qualified['main.$alias'] = qualified[alias]!;
        final using = source.natural
            ? columns
                .map((c) => asciiLower(c.name))
                .where((name) => star.any((c) => asciiLower(c.name) == name))
                .toSet()
            : source.using.map(asciiLower).toSet();
        for (final column in columns) {
          final name = asciiLower(column.name);
          local['$alias.$name'] = column;
          if (physical) local['main.$alias.$name'] = column;
          if (using.contains(name)) {
            final ordinal = star.indexWhere((c) => asciiLower(c.name) == name);
            if (ordinal < 0 || local[name] == null) {
              throw const SqlException('USING column missing or ambiguous');
            }
            final merged = source.join == 'RIGHT'
                ? column
                : source.join == 'FULL'
                    ? CatalogColumn(star[ordinal].name, '',
                        affinityOverride: 'none', collation: '')
                    : star[ordinal];
            local[name] = merged;
            star[ordinal] = merged;
          } else if (!column.hidden) {
            local[name] = local.containsKey(name) ? null : column;
            star.add(column);
          } else {
            local[name] = local.containsKey(name) ? null : column;
          }
        }
        if (source.query == null && table != null && !table.withoutRowid) {
          for (final name in ['rowid', '_rowid_', 'oid']) {
            if (columns.any((c) => asciiLower(c.name) == name)) continue;
            final column =
                CatalogColumn(table.rowidAlias ?? 'rowid', 'INTEGER');
            implicit['$alias.$name'] = column;
            if (physical) implicit['main.$alias.$name'] = column;
            implicit[name] = implicit.containsKey(name) ? null : column;
          }
        }
      }
    }
    for (final entry in implicit.entries) {
      local.putIfAbsent(entry.key, () => entry.value);
    }
    final scope = {...outer, ...local};
    final context = EvalContext({}, {
      for (final entry in scope.entries)
        if (entry.value != null) entry.key: entry.value!.affinity
    }, const [], _pager.header.textEncoding)
      ..collations = {
        for (final entry in scope.entries)
          if (entry.value != null) entry.key: entry.value!.collation
      };
    CatalogColumn expression(Expr expr) {
      if (expr is ColumnExpr) {
        final column = scope[expr.key];
        if (expr is BoolNameExpr && !scope.containsKey(expr.key)) {
          return CatalogColumn(expr.name, '', affinityOverride: 'none');
        }
        if (column == null) {
          if (scope.containsKey(expr.key)) {
            throw SqlException('Ambiguous column: ${expr.name}');
          }
          if (expr.doubleQuoted && doubleQuotedStringsEnabled) {
            return CatalogColumn(expr.name, 'TEXT', affinityOverride: 'none');
          }
          throw SqlException('Unknown or ambiguous column: ${expr.name}');
        }
        return column;
      }
      if (expr is CollateExpr) {
        final column = expression(expr.operand);
        return CatalogColumn(column.name, column.declaredType,
            affinityOverride: column.affinity, collation: expr.name);
      }
      if (expr is SubqueryExpr) {
        final columns =
            _pragmaColumnMetadata(expr.statement, metadata, scope, ctes, true);
        expr.preparedColumnAffinities =
            columns.map((column) => column.affinity).toList();
        expr.preparedColumnDeclaredTypes =
            columns.map((column) => column.declaredType).toList();
        if (expr.exists) {
          return CatalogColumn('', '', affinityOverride: 'none');
        }
        if (columns.length != 1) {
          throw SqlException(
              'sub-select returns ${columns.length} columns - expected 1');
        }
        return columns.single;
      }
      for (final child in expr.children) {
        expression(child);
      }
      String type = '';
      if (expr is CastExpr) {
        final declared = expr.type.toUpperCase();
        type = declared.contains('INT')
            ? 'INT'
            : ['CHAR', 'CLOB', 'TEXT'].any(declared.contains)
                ? 'TEXT'
                : declared.isEmpty || declared.contains('BLOB')
                    ? 'BLOB'
                    : ['REAL', 'FLOA', 'DOUB'].any(declared.contains)
                        ? 'REAL'
                        : 'NUM';
      }
      return CatalogColumn('', type,
          affinityOverride: expr.affinity(context),
          collation: expr.collation(context) ?? '');
    }

    final result = <CatalogColumn>[];
    for (final item in query.items) {
      if (item.expression == null) {
        final columns = item.label == '*'
            ? star
            : qualified[
                asciiLower(item.label.substring(0, item.label.length - 2))];
        if (columns == null) throw const SqlException('Unknown table wildcard');
        result.addAll(columns);
      } else {
        final column = expression(item.expression!);
        final operand = indexOperand(item.expression!);
        result.add(CatalogColumn(
            !item.explicitAlias && operand is ColumnExpr
                ? column.name
                : item.label,
            column.declaredType,
            affinityOverride: column.affinity,
            collation: column.collation));
      }
    }
    return result;
  }

  CatalogTable _pragmaTable(String name,
      [Map<String, (CatalogTable, List<RowValues>)>? metadata,
      Set<String>? loading]) {
    final key = asciiLower(name);
    metadata ??= {};
    loading ??= {};
    if (metadata.containsKey(key)) return metadata[key]!.$1;
    if (pragmaTableColumns.containsKey(key) &&
        !catalog.entries.any((entry) => asciiLower(entry.name) == key)) {
      return _pragmaSourceTable(QuerySource(table: name));
    }
    final entry = catalog.entries
        .where((e) => e.type == 'view' && asciiLower(e.name) == key)
        .firstOrNull;
    if (entry == null) {
      final table = catalog.table(name);
      // SQLite derives BLOB as the type of a view's untyped table column.
      final result = CatalogTable(
          table.name,
          table.rootPage,
          [
            for (final c in table.columns)
              CatalogColumn(
                  c.name, c.declaredType.isEmpty ? 'BLOB' : c.declaredType,
                  collation: c.collation)
          ],
          withoutRowid: table.withoutRowid,
          rowidAlias: table.rowidAlias);
      metadata[key] = (result, []);
      return result;
    }
    if (!loading.add(key)) throw const SqlException('Circular view');
    try {
      final parser = SqlParser(entry.sql!);
      parser.require('CREATE');
      parser.require('VIEW');
      if (parser.take('IF')) {
        parser.require('NOT');
        parser.require('EXISTS');
      }
      parser.identifier();
      final declared = <String>[];
      if (parser.take('(')) {
        do {
          declared.add(parser.identifier());
        } while (parser.take(','));
        parser.require(')');
      }
      parser.require('AS');
      final query = _pragmaMetadataQuery(parser.select());
      void prepare(SelectStatement query, [Set<String> inherited = const {}]) {
        final scope = {...inherited, ...query.ctes.keys};
        for (final c in query.ctes.values) {
          prepare(c.$2, scope);
        }
        for (final source in query.leafSources) {
          if (source.query != null) {
            prepare(source.query!, scope);
          } else if (source.schema != null ||
              !scope.contains(asciiLower(source.table!))) {
            final table = _pragmaTable(source.table!, metadata, loading);
            final value = metadata![asciiLower(source.table!)] ?? (table, []);
            metadata[asciiLower(source.table!)] = value;
            metadata['main.${asciiLower(source.table!)}'] = value;
          }
        }
        for (final expression in _expressions(query)) {
          for (final nested in _nested(expression)) {
            prepare(nested, scope);
          }
        }
        for (final part in query.compounds) {
          prepare(part.$2, scope);
        }
      }

      prepare(query);
      final result = _relational(query, const [], metadata, null);
      final columns = _pragmaColumnMetadata(query, metadata);
      final names =
          declared.isEmpty ? columns.map((c) => c.name).toList() : declared;
      if (names.length != result.columns.length) {
        throw const SqlException('View column width mismatch');
      }
      final unique = relationColumnNames(names);
      final table = CatalogTable(
          entry.name,
          0,
          [
            for (var i = 0; i < unique.length; i++)
              CatalogColumn(unique[i], columns[i].declaredType,
                  affinityOverride: columns[i].affinity,
                  collation: columns[i].collation)
          ],
          withoutRowid: true);
      metadata[key] = (table, []);
      return table;
    } finally {
      loading.remove(key);
    }
  }

  QueryResult _pragmaFunctions() {
    final rows = <List<Object?>>[];
    final window = {
      ...FunctionExpr.windowNames,
      'count',
      'sum',
      'total',
      'avg',
      'group_concat',
      'string_agg',
      'median',
      'percentile',
      'percentile_cont',
      'percentile_disc'
    };
    final variadic = {
      'concat': -3,
      'concat_ws': -4,
      'coalesce': -4,
      'if': -4,
      'iif': -4,
      'min': -3,
      'max': -3
    };
    void add(String name, String type, int count, int flags) => rows.add([
          name,
          BigInt.one,
          type,
          'utf8',
          BigInt.from(count),
          BigInt.from(flags)
        ]);
    for (final entry in FunctionExpr.builtinArities.entries) {
      final name = entry.key, range = entry.value;
      if (name == 'match') {
        rows.add(['match', BigInt.zero, 's', 'utf8', BigInt.two, BigInt.zero]);
        continue;
      }
      if (name == 'min' || name == 'max') {
        add(name, 'w', 1, 2097152);
        add(name, 's', variadic[name]!, 2099200);
        continue;
      }
      final type = window.contains(name) ? 'w' : 's';
      final flags = [
        'median',
        'percentile',
        'percentile_cont',
        'percentile_disc'
      ].contains(name)
          ? 0
          : type == 'w' ||
                  name.startsWith('current_') ||
                  [
                    'random',
                    'randomblob',
                    'changes',
                    'total_changes',
                    'last_insert_rowid'
                  ].contains(name)
              ? 2097152
              : 2099200;
      if (range.$2 >= 127) {
        add(name, type, variadic[name] ?? -1, flags);
      } else {
        for (var count = range.$1; count <= range.$2; count++) {
          add(name, type, count, flags);
        }
      }
    }
    for (final function in functions.registeredFunctions) {
      rows.add([
        asciiLower(function.name),
        BigInt.zero,
        function.aggregate == null ? 's' : 'a',
        'utf8',
        BigInt.from(function.argumentCount),
        BigInt.from(function.deterministic ? 2048 : 0)
      ]);
    }
    return QueryResult(
        ['name', 'builtin', 'type', 'enc', 'narg', 'flags'], rows);
  }

  Future<QueryResult> _pragma(SqlParser parser) async {
    var name = asciiLower(parser.identifier());
    if (parser.take('.')) {
      if (name != 'main') {
        throw SqlException('Unsupported database schema $name');
      }
      name = asciiLower(parser.identifier());
    }
    String? argument;
    if (parser.take('(')) {
      if ([SqlTokenKind.string, SqlTokenKind.number]
          .contains(parser.current.kind)) {
        argument = parser.current.text;
        parser.position++;
      } else {
        argument = parser.identifier();
      }
      parser.require(')');
    } else if (parser.take('=')) {
      argument = [SqlTokenKind.string, SqlTokenKind.number]
              .contains(parser.current.kind)
          ? parser.tokens[parser.position++].text
          : parser.identifier();
    }
    parser.finish();
    final header = _pager.header;
    final metadata = _readMetadataPragma(name, argument);
    if (metadata != null) return metadata;
    if (name == 'table_list') {
      final cols = ['schema', 'name', 'type', 'ncol', 'wr', 'strict'];
      final entries = [
        ...catalog.entries
            .where((e) => ['table', 'view'].contains(e.type))
            .toList()
            .reversed,
        CatalogEntry('table', 'sqlite_schema', 'sqlite_schema', 1, null)
      ];
      return QueryResult(cols, [
        for (final entry in entries)
          if (argument == null ||
              asciiLower(entry.name == 'sqlite_schema'
                      ? 'sqlite_master'
                      : entry.name) ==
                  asciiLower(argument))
            (() {
              final view = entry.type == 'view';
              final table =
                  view ? _pragmaTable(entry.name) : catalog.table(entry.name);
              return <Object?>[
                'main',
                entry.name,
                entry.type,
                BigInt.from(table.columns.length),
                boolean(!view && table.withoutRowid),
                boolean(!view && table.columns.any((c) => c.strict))
              ];
            })()
      ]);
    }
    if (['integrity_check', 'quick_check', 'foreign_key_check']
        .contains(name)) {
      if (_pager.pageCount * header.pageSize > 64 * 1024 * 1024) {
        throw const SqlException('Integrity image limit exceeded');
      }
      final image = Uint8List(_pager.pageCount * header.pageSize);
      for (var page = 1; page <= _pager.pageCount; page++) {
        image.setRange((page - 1) * header.pageSize, page * header.pageSize,
            await _pager.readPage(page));
      }
      if (name == 'foreign_key_check') {
        return (await ImageMutations.load(image)).foreignKeyCheck(argument);
      }
      if (argument != null &&
          (int.tryParse(argument) == null || int.parse(argument) <= 0)) {
        throw const SqlException(
            'Integrity check requires a positive error limit');
      }
      final errors =
          await ImageMutations.integrity(image, quick: name == 'quick_check');
      return QueryResult([
        name
      ], [
        for (final error
            in errors.take(argument == null ? 100 : int.parse(argument)))
          [error]
      ]);
    }
    final values = <String, Object?>{
      'page_size': BigInt.from(header.pageSize),
      'page_count': BigInt.from(_pager.pageCount),
      'freelist_count': BigInt.from(header.freelistPages),
      'schema_version': BigInt.from(header.schemaCookie.toSigned(32)),
      'user_version': BigInt.from(header.userVersion.toSigned(32)),
      'application_id': BigInt.from(header.applicationId.toSigned(32)),
      'foreign_keys': BigInt.zero,
      'recursive_triggers': BigInt.zero,
      'encoding': const [
        '',
        'UTF-8',
        'UTF-16le',
        'UTF-16be'
      ][header.textEncoding],
      'journal_mode': sqlJournalMode(header.writeVersion),
      'auto_vacuum': BigInt.from(header.autoVacuumMode),
    };
    if (values.containsKey(name) && argument == null) {
      return QueryResult([
        name
      ], [
        [values[name]]
      ]);
    }
    throw SqlException('Unsupported PRAGMA $name');
  }

  /// True when the first [items.length] order terms are exactly the selected
  /// expressions. Later terms only break ties, so equal projections are adjacent.
  bool _orderPrefixCovers(List<OrderTerm> order, List<SelectItem> items) {
    if (order.length < items.length || items.isEmpty) return false;
    final prefix = [
      for (final term in order.take(items.length)) term.expression
    ];
    final selected = [for (final item in items) item.expression!];
    bool covered(Expr expression, List<Expr> candidates) =>
        candidates.any((candidate) => sameExpression(expression, candidate));
    return selected.every((expression) => covered(expression, prefix)) &&
        prefix.every((expression) => covered(expression, selected));
  }

  bool _same(List<Object?> a, List<Object?> b, [List<String?>? collations]) {
    for (var i = 0; i < a.length; i++) {
      if (compareValues(
              a[i], b[i], _pager.header.textEncoding, collations?[i]) !=
          0) {
        return false;
      }
    }
    return true;
  }
}

class _ColumnBound {
  Object? lower;
  var lowerInclusive = false;
  var hasLower = false;
  Object? upper;
  var upperInclusive = false;
  var hasUpper = false;
  var empty = false;

  bool tighten(String op, Object? value, int encoding) {
    if (empty) return true;
    switch (op) {
      case '=':
      case '==':
        return _raise(value, true, encoding) && _cap(value, true, encoding);
      case '>':
        return _raise(value, false, encoding);
      case '>=':
        return _raise(value, true, encoding);
      case '<':
        return _cap(value, false, encoding);
      case '<=':
        return _cap(value, true, encoding);
      default:
        return false;
    }
  }

  bool _raise(Object? value, bool inclusive, int encoding) {
    if (hasLower && !_boundType(lower, value)) return false;
    if (!hasLower ||
        compareValues(value, lower, encoding) > 0 ||
        (compareValues(value, lower, encoding) == 0 &&
            lowerInclusive &&
            !inclusive)) {
      lower = value;
      lowerInclusive = inclusive;
      hasLower = true;
    }
    return _check(encoding);
  }

  bool _cap(Object? value, bool inclusive, int encoding) {
    if (hasUpper && !_boundType(upper, value)) return false;
    if (!hasUpper ||
        compareValues(value, upper, encoding) < 0 ||
        (compareValues(value, upper, encoding) == 0 &&
            upperInclusive &&
            !inclusive)) {
      upper = value;
      upperInclusive = inclusive;
      hasUpper = true;
    }
    return _check(encoding);
  }

  bool _check(int encoding) {
    if (hasLower && hasUpper && !_boundType(lower, upper)) return false;
    if (!hasLower || !hasUpper) return true;
    final comparison = compareValues(lower, upper, encoding);
    if (comparison > 0 ||
        (comparison == 0 && (!lowerInclusive || !upperInclusive))) {
      empty = true;
    }
    return true;
  }

  bool _boundType(Object? a, Object? b) {
    final numeric = a is num || a is BigInt;
    if (numeric) return b is num || b is BigInt;
    return a is String && b is String;
  }
}
