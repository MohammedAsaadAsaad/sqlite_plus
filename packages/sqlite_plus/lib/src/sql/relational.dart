part of 'database.dart';

extension _RelationalQueries on SqliteDatabase {
  Iterable<Expr> _expressions(SelectStatement s) sync* {
    for (final item in s.items) {
      if (item.expression != null) yield item.expression!;
    }
    if (s.where != null) yield s.where!;
    yield* s.groupBy;
    if (s.having != null) yield s.having!;
    for (final order in s.order) {
      yield order.expression;
    }
    for (final source in s.sources) {
      if (source.on != null) yield source.on!;
    }
  }

  Iterable<SelectStatement> _nested(Expr expr) sync* {
    if (expr is SubqueryExpr) yield expr.statement;
    if (expr is InSelectExpr) yield expr.statement;
    for (final child in expr.children) {
      yield* _nested(child);
    }
  }

  bool _needsRelational(SelectStatement s) =>
      s.ctes.isNotEmpty ||
      s.sources.any((source) =>
          source.table != null &&
          catalog.entries.any((entry) =>
              asciiLower(entry.name) == asciiLower(source.table!) &&
              entry.type == 'view')) ||
      s.compounds.isNotEmpty ||
      s.sources.length > 1 ||
      s.sources.any((source) => source.alias != null || source.query != null) ||
      s.items.any((item) => item.expression == null && item.label != '*') ||
      _expressions(s)
          .any((expr) => _nested(expr).isNotEmpty || _qualified(expr));
  bool _qualified(Expr expr) =>
      expr is ColumnExpr && expr.name.contains('.') ||
      expr.children.any(_qualified);

  Future<void> _loadRelations(SelectStatement s,
      Map<String, (CatalogTable, List<RowValues>)> cache, Set<String> loading,
      [Set<String> cteNames = const {}]) async {
    final cteScope = {...cteNames, ...s.ctes.keys};
    for (final cte in s.ctes.values) {
      await _loadRelations(cte.$2, cache, loading, cteScope);
    }
    for (final source in s.sources) {
      if (source.query != null) {
        await _loadRelations(source.query!, cache, loading, cteScope);
        continue;
      }
      final name = source.table!;
      final key = asciiLower(name);
      if (cteScope.contains(key)) continue;
      if (cache.containsKey(key)) continue;
      if (!loading.add(key)) throw const SqlException('Circular view');
      try {
        final entry =
            catalog.entries.where((e) => asciiLower(e.name) == key).firstOrNull;
        if (entry?.type == 'view') {
          final parser = SqlParser(entry!.sql!);
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
          final query =
              SqlParser(entry.sql!.substring(parser.current.offset)).select();
          await _loadRelations(query, cache, loading, cteScope);
          final result = _relational(query, const [], cache, null);
          final names = declared.isEmpty ? result.columns : declared;
          if (names.length != result.columns.length) {
            throw const SqlException('View column width mismatch');
          }
          cache[key] = (
            CatalogTable(
                name,
                0,
                [
                  for (var i = 0; i < names.length; i++)
                    CatalogColumn(
                        names[i], _affinityType(result.columnAffinities[i]))
                ],
                withoutRowid: true),
            [
              for (final row in result.rows)
                {
                  for (var i = 0; i < names.length; i++)
                    asciiLower(names[i]): row[i]
                }
            ]
          );
        } else {
          final table = catalog.table(name);
          final rows = <RowValues>[];
          final reader = BtreeReader(_pager);
          await for (final record in table.withoutRowid
              ? reader.scanIndex(table.rootPage)
              : reader.scanTable(table.rootPage)) {
            final row = <String, Object?>{};
            final stored = table.storageColumns;
            if (record.values.length > stored.length) {
              throw const FormatException('Catalog record width mismatch');
            }
            for (var i = 0; i < stored.length; i++) {
              final c = stored[i];
              var value = c.name == table.rowidAlias
                  ? record.rowId
                  : i < record.values.length
                      ? record.values[i]
                      : c.defaultValue;
              if (value is double && value.isNaN) value = null;
              if (value is BigInt &&
                  !c.declaredType.toUpperCase().contains('INT') &&
                  ['REAL', 'FLOA', 'DOUB']
                      .any(c.declaredType.toUpperCase().contains)) {
                value = value.toDouble();
              }
              row[asciiLower(c.name)] = value;
            }
            if (!table.withoutRowid) {
              for (final id in ['rowid', '_rowid_', 'oid']) {
                row.putIfAbsent(id, () => record.rowId);
              }
            }
            rows.add(row);
          }
          cache[key] = (table, rows);
        }
      } finally {
        loading.remove(key);
      }
    }
    for (final expr in _expressions(s)) {
      for (final nested in _nested(expr)) {
        await _loadRelations(nested, cache, loading, cteScope);
      }
    }
    for (final part in s.compounds) {
      await _loadRelations(part.$2, cache, loading, cteScope);
    }
  }

