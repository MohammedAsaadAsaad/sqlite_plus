import 'dart:typed_data';
import '../btree/btree_reader.dart';
import '../pager/read_only_pager.dart';
import '../storage/storage_backend.dart';
import 'catalog.dart';
import 'parser.dart';
import 'functions.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'expressions.dart';
import 'function_registry.dart';
import 'image_mutations.dart';
import 'index_definition.dart';

part 'relational.dart';

final class QueryResult implements SqlRows {
  QueryResult(List<String> columns, List<List<Object?>> rows,
      [List<String>? affinities])
      : columnAffinities = List.unmodifiable(
            affinities ?? List.filled(columns.length, 'none')),
        columns = List.unmodifiable(columns),
        rows = List.unmodifiable(rows.map(List<Object?>.unmodifiable));
  @override
  final List<String> columnAffinities;
  @override
  final List<String> columns;
  @override
  final List<List<Object?>> rows;
}

final class QueryPlan {
  const QueryPlan(this.access, this.rootPage, this.rowid) : _index = null;
  const QueryPlan._indexed(this.rootPage, this._index, this.access)
      : rowid = null;
  final _IndexAccess? _index;
  String? get indexName => _index?.table == false ? _index?.name : null;
  final String access;
  final int? rootPage;
  final BigInt? rowid;
}

final class _IndexAccess {
  _IndexAccess(this.name, this.compare,
      {this.table = false, this.empty = false});
  final String name;
  final int Function(List<Object?>) compare;
  final bool table, empty;
}

