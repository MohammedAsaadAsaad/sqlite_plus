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
import 'windows.dart';
import 'virtual_table.dart';

part 'relational.dart';
part 'join_groups.dart';
part 'dml_subqueries.dart';
part 'lazy_views.dart';
part 'query_execution.dart';
part 'pragma_tables.dart';

final class QueryResult implements SqlRows {
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
  @override
  final List<String> columnAffinities;
  final List<String> columnDeclaredTypes;
  @override
  final List<String> columnCollations;
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
  SqliteDatabase._(this._pager, this.catalog, this._statistics,
      [SqlFunctionRegistry? registry])
      : functions = registry ?? SqlFunctionRegistry();
  final ReadOnlyPager _pager;
  final DatabaseCatalog catalog;
  final PlannerStatistics _statistics;
  final SqlFunctionRegistry functions;
  bool _closed = false;
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

  QueryPlan _plan(
      SelectStatement statement, CatalogTable? table, List<Object?> bound) {
    if (table == null) return const QueryPlan('constant', null, null);
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
      if (rowBounds.isNotEmpty && forced == null) {
        return QueryPlan._indexed(
            table.rootPage,
            _IndexAccess('@rowid',
                (values) => comparison(values.single, rowBounds, 'binary'),
                table: true, empty: rowBounds.any((b) => b.$2 == null)),
            'rowid-range');
      }
      if (notIndexed) {
        return QueryPlan('table-scan', table.rootPage, null);
      }
      QueryPlan? best;
      var bestScore = -1;
      double? bestEstimate;
      for (final entry in catalog.entries.where((e) =>
          e.type == 'index' &&
          asciiLower(e.tableName) == asciiLower(table.name) &&
          (forced == null || asciiLower(e.name) == asciiLower(forced.name)))) {
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
          final rangeTerms = range ? prefix.last : <(String, Object?)>[];
          final rangeBounds =
              (rangeTerms.any((bound) => ['>', '>='].contains(bound.$1))
                      ? 1
                      : 0) +
                  (rangeTerms.any((bound) => ['<', '<='].contains(bound.$1))
                      ? 1
                      : 0);
          final estimate = _statistics.estimate(table.name, entry.name,
              columns: definition.$1.length,
              equalities: prefix.length - (range ? 1 : 0),
              rangeBounds: rangeBounds,
              unique: definition.$5);
          if (best == null ||
              estimate != null &&
                  bestEstimate != null &&
                  estimate < bestEstimate ||
              (estimate == bestEstimate ||
                      estimate == null ||
                      bestEstimate == null) &&
                  score > bestScore) {
            bestScore = score;
            bestEstimate = estimate;
            best = QueryPlan._indexed(entry.rootPage, access,
                range ? 'secondary-index-range' : 'secondary-index-lookup');
          }
        } on Exception {
          continue;
        }
      }
      if (best != null) return best;
    }
    if (forced != null) {
      return QueryPlan._indexed(forced.rootPage,
          _IndexAccess(forced.name, (_) => 0), 'secondary-index-scan');
    }
    return QueryPlan(table.withoutRowid ? 'index-tree-scan' : 'table-scan',
        table.rootPage, null);
  }

  Stream<BtreeRecord> _planRecords(CatalogTable table, QueryPlan plan) async* {
    if (plan.access == 'virtual-table-scan') {
      yield* Stream<BtreeRecord>.fromIterable(VirtualTableRows.records(table));
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
          ? reader.scanIndex(table.rootPage)
          : reader.scanTable(table.rootPage);
      return;
    }
    if (access.empty) return;
    if (access.table) {
      yield* reader.seekTable(
          plan.rootPage!, (rowid) => access.compare([rowid]));
      return;
    }
    if (!table.withoutRowid) {
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
      return;
    }
    if (plan.rootPage == table.rootPage) {
      yield* reader.scanIndex(table.rootPage);
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
    await for (final indexed
        in reader.seekIndex(plan.rootPage!, access.compare)) {
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
    return (await _prepareQuery(sql, parameters, outer)).materialize();
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
      [EvalContext? outer]) async {
    if (_closed) throw StateError('Database is closed');
    final statement = SqlParser(sql).select();
    if (parameters.length != statement.parameterCount) {
      throw const SqlException('Incorrect parameter count');
    }
    final bound = parameters.map(sqlValue).toList();
    if (outer != null || _needsRelational(statement)) {
      final cache = <String, (CatalogTable, List<RowValues>)>{};
      await _loadRelations(statement, cache, <String>{});
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
    final table =
        statement.table == null ? null : catalog.table(statement.table!);
    final columns = table?.columns ?? <CatalogColumn>[];
    final input = <RowValues>[];
    if (table == null) {
      input.add({});
    } else {
      final plan = _plan(statement, table, bound);
      final stream = _planRecords(table, plan);
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
        table.evaluateGenerated(row, _pager.header.textEncoding, lazy: true);
        input.add(row);
      }
    }
    final scanOrder =
        table == null ? null : _physicalScanOrder(statement, table);
    if (scanOrder != null) _sortPhysicalRows(input, scanOrder);
    return _evaluate(statement, bound, table, input,
        inputOrdered: scanOrder != null);
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
      bool omitProjection = false}) {
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
        items
            .addAll(columns.map((c) => SelectItem(ColumnExpr(c.name), c.name)));
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
      if (limit == 0) return;
      final selected = input.where((row) {
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
      final filtered = windowed && !aggregate ? selected.toList() : selected;
      final groups = <(List<Object?>, Iterable<RowValues>)>[];
      if (aggregate && groupBy.isEmpty) {
        groups.add(([], filtered));
      } else if (aggregate) {
        final groupCollations =
            groupBy.map((expr) => expr.collation(constantContext)).toList();
        for (final row in filtered) {
          final ctx =
              EvalContext(row, affinities, bound, _pager.header.textEncoding)
                ..inTrigger = inTrigger
                ..subquery = subquery
                ..collations = collations;
          final keys = groupBy.map((expr) => expr.evaluate(ctx)).toList();
          final index = groups
              .indexWhere((group) => _same(group.$1, keys, groupCollations));
          if (index < 0) {
            groups.add((keys, <RowValues>[row]));
          } else {
            (groups[index].$2 as List<RowValues>).add(row);
          }
        }
        groups.sort((a, b) {
          for (var i = 0; i < groupBy.length; i++) {
            final comparison = compareValues(a.$1[i], b.$1[i],
                _pager.header.textEncoding, groupCollations[i]);
            if (comparison != 0) return comparison;
          }
          return 0;
        });
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
            groupRows.add(candidate);
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
            var worst = 0;
            for (var i = 1; i < output.length; i++) {
              if (compareKeys(output[i].$2, output[worst].$2) >= 0) worst = i;
            }
            if (compareKeys(candidateKeys, output[worst].$2) >= 0) continue;
            output.removeAt(worst);
          }
        }
        for (var i = 0; i < items.length; i++) {
          project(i);
        }
        if (distinct &&
            output.any((entry) => _same(
                entry.$1,
                values,
                items
                    .map((item) => item.expression!.collation(ctx))
                    .toList()))) {
          continue;
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
        output.add((values, keys, sequence++));
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
          throw const SqlException('Scalar subquery must return one column');
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