  String _affinityType(String affinity) => affinity == 'numeric'
      ? 'NUMERIC'
      : affinity == 'text'
          ? 'TEXT'
          : '';
  SelectStatement _copy(SelectStatement source, List<SelectItem> items,
          {bool tail = true}) =>
      SelectStatement(
          items,
          source.table,
          source.where,
          tail ? source.order : [],
          tail ? source.limit : null,
          tail ? source.offset : null,
          source.distinct,
          source.parameterCount)
        ..groupBy.addAll(source.groupBy)
        ..having = source.having;

  QueryResult _relational(SelectStatement s, List<Object?> bound,
      Map<String, (CatalogTable, List<RowValues>)> cache, EvalContext? outer) {
    if (s.ctes.isNotEmpty) {
      cache = Map.of(cache);
      final pending = Map.of(s.ctes);
      while (pending.isNotEmpty) {
        var progressed = false;
        for (final name in pending.keys.toList()) {
          final entry = pending[name]!;
          final query = entry.$2;
          final references = <String>{
            for (final source in query.sources)
              if (source.table != null) asciiLower(source.table!),
            for (final part in query.compounds)
              for (final source in part.$2.sources)
                if (source.table != null) asciiLower(source.table!)
          };
          if (references
              .any((ref) => ref != name && pending.containsKey(ref))) {
            continue;
          }
          if (query.sources
              .any((source) => asciiLower(source.table ?? '') == name)) {
            throw const SqlException(
                'Recursive CTE requires a non-recursive anchor');
          }
          final anchor = _copy(query, query.items, tail: false)
            ..sources.addAll(query.sources)
            ..ctes.addAll(query.ctes);
          final first = _relational(anchor, bound, cache, outer);
          final columns = entry.$1.isEmpty ? first.columns : entry.$1;
          if (columns.length != first.columns.length) {
            throw const SqlException('CTE column width mismatch');
          }
          (CatalogTable, List<RowValues>) materialize(
                  List<List<Object?>> rows) =>
              (
                CatalogTable(
                    name,
                    0,
                    [
                      for (var i = 0; i < columns.length; i++)
                        CatalogColumn(columns[i],
                            _affinityType(first.columnAffinities[i]))
                    ],
                    withoutRowid: true),
                [
                  for (final row in rows)
                    {
                      for (var i = 0; i < columns.length; i++)
                        asciiLower(columns[i]): row[i]
                    }
                ]
              );
          if (references.contains(name)) {
            if (query.order.isNotEmpty || query.limit != null) {
              throw const SqlException(
                  'Recursive CTE queue ordering is unsupported');
            }
            final rows = first.rows.map((row) => row.toList()).toList();
            final recursive = query.compounds
                .where((part) => part.$2.sources
                    .any((source) => asciiLower(source.table ?? '') == name))
                .toList();
            for (final part
                in query.compounds.where((part) => !recursive.contains(part))) {
              final seed = _relational(part.$2, bound, cache, outer);
              for (final row in seed.rows) {
                if (part.$1 == 'UNION' && rows.any((old) => _same(old, row))) {
                  continue;
                }
                rows.add(row);
              }
            }
            final queue = rows.toList();
            var offset = 0;
            while (offset < queue.length) {
              if (rows.length > 100000) {
                throw const SqlException('Recursive CTE row limit exceeded');
              }
              cache[name] = materialize([queue[offset++]]);
              for (final part in recursive) {
                if (!['UNION', 'UNION ALL'].contains(part.$1)) {
                  throw const SqlException('Invalid recursive compound');
                }
                final result = _relational(part.$2, bound, cache, outer);
                if (result.columns.length != columns.length) {
                  throw const SqlException('Recursive CTE width mismatch');
                }
                for (final row in result.rows) {
                  if (part.$1 == 'UNION' &&
                      rows.any((old) => _same(old, row))) {
                    continue;
                  }
                  rows.add(row);
                  queue.add(row);
                }
              }
            }
            cache[name] = materialize(rows);
          } else {
            final result = _relational(query, bound, cache, outer);
            cache[name] = materialize(result.rows);
          }
          pending.remove(name);
          progressed = true;
        }
        if (!progressed) throw const SqlException('Circular CTE definition');
      }
    }
    final sources = s.sources;
    var joined = <RowValues>[{}];
    final aliases = <String>{};
    final refs = <String, List<String>>{};
    final merged = <String>{};
    final declared = <String, CatalogColumn>{};
    final labels = <String, String>{};
    final star = <(String, String)>[];
    final sourceStars = <String, List<(String, String)>>{};
    Set<String> keysBefore = {};
    Map<String, Object?> scope(RowValues row) {
      final result = <String, Object?>{...?outer?.row, ...row};
      for (final entry in refs.entries) {
        result.remove(entry.key);
        if (entry.value.length == 1) {
          result[entry.key] = row[entry.value.single];
        } else if (merged.contains(entry.key)) {
          result[entry.key] = entry.value
              .map((key) => row[key])
              .where((v) => v != null)
              .firstOrNull;
        }
      }
      return result;
    }

    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      CatalogTable table;
      List<RowValues> rows;
      if (source.query != null) {
        final result = _relational(source.query!, bound, cache, outer);
        table = CatalogTable(
            '@$index',
            0,
            [
              for (var i = 0; i < result.columns.length; i++)
                CatalogColumn(result.columns[i],
                    _affinityType(result.columnAffinities[i]))
            ],
            withoutRowid: true);
        rows = [
          for (final row in result.rows)
            {
              for (var i = 0; i < result.columns.length; i++)
                asciiLower(result.columns[i]): row[i]
            }
        ];
      } else {
        final entry = cache[asciiLower(source.table!)];
        if (entry == null) {
          throw SqlException('Unknown or circular source: ${source.table}');
        }
        (table, rows) = entry;
      }
      final alias = asciiLower(source.alias ?? source.table ?? '@$index');
      if (!aliases.add(alias)) {
        throw const SqlException('Duplicate table alias');
      }
      final rightNames = {for (final c in table.columns) asciiLower(c.name)};
      final using = source.natural
          ? refs.keys.where(rightNames.contains).toSet()
          : source.using.map(asciiLower).toSet();
      for (final name in using) {
        if (!refs.containsKey(name) || !rightNames.contains(name)) {
          throw SqlException('USING column missing: $name');
        }
      }
      merged.addAll(using);
      for (var i = 0; i < star.length; i++) {
        if (using.contains(asciiLower(star[i].$1))) {
          star[i] = (star[i].$1, asciiLower(star[i].$1));
        }
      }
      final available = [...table.columns];
      if (!table.withoutRowid) {
        for (final name in ['rowid', '_rowid_', 'oid']) {
          if (!rightNames.contains(name)) {
            available.add(CatalogColumn(name, 'INTEGER'));
          }
        }
      }
      final rightKeys = <String>{};
      final allStar = <(String, String)>[];
      for (final column in available) {
        final name = asciiLower(column.name);
        final key = '$alias.$name';
        rightKeys.add(key);
        declared[key] = column;
        labels[key] = rightNames.contains(name)
            ? column.name
            : table.rowidAlias ?? 'rowid';
        refs.putIfAbsent(name, () => []).add(key);
        if (rightNames.contains(name)) {
          allStar.add((column.name, key));
          if (!using.contains(name)) star.add((column.name, key));
        }
      }
      sourceStars[alias] = allStar;
      final known = <String>{
        ...declared.keys,
        ...?outer?.row.keys,
        for (final e in refs.entries)
          if (e.value.length == 1 || merged.contains(e.key)) e.key
      };
      source.on?.validate(known);
      if (source.on?.containsAggregate ?? false) {
        throw const SqlException('Aggregate in JOIN ON');
      }
      final af = <String, String>{
        ...?outer?.affinities,
        for (final e in declared.entries) e.key: e.value.affinity,
        for (final e in refs.entries)
          if (e.value.length == 1 || merged.contains(e.key))
            e.key: declared[e.value.first]!.affinity
      };
      final right = [
        for (final row in rows)
          {
            for (final key in rightKeys)
              key: row[key.substring(alias.length + 1)]
          }
      ];
      final next = <RowValues>[];
      final matched = List<bool>.filled(right.length, false);
      for (final left in joined) {
        var found = false;
        for (var r = 0; r < right.length; r++) {
          final combined = <String, Object?>{...left, ...right[r]};
          var equal = true;
          for (final name in using) {
            final leftKey = refs[name]!.first;
            final rightKey = '$alias.$name';
            final ctx =
                EvalContext(combined, af, bound, _pager.header.textEncoding);
            if (BinaryExpr('=', ColumnExpr(leftKey), ColumnExpr(rightKey))
                    .evaluate(ctx) !=
                BigInt.one) {
              equal = false;
              break;
            }
          }
          if (!equal) continue;
          final ctx = EvalContext(
              scope(combined), af, bound, _pager.header.textEncoding)
            ..subquery =
                (query, context) => _relational(query, bound, cache, context);
          if (source.on != null &&
              truth(source.on!.evaluate(ctx), ctx.encoding) != true) {
            continue;
          }
          found = true;
          matched[r] = true;
          next.add(combined);
        }
        if (!found && ['LEFT', 'FULL'].contains(source.join)) {
          next.add({...left, for (final key in rightKeys) key: null});
        }
      }
      if (['RIGHT', 'FULL'].contains(source.join)) {
        for (var r = 0; r < right.length; r++) {
          if (!matched[r]) {
            next.add({for (final key in keysBefore) key: null, ...right[r]});
          }
        }
      }
      joined = next;
      keysBefore = {...keysBefore, ...rightKeys};
    }
    final columns = <CatalogColumn>[
      ...declared.entries.map((e) => CatalogColumn(
          e.key, _affinityType(e.value.affinity),
          collation: e.value.collation))
    ];
    for (final entry in refs.entries) {
      if (entry.value.length == 1 || merged.contains(entry.key)) {
        final original = declared[entry.value.first]!;
        columns.add(CatalogColumn(
            original.name, _affinityType(original.affinity),
            collation: original.collation));
      }
    }
    if (outer != null) {
      for (final name in outer.row.keys) {
        if (!columns.any((c) => asciiLower(c.name) == name)) {
          columns.add(CatalogColumn(
              name, _affinityType(outer.affinities[name] ?? 'none')));
        }
      }
    }
    final items = <SelectItem>[];
    for (final item in s.items) {
      if (item.expression == null) {
        final list = item.label == '*'
            ? star
            : sourceStars[
                asciiLower(item.label.substring(0, item.label.length - 2))];
        if (list == null || sources.isEmpty) {
          throw const SqlException('Unknown table wildcard');
        }
        items.addAll(list.map(
            (c) => SelectItem(ColumnExpr(c.$2), c.$1, explicitAlias: true)));
      } else if (item.expression is ColumnExpr && !item.explicitAlias) {
        final expr = item.expression as ColumnExpr;
        final col =
            columns.where((c) => asciiLower(c.name) == expr.key).firstOrNull;
        items.add(SelectItem(
            expr,
            col == null
                ? item.label
                : labels[expr.key] ??
                    (refs[expr.key]?.isNotEmpty == true
                        ? labels[refs[expr.key]!.first]
                        : null) ??
                    col.name.split('.').last,
            explicitAlias: true));
      } else {
        items.add(item);
      }
    }
    final virtual = CatalogTable('@scope', 0, columns, withoutRowid: true);
    final component = _copy(s, items, tail: s.compounds.isEmpty);
    var result = _evaluate(
        component, bound, virtual, joined.map(scope).toList(),
        subquery: (query, context) =>
            _relational(query, bound, cache, context));
    if (s.compounds.isEmpty) return result;
    var values = result.rows.map((row) => row.toList()).toList();
    bool same(List<Object?> a, List<Object?> b) => _same(a, b);
    for (final part in s.compounds) {
      final rhs = _relational(part.$2, bound, cache, outer);
      if (rhs.columns.length != result.columns.length) {
        throw const SqlException('Compound SELECT width mismatch');
      }
      if (part.$1 == 'UNION ALL') {
        values.addAll(rhs.rows);
      } else if (part.$1 == 'UNION') {
        for (final row in rhs.rows) {
          if (!values.any((old) => same(old, row))) values.add(row);
        }
        final unique = <List<Object?>>[];
        for (final row in values) {
          if (!unique.any((old) => same(old, row))) unique.add(row);
        }
        values = unique;
      } else {
        final filtered = <List<Object?>>[];
        for (final row in values) {
          if (rhs.rows.any((other) => same(row, other)) ==
                  (part.$1 == 'INTERSECT') &&
              !filtered.any((old) => same(old, row))) {
            filtered.add(row);
          }
        }
        values = filtered;
      }
    }
    if (s.order.isNotEmpty) {
      final positions = <int>[];
      for (final term in s.order) {
        final expr = term.expression;
        int index = -1;
        if (expr is Literal && expr.value is BigInt) {
          index = (expr.value as BigInt).toInt() - 1;
        } else if (expr is ColumnExpr) {
          index =
              result.columns.indexWhere((name) => asciiLower(name) == expr.key);
        }
        if (index < 0 || index >= result.columns.length) {
          throw const SqlException(
              'Compound ORDER BY must name an output column');
        }
        positions.add(index);
      }
      values.sort((a, b) {
        for (var i = 0; i < positions.length; i++) {
          final c = s.order[i].compare(a[positions[i]], b[positions[i]],
              EvalContext({}, {}, bound, _pager.header.textEncoding));
          if (c != 0) return c;
        }
        return 0;
      });
    }
    int count(Expr? expr, int fallback) {
      if (expr == null) return fallback;
      expr.validate({});
      var value =
          expr.evaluate(EvalContext({}, {}, bound, _pager.header.textEncoding));
      if (value is String) value = numeric(value);
      if (value is double &&
          value.isFinite &&
          value == value.truncateToDouble()) {
        value = BigInt.from(value);
      }
      if (value is! BigInt || value.bitLength > 63) {
        throw const SqlException('LIMIT datatype mismatch');
      }
      return value > BigInt.from(0x7fffffff)
          ? 0x7fffffff
          : value < BigInt.from(-0x7fffffff)
              ? -0x7fffffff
              : value.toInt();
    }

    final offset = count(s.offset, 0);
    final limit = count(s.limit, -1);
    var selected = values.skip(offset < 0 ? 0 : offset);
    if (limit >= 0) selected = selected.take(limit);
    return QueryResult(
        result.columns, selected.toList(), result.columnAffinities);
  }
}