/// M3 read-only single-table SELECT API. Unsupported SQL fails explicitly.
final class SqliteDatabase {
  SqliteDatabase._(this._pager, this.catalog, [SqlFunctionRegistry? registry])
      : functions = registry ?? SqlFunctionRegistry();
  final ReadOnlyPager _pager;
  final DatabaseCatalog catalog;
  final SqlFunctionRegistry functions;
  bool _closed = false;
  static Future<SqliteDatabase> openReadOnly(StorageBackend storage,
      {SqlFunctionRegistry? functions}) async {
    final pager = await ReadOnlyPager.open(storage);
    try {
      return SqliteDatabase._(
          pager, await DatabaseCatalog.read(pager), functions);
    } catch (_) {
      await pager.close();
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    await _pager.close();
  }

  bool _planningConstant(Expr expression) {
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

  QueryPlan _plan(
      SelectStatement statement, CatalogTable? table, List<Object?> bound) {
    if (table == null) return const QueryPlan('constant', null, null);
    if (!table.withoutRowid) {
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
      if (key != null) return QueryPlan('rowid-lookup', table.rootPage, key);
    }
    if (!table.withoutRowid) {
      final constraints = <BinaryExpr>[];
      void collect(Expr? expr) {
        if (expr is BinaryExpr && expr.op == 'AND') {
          collect(expr.left);
          collect(expr.right);
        } else if (expr is BinaryExpr &&
            ['=', '==', '<', '<=', '>', '>='].contains(expr.op)) {
          constraints.add(expr);
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
      if (rowBounds.isNotEmpty) {
        return QueryPlan._indexed(
            table.rootPage,
            _IndexAccess('@rowid',
                (values) => comparison(values.single, rowBounds, 'binary'),
                table: true, empty: rowBounds.any((b) => b.$2 == null)),
            'rowid-range');
      }
      QueryPlan? best;
      var bestScore = -1;
      for (final entry in catalog.entries.where((e) =>
          e.type == 'index' &&
          asciiLower(e.tableName) == asciiLower(table.name))) {
        try {
          final parsed = entry.sql == null
              ? null
              : IndexDefinition.parse(entry.sql!, table);
          if (!impliesIndexPredicate(statement.where, parsed?.predicate)) {
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
          if (prefix.isEmpty) continue;
          final access = _IndexAccess(entry.name, (values) {
            if (values.length <= prefix.length) {
              throw const FormatException('Short secondary index key');
            }
            for (var i = 0; i < prefix.length; i++) {
              final c = comparison(values[i], prefix[i], definition.$3[i]);
              if (c != 0) return definition.$2[i] ? -c : c;
            }
            return 0;
          },
              empty:
                  prefix.any((list) => list.any((bound) => bound.$2 == null)));
          final score = prefix.length * 10 + (definition.$5 && !range ? 1 : 0);
          if (score > bestScore) {
            bestScore = score;
            best = QueryPlan._indexed(entry.rootPage, access,
                range ? 'secondary-index-range' : 'secondary-index-lookup');
          }
        } on Exception {
          continue;
        }
      }
      if (best != null) return best;
    }
    return QueryPlan(table.withoutRowid ? 'index-tree-scan' : 'table-scan',
        table.rootPage, null);
  }

  QueryPlan explain(String sql, [List<Object?> parameters = const []]) =>
      functions.run(() => _explain(sql, parameters));
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

  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      functions.run(() => _query(sql, parameters));
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
    final statement = SqlParser(sql).select();
    if (parameters.length != statement.parameterCount) {
      throw const SqlException('Incorrect parameter count');
    }
    final bound = parameters.map(sqlValue).toList();
    if (outer != null || _needsRelational(statement)) {
      final cache = <String, (CatalogTable, List<RowValues>)>{};
      await _loadRelations(statement, cache, <String>{});
      return _relational(statement, bound, cache, outer);
    }
    final table =
        statement.table == null ? null : catalog.table(statement.table!);
    final columns = table?.columns ?? <CatalogColumn>[];
    final input = <RowValues>[];
    if (table == null) {
      input.add({});
    } else {
      final reader = BtreeReader(_pager);
      final plan = _plan(statement, table, bound);
      Stream<BtreeRecord> point() async* {
        final record = await reader.findRowid(table.rootPage, plan.rowid!);
        if (record != null) yield record;
      }

      Stream<BtreeRecord> indexed() async* {
        final access = plan._index!;
        if (access.empty) return;
        if (access.table) {
          yield* reader.seekTable(
              plan.rootPage!, (rowid) => access.compare([rowid]));
          return;
        }
        await for (final entry
            in reader.seekIndex(plan.rootPage!, access.compare)) {
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
      }

      final stream = plan.access == 'rowid-lookup'
          ? point()
          : plan._index != null
              ? indexed()
              : table.withoutRowid
                  ? reader.scanIndex(table.rootPage)
                  : reader.scanTable(table.rootPage);
      final stored = table.storageColumns;
      await for (final record in stream) {
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
        input.add(row);
      }
    }
    return _evaluate(statement, bound, table, input);
  }

  QueryResult _evaluate(SelectStatement statement, List<Object?> bound,
      CatalogTable? table, List<RowValues> input,
      {SqlRows Function(SelectStatement, EvalContext)? subquery,
      bool inTrigger = false}) {
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
        items
            .addAll(columns.map((c) => SelectItem(ColumnExpr(c.name), c.name)));
      } else {
        items.add(item);
      }
    }
    for (final item in items) {
      item.expression!.validate(names);
    }
    statement.where?.validate(names);
    if ((statement.where?.containsAggregate ?? false) ||
        (statement.where?.containsWindow ?? false)) {
      throw const SqlException('Aggregate in WHERE');
    }
    final groupBy = <Expr>[];
    final aliasExpressions = {
      for (final item in items) asciiLower(item.label): item.expression!
    };
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
          aliasExpressions.containsKey(expr.key)) {
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
        statement.order.any((term) => term.expression.containsAggregate) ||
        (statement.having?.containsAggregate ?? false);
    if (statement.having != null && !aggregate) {
      throw const SqlException('HAVING requires aggregate query');
    }
    statement.having?.validate({...names, ...aliasExpressions.keys});
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

    final orderSlots =
        statement.order.map((term) => projectionSlot(term.expression)).toList();
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
        EvalContext({}, {}, bound, _pager.header.textEncoding)
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

    final limit = count(statement.limit);
    final offset = count(statement.offset) ?? 0;
    if (limit == 0) return QueryResult(_labels(items, columns, table), []);
    final filtered = input.where((row) {
      final ctx =
          EvalContext(row, affinities, bound, _pager.header.textEncoding)
            ..inTrigger = inTrigger
            ..subquery = subquery
            ..collations = collations;
      return statement.where == null ||
          truth(statement.where!.evaluate(ctx), _pager.header.textEncoding) ==
              true;
    }).toList();
    final groups = <(List<Object?>, List<RowValues>)>[];
    if (aggregate && groupBy.isEmpty) {
      groups.add(([], filtered));
    } else {
      for (final row in filtered) {
        final ctx =
            EvalContext(row, affinities, bound, _pager.header.textEncoding)
              ..inTrigger = inTrigger
              ..subquery = subquery
              ..collations = collations;
        final keys = groupBy.map((expr) => expr.evaluate(ctx)).toList();
        if (!aggregate) {
          groups.add((keys, [row]));
          continue;
        }
        final index = groups.indexWhere((group) => _same(group.$1, keys,
            groupBy.map((expr) => expr.collation(constantContext)).toList()));
        if (index < 0) {
          groups.add((keys, [row]));
        } else {
          groups[index].$2.add(row);
        }
      }
    }
    final windowed = items.any((item) => item.expression!.containsWindow) ||
        statement.order.any((term) => term.expression.containsWindow);
    final windowGroups = <RowValues, List<RowValues>>{};
    final windowAggregates = <RowValues, Map<Expr, Object?>>{};
    Iterable<EvalContext> prepare() sync* {
      for (final group in groups) {
        var row = group.$2.isEmpty
            ? <String, Object?>{for (final name in names) name: null}
            : group.$2.first;
        final extrema = items
            .expand((item) => aggregateFunctions(item.expression!))
            .where((fn) => ['min', 'max'].contains(fn.key))
            .toList();
        if (aggregate && extrema.length == 1 && group.$2.isNotEmpty) {
          final fn = extrema.single;
          Object? best;
          row = group.$2.last;
          for (final candidate in group.$2) {
            final context = EvalContext(
                candidate, affinities, bound, _pager.header.textEncoding)
              ..inTrigger = inTrigger
              ..subquery = subquery
              ..collations = collations;
            if (fn.filter != null &&
                truth(fn.filter!.evaluate(context), context.encoding) != true) {
              continue;
            }
            final value = fn.arguments.single.evaluate(context);
            if (value == null) continue;
            final comparison = best == null
                ? 0
                : compareValues(value, best, _pager.header.textEncoding,
                    fn.arguments.single.collation(context));
            if (best == null ||
                (fn.key == 'min' ? comparison < 0 : comparison > 0)) {
              best = value;
              row = candidate;
            }
          }
        }
        row = {...row};
        final ctx =
            EvalContext(row, affinities, bound, _pager.header.textEncoding)
              ..group = aggregate ? group.$2 : null
              ..windowRows = filtered
              ..windowRow = group.$2.isEmpty ? null : group.$2.first
              ..windowCache = windowCache
              ..inTrigger = inTrigger
              ..subquery = subquery
              ..collations = collations;
        if (aggregate) {
          for (final expr in [
            ...items.map((item) => item.expression!),
            if (statement.having != null) statement.having!,
            ...statement.order.map((term) => term.expression)
          ]) {
            for (final function in aggregateFunctions(expr)) {
              ctx.aggregateValues[function] = function.evaluate(ctx);
            }
          }
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

    final prepared = windowed ? prepare().toList() : prepare();
    final windowRows =
        windowed ? prepared.map((ctx) => ctx.row).toList() : <RowValues>[];
    final output = <(List<Object?>, List<Object?>, int)>[];
    for (final ctx in prepared) {
      final row = ctx.row;
      ctx.windowRows = windowRows;
      ctx.windowRow = row;
      ctx.windowGroups = windowGroups;
      ctx.windowAggregates = windowAggregates;
      final values =
          items.map((item) => item.expression!.evaluate(ctx)).toList();
      if (statement.distinct &&
          output.any((entry) => _same(entry.$1, values,
              items.map((item) => item.expression!.collation(ctx)).toList()))) {
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
      final keys = <Object?>[];
      for (var i = 0; i < statement.order.length; i++) {
        final slot = orderSlots[i];
        keys.add(slot >= 0
            ? values[slot]
            : statement.order[i].expression.evaluate(orderCtx));
      }
      output.add((values, keys, output.length));
    }
    final sortTerms = [
      for (var i = 0; i < statement.order.length; i++)
        OrderTerm(
            CollateExpr(
                statement.order[i].expression,
                statement.order[i].expression
                        .explicitCollation(constantContext) ??
                    (orderSlots[i] >= 0
                        ? items[orderSlots[i]]
                            .expression!
                            .collation(constantContext)
                        : statement.order[i].expression
                            .collation(constantContext)) ??
                    'binary'),
            statement.order[i].descending,
            statement.order[i].nullsFirst)
    ];
    output.sort((a, b) {
      for (var i = 0; i < statement.order.length; i++) {
        final comparison =
            sortTerms[i].compare(a.$2[i], b.$2[i], constantContext);
        if (comparison != 0) return comparison;
      }
      return a.$3.compareTo(b.$3);
    });
    var rows = output.map((entry) => entry.$1).skip(offset < 0 ? 0 : offset);
    if (limit != null && limit >= 0) rows = rows.take(limit);
    return QueryResult(
        _labels(items, columns, table),
        rows.toList(),
        items
            .map((item) => item.expression!.affinity(constantContext))
            .toList());
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
      final columns = keys
          .map((name) => table.columns
              .firstWhere((c) => asciiLower(c.name) == asciiLower(name)))
          .toList();
      final primary = columns.every((c) => c.primaryKey != 0) &&
          columns.length ==
              table.columns.where((c) => c.primaryKey != 0).length;
      return (
        keys,
        columns.map((c) => c.primaryDescending).toList(),
        columns.map((c) => c.collation).toList(),
        primary ? 'pk' : 'u',
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

  Future<QueryResult> _pragma(SqlParser parser) async {
    final name = asciiLower(parser.identifier());
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
    }
    parser.finish();
    final header = _pager.header;
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
      'encoding': const [
        '',
        'UTF-8',
        'UTF-16le',
        'UTF-16be'
      ][header.textEncoding],
    };
    if (values.containsKey(name) && argument == null) {
      return QueryResult([
        name
      ], [
        [values[name]]
      ]);
    }
    if (name == 'foreign_key_list' && argument != null) {
      final cols = [
        'id',
        'seq',
        'table',
        'from',
        'to',
        'on_update',
        'on_delete',
        'match'
      ];
      final entry = catalog.entries
          .where((e) =>
              e.type == 'table' && asciiLower(e.name) == asciiLower(argument!))
          .firstOrNull;
      if (entry == null) return QueryResult(cols, []);
      final keys = catalog.table(argument).foreignKeys.reversed.toList();
      return QueryResult(cols, [
        for (var i = 0; i < keys.length; i++)
          for (var j = 0; j < keys[i].columns.length; j++)
            [
              BigInt.from(i),
              BigInt.from(j),
              keys[i].table,
              keys[i].columns[j],
              keys[i].targetColumns.isEmpty ? null : keys[i].targetColumns[j],
              keys[i].onUpdate,
              keys[i].onDelete,
              'NONE'
            ]
      ]);
    }
    if (name == 'index_list' && argument != null) {
      final cols = ['seq', 'name', 'unique', 'origin', 'partial'];
      final tableEntry = catalog.entries
          .where((e) =>
              e.type == 'table' && asciiLower(e.name) == asciiLower(argument!))
          .firstOrNull;
      if (tableEntry == null) return QueryResult(cols, []);
      final table = catalog.table(argument);
      final entries = catalog.entries
          .where((e) =>
              e.type == 'index' &&
              asciiLower(e.tableName) == asciiLower(argument!))
          .toList();
      if (table.withoutRowid) {
        final pk = table.columns
            .where((c) => c.primaryKey != 0)
            .map((c) => asciiLower(c.name))
            .toSet();
        final ordinal = table.autoIndexKeys.indexWhere((key) =>
            key.length == pk.length &&
            key.map(asciiLower).toSet().containsAll(pk));
        entries.add(CatalogEntry(
            'index',
            'sqlite_autoindex_${table.name}_${ordinal + 1}',
            table.name,
            table.rootPage,
            null));
        entries.sort((a, b) => a.sql == null && b.sql == null
            ? a.name.compareTo(b.name)
            : catalog.entries.indexOf(a).compareTo(catalog.entries.indexOf(b)));
      }
      final reversed = entries.reversed.toList();
      return QueryResult(cols, [
        for (var i = 0; i < reversed.length; i++)
          [
            BigInt.from(i),
            reversed[i].name,
            boolean(_indexDefinition(reversed[i]).$5),
            _indexDefinition(reversed[i]).$4,
            boolean(reversed[i].sql != null &&
                SqlParser(reversed[i].sql!)
                    .tokens
                    .any((t) => t.keyword == 'WHERE'))
          ]
      ]);
    }
    if (['index_info', 'index_xinfo'].contains(name) && argument != null) {
      final extended = name == 'index_xinfo';
      final cols = [
        'seqno',
        'cid',
        'name',
        if (extended) ...['desc', 'coll', 'key']
      ];
      final entry = catalog.entries
          .where((e) =>
              e.type == 'index' && asciiLower(e.name) == asciiLower(argument!))
          .firstOrNull;
      if (entry == null) return QueryResult(cols, []);
      final definition = _indexDefinition(entry);
      final table = catalog.table(entry.tableName);
      final keys = definition.$1.toList();
      final descending = definition.$2.toList();
      final collations = definition.$3.toList();
      final keyCount = keys.length;
      final expressions = entry.sql == null
          ? <int>{}
          : {
              for (var i = 0; i < keyCount; i++)
                if (IndexDefinition.parse(entry.sql!, table)
                        .terms[i]
                        .columnName ==
                    null)
                  i
            };
      if (extended) {
        if (!table.withoutRowid) {
          keys.add('');
          descending.add(false);
          collations.add('binary');
        } else {
          final pk = table.columns.where((c) => c.primaryKey != 0).toList()
            ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
          for (final col in pk) {
            if (!List.generate(
                keyCount,
                (i) =>
                    !expressions.contains(i) &&
                    asciiLower(keys[i]) == asciiLower(col.name) &&
                    collations[i] == col.collation).any((v) => v)) {
              keys.add(col.name);
              descending.add(col.primaryDescending);
              collations.add(col.collation);
            }
          }
        }
      }
      return QueryResult(cols, [
        for (var i = 0; i < keys.length; i++)
          [
            BigInt.from(i),
            BigInt.from(expressions.contains(i)
                ? -2
                : i >= keyCount && !table.withoutRowid
                    ? -1
                    : table.columns.indexWhere(
                        (c) => asciiLower(c.name) == asciiLower(keys[i]))),
            expressions.contains(i) || i >= keyCount && !table.withoutRowid
                ? null
                : keys[i],
            if (extended) ...[
              boolean(descending[i]),
              collations[i].toUpperCase(),
              boolean(i < keyCount)
            ]
          ]
      ]);
    }
    if (['table_info', 'table_xinfo'].contains(name) && argument != null) {
      final cols = [
        'cid',
        'name',
        'type',
        'notnull',
        'dflt_value',
        'pk',
        if (name == 'table_xinfo') 'hidden'
      ];
      final exists =
          ['sqlite_schema', 'sqlite_master'].contains(asciiLower(argument)) ||
              catalog.entries.any((entry) =>
                  asciiLower(entry.name) == asciiLower(argument!) &&
                  entry.type == 'table');
      if (!exists) return QueryResult(cols, []);
      final table = catalog.table(argument);
      return QueryResult(cols, [
        for (var i = 0; i < table.columns.length; i++)
          [
            BigInt.from(i),
            table.columns[i].name,
            table.columns[i].declaredType,
            boolean(table.columns[i].notNull ||
                (table.withoutRowid ||
                        table.columns[i].strict &&
                            table.columns[i].name != table.rowidAlias) &&
                    table.columns[i].primaryKey != 0),
            table.columns[i].defaultSql,
            BigInt.from(table.columns[i].primaryKey),
            if (name == 'table_xinfo') BigInt.zero
          ]
      ]);
    }
    throw SqlException('Unsupported PRAGMA $name');
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
