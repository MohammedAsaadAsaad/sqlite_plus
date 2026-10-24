import '../btree/btree_reader.dart';
import '../pager/read_only_pager.dart';
import '../storage/storage_backend.dart';
import 'catalog.dart';
import 'parser.dart';
import 'functions.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'expressions.dart';

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
  const QueryPlan._indexed(this.rootPage, this._index)
      : access = 'secondary-index-lookup',
        rowid = null;
  final _IndexAccess? _index;
  final String access;
  final int? rootPage;
  final BigInt? rowid;
}

final class _IndexAccess {
  _IndexAccess(this.name, this.value, this.collation, this.descending);
  final String name, collation;
  final Object? value;
  final bool descending;
}

/// M3 read-only single-table SELECT API. Unsupported SQL fails explicitly.
final class SqliteDatabase {
  SqliteDatabase._(this._pager, this.catalog);
  final ReadOnlyPager _pager;
  final DatabaseCatalog catalog;
  bool _closed = false;
  static Future<SqliteDatabase> openReadOnly(StorageBackend storage) async {
    final pager = await ReadOnlyPager.open(storage);
    try {
      return SqliteDatabase._(pager, await DatabaseCatalog.read(pager));
    } catch (_) {
      await pager.close();
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    await _pager.close();
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
        if (constant.containsAggregate) return null;
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
      final equalities = <BinaryExpr>[];
      void collect(Expr? expr) {
        if (expr is BinaryExpr && expr.op == 'AND') {
          collect(expr.left);
          collect(expr.right);
        } else if (expr is BinaryExpr && ['=', '=='].contains(expr.op)) {
          equalities.add(expr);
        }
      }

      collect(statement.where);
      for (final entry in catalog.entries.where((e) =>
          e.type == 'index' &&
          asciiLower(e.tableName) == asciiLower(table.name))) {
        try {
          String name, collation;
          bool descending = false;
          if (entry.sql == null) {
            final suffix = int.parse(entry.name.split('_').last) - 1;
            name = table.autoIndexKeys[suffix].first;
            final column = table.columns
                .firstWhere((c) => asciiLower(c.name) == asciiLower(name));
            collation = column.collation;
            descending = column.primaryDescending;
          } else {
            final p = SqlParser(entry.sql!);
            p.require('CREATE');
            p.take('UNIQUE');
            p.require('INDEX');
            if (p.take('IF')) {
              p.require('NOT');
              p.require('EXISTS');
            }
            p.identifier();
            p.require('ON');
            p.identifier();
            p.require('(');
            name = p.identifier();
            final column = table.columns
                .firstWhere((c) => asciiLower(c.name) == asciiLower(name));
            collation = p.take('COLLATE')
                ? asciiLower(p.identifier())
                : column.collation;
            descending = p.take('DESC');
            // Partial and expression indexes require predicate implication first.
            if (p.tokens.any((t) => t.keyword == 'WHERE') ||
                ![',', ')', 'ASC'].contains(p.current.text.toUpperCase())) {
              continue;
            }
          }
          final column = table.columns
              .firstWhere((c) => asciiLower(c.name) == asciiLower(name));
          if (collation != column.collation) continue;
          for (final equality in equalities) {
            Expr? constant;
            if (equality.left is ColumnExpr &&
                (equality.left as ColumnExpr).key == asciiLower(name)) {
              constant = equality.right;
            } else if (equality.right is ColumnExpr &&
                (equality.right as ColumnExpr).key == asciiLower(name)) {
              constant = equality.left;
            }
            if (constant == null || constant.containsAggregate) continue;
            try {
              constant.validate({});
            } on SqlException {
              continue;
            }
            if (column.affinity == 'text' &&
                constant.affinity(EvalContext({}, {}, bound)) == 'numeric') {
              continue;
            }
            final explicit =
                constant.explicitCollation(EvalContext({}, {}, bound));
            if (explicit != null && explicit != collation) continue;
            final value = applyAffinity(
                constant.evaluate(
                    EvalContext({}, {}, bound, _pager.header.textEncoding)),
                column.affinity);
            return QueryPlan._indexed(entry.rootPage,
                _IndexAccess(entry.name, value, collation, descending));
          }
        } on Exception {
          continue;
        }
      }
    }
    return QueryPlan(table.withoutRowid ? 'index-tree-scan' : 'table-scan',
        table.rootPage, null);
  }

