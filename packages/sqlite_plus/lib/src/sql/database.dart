import '../btree/btree_reader.dart';
import '../pager/read_only_pager.dart';
import '../storage/storage_backend.dart';
import 'catalog.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

final class QueryResult {
  QueryResult(List<String> columns, List<List<Object?>> rows)
      : columns = List.unmodifiable(columns),
        rows = List.unmodifiable(rows.map(List<Object?>.unmodifiable));
  final List<String> columns;
  final List<List<Object?>> rows;
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

  Future<QueryResult> query(String sql,
      [List<Object?> parameters = const []]) async {
    if (_closed) throw StateError('Database is closed');
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
    final input = <RowValues>[];
    if (table == null) {
      input.add({});
    } else {
      final reader = BtreeReader(_pager);
      final stream = table.withoutRowid
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
    final output = <(List<Object?>, List<Object?>, int)>[];
    for (final row in input) {
      final ctx =
          EvalContext(row, affinities, bound, _pager.header.textEncoding);
      if (statement.where != null &&
          truth(statement.where!.evaluate(ctx), _pager.header.textEncoding) !=
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
          EvalContext(orderRow, affinities, bound, _pager.header.textEncoding);
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

    return QueryResult(items.map(label).toList(), rows.toList());
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
