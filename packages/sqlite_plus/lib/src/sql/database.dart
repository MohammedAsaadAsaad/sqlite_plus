import '../btree/btree_reader.dart';
import '../pager/read_only_pager.dart';
import '../storage/storage_backend.dart';
import 'catalog.dart';
import 'parser.dart';
import 'functions.dart';
import 'tokenizer.dart';
import 'values.dart';

final class QueryResult {
  QueryResult(List<String> columns, List<List<Object?>> rows)
      : columns = List.unmodifiable(columns),
        rows = List.unmodifiable(rows.map(List<Object?>.unmodifiable));
  final List<String> columns;
  final List<List<Object?>> rows;
}

final class QueryPlan {
  const QueryPlan(this.access, this.rootPage, this.rowid);
  final String access;
  final int? rootPage;
  final BigInt? rowid;
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
      [List<Object?> parameters = const []]) async {
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
    final table =
        statement.table == null ? null : catalog.table(statement.table!);
    final columns = table?.columns ?? <CatalogColumn>[];
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
    if (statement.where?.containsAggregate ?? false) {
      throw const SqlException('Aggregate in WHERE');
    }
    for (final expr in statement.groupBy) {
      expr.validate(names);
      if (expr is Literal && expr.value is BigInt) {
        throw const SqlException('GROUP BY ordinals are unsupported');
      }
      if (expr.containsAggregate) {
        throw const SqlException('Aggregate in GROUP BY');
      }
    }
    final aggregate = statement.groupBy.isNotEmpty ||
        items.any((item) => item.expression!.containsAggregate) ||
        statement.order.any((term) => term.expression.containsAggregate) ||
        (statement.having?.containsAggregate ?? false);
    if (statement.having != null && !aggregate) {
      throw const SqlException('HAVING requires aggregate query');
    }
    statement.having?.validate(names);
    if (aggregate) {
      final grouped = statement.groupBy
          .whereType<ColumnExpr>()
          .map((expr) => expr.key)
          .toSet();
      for (final expr in [
        ...items.map((item) => item.expression!),
        if (statement.having != null) statement.having!
      ]) {
        if (expr.unaggregatedColumns.any((name) => !grouped.contains(name))) {
          throw const SqlException(
              'Bare or expression-grouped columns in aggregate projection are unsupported');
        }
      }
    }

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
      if (aggregate) {
        final grouped = statement.groupBy
            .whereType<ColumnExpr>()
            .map((expr) => expr.key)
            .toSet();
        if (term.expression.unaggregatedColumns.any(
            (name) => !grouped.contains(name) && !aliases.contains(name))) {
          throw const SqlException(
              'Unsupported bare column in aggregate ordering');
        }
      }
    }
    statement.limit?.validate({});
    statement.offset?.validate({});
    final constantContext =
        EvalContext({}, {}, bound, _pager.header.textEncoding);
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

      final stream = plan.access == 'rowid-lookup'
          ? point()
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
    final filtered = input.where((row) {
      final ctx =
          EvalContext(row, affinities, bound, _pager.header.textEncoding);
      return statement.where == null ||
          truth(statement.where!.evaluate(ctx), _pager.header.textEncoding) ==
              true;
    }).toList();
    final groups = <(List<Object?>, List<RowValues>)>[];
    if (aggregate && statement.groupBy.isEmpty) {
      groups.add(([], filtered));
    } else {
      for (final row in filtered) {
        final ctx =
            EvalContext(row, affinities, bound, _pager.header.textEncoding);
        final keys =
            statement.groupBy.map((expr) => expr.evaluate(ctx)).toList();
        if (!aggregate) {
          groups.add((keys, [row]));
          continue;
        }
        final index = groups.indexWhere((group) => _same(group.$1, keys));
        if (index < 0) {
          groups.add((keys, [row]));
        } else {
          groups[index].$2.add(row);
        }
      }
    }
    final output = <(List<Object?>, List<Object?>, int)>[];
    for (final group in groups) {
      final row = group.$2.isEmpty
          ? <String, Object?>{for (final name in names) name: null}
          : group.$2.first;
      final ctx =
          EvalContext(row, affinities, bound, _pager.header.textEncoding)
            ..group = aggregate ? group.$2 : null;
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
      if (statement.having != null &&
          truth(statement.having!.evaluate(ctx), _pager.header.textEncoding) !=
              true) {
        continue;
      }
      final values =
          items.map((item) => item.expression!.evaluate(ctx)).toList();
      if (statement.distinct &&
          output.any((entry) => _same(entry.$1, values))) {
        continue;
      }
      final orderRow = {...row};
      for (var i = 0; i < items.length; i++) {
        orderRow[asciiLower(items[i].label)] = values[i];
      }
      final orderCtx =
          EvalContext(orderRow, affinities, bound, _pager.header.textEncoding)
            ..group = aggregate ? group.$2 : null;
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
            compareValues(a.$2[i], b.$2[i], _pager.header.textEncoding);
        if (comparison != 0) {
          return statement.order[i].descending ? -comparison : comparison;
        }
      }
      return a.$3.compareTo(b.$3);
    });
    var rows = output.map((entry) => entry.$1).skip(offset < 0 ? 0 : offset);
    if (limit != null && limit >= 0) rows = rows.take(limit);
    return QueryResult(_labels(items, columns, table), rows.toList());
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
    if (name == 'table_info' && argument != null) {
      final cols = ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk'];
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
                table.withoutRowid && table.columns[i].primaryKey != 0),
            table.columns[i].defaultSql,
            BigInt.from(table.columns[i].primaryKey)
          ]
      ]);
    }
    throw SqlException('Unsupported PRAGMA $name');
  }

  bool _same(List<Object?> a, List<Object?> b) {
    for (var i = 0; i < a.length; i++) {
      if (compareValues(a[i], b[i], _pager.header.textEncoding) != 0) {
        return false;
      }
    }
    return true;
  }
}