  QueryPlan explain(String sql, [List<Object?> parameters = const []]) {
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
      _query(sql, parameters);
  Future<QueryResult> queryWithContext(
          String sql, List<Object?> parameters, EvalContext context) =>
      _query(sql, parameters, context);
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
        if (access.value == null) return;
        await for (final entry in reader.seekIndex(plan.rootPage!, (values) {
          if (values.isEmpty) {
            throw const FormatException('Empty secondary index key');
          }
          final comparison = compareValues(values.first, access.value,
              _pager.header.textEncoding, access.collation);
          return access.descending ? -comparison : comparison;
        })) {
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
      {SqlRows Function(SelectStatement, EvalContext)? subquery}) {
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
      if (expr is Literal && expr.value is BigInt) {
        final ordinal = expr.value as BigInt;
        if (ordinal < BigInt.one || ordinal > BigInt.from(items.length)) {
          throw const SqlException('GROUP BY index out of range');
        }
        expr = items[ordinal.toInt() - 1].expression!;
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
    final windows = items.any((item) => item.expression!.containsWindow) ||
        statement.order.any((term) => term.expression.containsWindow);
    if ((statement.having?.containsWindow ?? false) || aggregate && windows) {
      throw const SqlException('Grouped window queries unsupported');
    }
    final windowCache = <Expr, Object>{};

    for (final term in statement.order) {
      final expr = term.expression;
      if (expr is Literal &&
          expr.value is BigInt &&
          ((expr.value as BigInt) < BigInt.one ||
              (expr.value as BigInt) > BigInt.from(items.length))) {
        throw const SqlException('ORDER BY index out of range');
      }
    }
    final aliases = items.map((item) => asciiLower(item.label)).toSet();
    for (final term in statement.order) {
      term.expression.validate({...names, ...aliases});
    }
    statement.limit?.validate({});
    statement.offset?.validate({});
    final constantContext =
        EvalContext({}, {}, bound, _pager.header.textEncoding)
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
    final output = <(List<Object?>, List<Object?>, int)>[];
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
      final values =
          items.map((item) => item.expression!.evaluate(ctx)).toList();
      for (var i = 0; i < items.length; i++) {
        final name = asciiLower(items[i].label);
        if (!names.contains(name)) row[name] = values[i];
      }
      if (statement.having != null &&
          truth(statement.having!.evaluate(ctx), _pager.header.textEncoding) !=
              true) {
        continue;
      }
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
            ..group = aggregate ? group.$2 : null
            ..windowRows = filtered
            ..windowRow = group.$2.isEmpty ? null : group.$2.first
            ..windowCache = windowCache
            ..subquery = subquery
            ..collations = collations;
      orderCtx.aggregateValues.addAll(ctx.aggregateValues);
      final keys = <Object?>[];
      for (final term in statement.order) {
        final expr = term.expression;
        if (expr is Literal && expr.value is BigInt) {
          final ordinal = expr.value as BigInt;
          if (ordinal < BigInt.one || ordinal > BigInt.from(values.length)) {
            throw const SqlException('ORDER BY index out of range');
          }
          keys.add(values[ordinal.toInt() - 1]);
        } else {
          keys.add(expr.evaluate(orderCtx));
        }
      }
      output.add((values, keys, output.length));
    }
    output.sort((a, b) {
      for (var i = 0; i < statement.order.length; i++) {
        final comparison =
            statement.order[i].compare(a.$2[i], b.$2[i], constantContext);
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
    final p = SqlParser(entry.sql!);
    p.require('CREATE');
    final unique = p.take('UNIQUE');
    p.require('INDEX');
    if (p.take('IF')) {
      p.require('NOT');
      p.require('EXISTS');
    }
    p.identifier();
    p.require('ON');
    p.identifier();
    p.require('(');
    final keys = <String>[];
    final descending = <bool>[];
    final collations = <String>[];
    do {
      final name = p.identifier();
      final col = table.columns
          .firstWhere((c) => asciiLower(c.name) == asciiLower(name));
      keys.add(col.name);
      collations
          .add(p.take('COLLATE') ? asciiLower(p.identifier()) : col.collation);
      final desc = p.take('DESC');
      if (!desc) p.take('ASC');
      descending.add(desc);
    } while (p.take(','));
    p.require(')');
    return (keys, descending, collations, 'c', unique);
  }

  QueryResult _pragma(SqlParser parser) {
    final name = asciiLower(parser.identifier());
    String? argument;
    if (parser.take('(')) {
      if (parser.current.kind == SqlTokenKind.string) {
        argument = parser.current.text;
        parser.position++;
      } else {
        argument = parser.identifier();
      }
      parser.require(')');
    }
    parser.finish();
    final header = _pager.header;
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
      if (extended) {
        if (!table.withoutRowid) {
          keys.add('');
          descending.add(false);
          collations.add('binary');
        } else {
          final pk = table.columns.where((c) => c.primaryKey != 0).toList()
            ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
          for (final col in pk) {
            if (!keys.any((key) => asciiLower(key) == asciiLower(col.name))) {
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
            BigInt.from(keys[i].isEmpty
                ? -1
                : table.columns.indexWhere(
                    (c) => asciiLower(c.name) == asciiLower(keys[i]))),
            keys[i].isEmpty ? null : keys[i],
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
