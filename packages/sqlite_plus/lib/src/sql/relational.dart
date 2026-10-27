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
    for (final source in s.allSources) {
      if (source.on != null) yield source.on!;
      yield* source.pragmaArguments ?? const <Expr>[];
    }
  }

  Iterable<SelectStatement> _nested(Expr expr) sync* {
    if (expr is SubqueryExpr) yield expr.statement;
    if (expr is InSelectExpr) yield expr.statement;
    for (final child in expr.children) {
      yield* _nested(child);
    }
  }

  Set<String> _usedCteNames(SelectStatement statement) =>
      usedCteNames(statement);

  bool _needsRelational(SelectStatement s) =>
      s.ctes.isNotEmpty ||
      s.sources.any((source) =>
          source.table != null &&
          catalog.entries.any((entry) =>
              asciiLower(entry.name) == asciiLower(source.table!) &&
              entry.type == 'view')) ||
      s.compounds.isNotEmpty ||
      s.sources.length > 1 ||
      s.sources.any((source) =>
          _isPragmaTableSource(source) ||
          source.alias != null ||
          source.query != null ||
          source.group.isNotEmpty) ||
      s.items.any((item) => item.expression == null && item.label != '*') ||
      _expressions(s)
          .any((expr) => _nested(expr).isNotEmpty || _qualified(expr));
  bool _qualified(Expr expr) =>
      expr is ColumnExpr && expr.name.contains('.') ||
      expr.children.any(_qualified);

  Future<void> _loadRelations(SelectStatement s,
      Map<String, (CatalogTable, List<RowValues>)> cache, Set<String> loading,
      [Set<String> cteNames = const {},
      List<Object?> parameters = const []]) async {
    final cteScope = {...cteNames, ...s.ctes.keys};
    for (final name in _usedCteNames(s)) {
      await _loadRelations(
          s.ctes[name]!.$2, cache, loading, cteScope, parameters);
    }
    for (final source in s.leafSources) {
      if (source.query != null) {
        await _loadRelations(
            source.query!, cache, loading, cteScope, parameters);
        continue;
      }
      final name = source.table!;
      final key =
          source.schema == null ? asciiLower(name) : 'main.${asciiLower(name)}';
      if (source.schema == null && cteScope.contains(key)) {
        if (source.pragmaArguments != null) {
          throw SqlException('${source.table} is not a table-valued function');
        }
        _hintIndex(source, s.where, physical: false);
        continue;
      }
      if (_isPragmaTableSource(source)) {
        if (source.indexedBy != null || source.notIndexed) {
          throw const SqlException('Index hints on a PRAGMA table source');
        }
        final descriptor = (_pragmaSourceTable(source), <RowValues>[]);
        cache[key] = descriptor;
        cache['main.${asciiLower(name)}'] = descriptor;
        continue;
      }
      _hintIndex(source, s.where,
          physical: catalog.entries.any((entry) =>
              entry.type == 'table' &&
              asciiLower(entry.name) == asciiLower(name)));
      if (cache.containsKey(key)) continue;
      if (!loading.add(key)) throw const SqlException('Circular view');
      try {
        final entry = catalog.entries
            .where((e) => asciiLower(e.name) == asciiLower(name))
            .firstOrNull;
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
          await _loadRelations(query, cache, loading, cteScope, parameters);
          prepareSubqueryWidths(query, {
            for (final relation in cache.entries)
              for (final name in {
                relation.key,
                if (relation.key.startsWith('main.')) relation.key.substring(5)
              })
                name: (
                  columns: relation.value.$1.columns
                      .where((column) => !column.hidden)
                      .map((column) => column.name)
                      .toList(),
                  rowid: !relation.value.$1.withoutRowid
                )
          });
          final columns = _pragmaColumnMetadata(query, cache);
          final names = _relationColumnNames(declared.isEmpty
              ? columns.map((column) => column.name).toList()
              : declared);
          if (names.length != columns.length) {
            throw const SqlException('View column width mismatch');
          }
          cache[key] = (
            CatalogTable(
                name,
                0,
                [
                  for (var i = 0; i < names.length; i++)
                    CatalogColumn(names[i], columns[i].declaredType,
                        affinityOverride: columns[i].affinity,
                        collation: columns[i].collation.isEmpty
                            ? 'binary'
                            : columns[i].collation)
                ],
                withoutRowid: true),
            _QueryRelationRows(
                query,
                names,
                (query, deferred) => _relationalExecution(
                    query, const [], cache, null,
                    deferredProjection: deferred),
                describe: (query) => _pragmaColumnMetadata(query, cache))
          );
        } else {
          final table = _resolveTable(name, source, parameters);
          final rows = <RowValues>[];
          final reader = BtreeReader(_pager);
          final records = table.virtual
              ? Stream<BtreeRecord>.fromIterable(VirtualTableRows.records(table,
                  where: s.where,
                  parameters: parameters,
                  allowUnqualified: s.leafSources
                          .where((item) => item.query == null)
                          .length ==
                      1,
                  alias: source.alias))
              : table.withoutRowid
                  ? reader.scanIndex(table.rootPage)
                  : reader.scanTable(table.rootPage);
          await for (final record in records) {
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
            table.evaluateGenerated(row, _pager.header.textEncoding,
                lazy: true);
            rows.add(row);
          }
          cache[key] = (table, rows);
        }
        cache['main.${asciiLower(name)}'] = cache[key]!;
      } finally {
        loading.remove(key);
      }
    }
    for (final expr in _expressions(s)) {
      for (final nested in _nested(expr)) {
        await _loadRelations(nested, cache, loading, cteScope, parameters);
      }
    }
    for (final part in s.compounds) {
      await _loadRelations(part.$2, cache, loading, cteScope, parameters);
    }
  }

  String _affinityType(String affinity) => affinity == 'numeric'
      ? 'NUMERIC'
      : affinity == 'text'
          ? 'TEXT'
          : '';

  List<String> _relationColumnNames(List<String> columns) =>
      relationColumnNames(columns);

  SelectStatement _copy(SelectStatement source, List<SelectItem> items,
          {bool tail = true,
          Expr? limitOverride,
          Set<Expr> omitConditions = const {}}) =>
      SelectStatement(
          items,
          source.table,
          source.where == null
              ? null
              : _omitPragmaConstraints(source.where!, omitConditions),
          tail ? source.order : [],
          tail ? source.limit : limitOverride,
          tail ? source.offset : null,
          source.distinct,
          source.parameterCount)
        ..groupBy.addAll(source.groupBy)
        ..cteMaterialization.addAll(source.cteMaterialization)
        ..subqueryFirstRowOnly = source.subqueryFirstRowOnly
        ..subqueryExists = source.subqueryExists
        ..having = source.having;

  QueryResult _relational(SelectStatement s, List<Object?> bound,
      Map<String, (CatalogTable, List<RowValues>)> cache, EvalContext? outer,
      {SqlRows Function(SelectStatement, EvalContext,
              Map<String, (CatalogTable, List<RowValues>)>)?
          mutationSubqueries,
      Map<SelectStatement, (CatalogTable, List<RowValues>)?>? mutationCtes,
      _JoinedGroup? sourceGroup}) {
    return _relationalExecution(s, bound, cache, outer,
            mutationSubqueries: mutationSubqueries,
            mutationCtes: mutationCtes,
            sourceGroup: sourceGroup)
        .materialize(firstRowOnly: s.subqueryFirstRowOnly);
  }

  _QueryExecution _relationalExecution(SelectStatement s, List<Object?> bound,
      Map<String, (CatalogTable, List<RowValues>)> cache, EvalContext? outer,
      {SqlRows Function(SelectStatement, EvalContext,
              Map<String, (CatalogTable, List<RowValues>)>)?
          mutationSubqueries,
      Map<SelectStatement, (CatalogTable, List<RowValues>)?>? mutationCtes,
      _JoinedGroup? sourceGroup,
      bool deferredProjection = false}) {
    if (s.subqueryFirstRowOnly) {
      s = _relationQuery(s, limitOverride: _ScalarSubqueryLimit(s.limit));
    }
    final outerMetadata = <String, CatalogColumn?>{
      if (outer != null)
        for (final name in outer.row.keys)
          name: CatalogColumn(name, '',
              affinityOverride: outer.affinities[name] ?? 'none',
              collation: outer.collations[name] ?? '')
    };
    QueryResult evaluate(
            SelectStatement query,
            Map<String, (CatalogTable, List<RowValues>)> scope,
            EvalContext? context) =>
        _relational(query, bound, scope, context,
            mutationSubqueries: mutationSubqueries, mutationCtes: mutationCtes);
    final once = <SelectStatement, SqlRows>{};
    SqlRows subquery(SelectStatement query, EvalContext context) {
      if (mutationSubqueries != null) {
        return mutationSubqueries(query, context, cache);
      }
      final correlated =
          _mutationCorrelated(query, cache, context.row.keys.toSet());
      if (!correlated && once.containsKey(query)) return once[query]!;
      final result = evaluate(query, cache, context);
      if (!correlated) once[query] = result;
      return result;
    }

    if (s.ctes.isNotEmpty) {
      cache = Map.of(cache);
      final pending = {
        for (final name in _usedCteNames(s)) name: s.ctes[name]!
      };
      while (pending.isNotEmpty) {
        var progressed = false;
        for (final name in pending.keys.toList()) {
          final entry = pending[name]!;
          final query = entry.$2;
          final saved = mutationCtes?[query];
          if (saved != null) {
            cache[name] = saved;
            pending.remove(name);
            progressed = true;
            continue;
          }
          final references = usedCteNames(s, consumer: query);
          if (references
              .any((ref) => ref != name && pending.containsKey(ref))) {
            continue;
          }
          if (query.leafSources.any((source) =>
              source.schema == null &&
              asciiLower(source.table ?? '') == name)) {
            throw const SqlException(
                'Recursive CTE requires a non-recursive anchor');
          }
          int recursiveCount(Expr? expr, int fallback) {
            if (expr == null) return fallback;
            expr.validate({});
            var value = expr.evaluate(
                EvalContext({}, {}, bound, _pager.header.textEncoding));
            if (value is String) value = numeric(value);
            if (value is double &&
                value.isFinite &&
                value == value.truncateToDouble()) {
              value = BigInt.from(value);
            }
            if (value is! BigInt ||
                value < -(BigInt.one << 63) ||
                value >= BigInt.one << 63) {
              throw const SqlException(
                  'Recursive LIMIT/OFFSET datatype mismatch');
            }
            if (value > BigInt.from(0x7fffffff)) return 0x7fffffff;
            if (value < BigInt.from(-0x7fffffff)) return -0x7fffffff;
            return value.toInt();
          }

          final recursiveLimit =
              references.contains(name) ? recursiveCount(query.limit, -1) : -1;
          final recursiveOffset =
              references.contains(name) ? recursiveCount(query.offset, 0) : 0;
          final anchor = _copy(query, query.items,
              tail: false,
              limitOverride: recursiveLimit == 0 ? Literal(BigInt.zero) : null)
            ..sources.addAll(query.sources)
            ..ctes.addAll(query.ctes);
          if (!references.contains(name)) {
            final metadata = _pragmaColumnMetadata(query, cache, outerMetadata);
            final names = _relationColumnNames(entry.$1.isEmpty
                ? metadata.map((column) => column.name).toList()
                : entry.$1);
            if (names.length != metadata.length) {
              throw const SqlException('CTE column width mismatch');
            }
            // A pushed consumer predicate may reference another WITH name
            // which is prepared later. Keep this lexical frame live until
            // all reachable declarations have been installed.
            final scope = cache;
            cache[name] = (
              CatalogTable(
                  name,
                  0,
                  [
                    for (var i = 0; i < names.length; i++)
                      CatalogColumn(names[i], metadata[i].declaredType,
                          affinityOverride: metadata[i].affinity,
                          collation: metadata[i].collation.isEmpty
                              ? 'binary'
                              : metadata[i].collation)
                  ],
                  withoutRowid: true),
              _QueryRelationRows(
                  query,
                  names,
                  (query, deferred) => _relationalExecution(
                      query, bound, scope, outer,
                      mutationSubqueries: mutationSubqueries,
                      mutationCtes: mutationCtes,
                      deferredProjection: deferred),
                  materialized: s.cteMaterialization[name] == true ||
                      (mutationCtes?.containsKey(query) ?? false),
                  cte: true,
                  describe: (query) =>
                      _pragmaColumnMetadata(query, scope, outerMetadata))
            );
            if (mutationCtes?.containsKey(query) ?? false) {
              mutationCtes![query] = cache[name]!;
            }
            pending.remove(name);
            progressed = true;
            continue;
          }
          final first = evaluate(anchor, cache, outer);
          final columns =
              _relationColumnNames(entry.$1.isEmpty ? first.columns : entry.$1);
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
                        CatalogColumn(
                            columns[i],
                            first.columnDeclaredTypes[i].isEmpty
                                ? _affinityType(first.columnAffinities[i])
                                : first.columnDeclaredTypes[i],
                            affinityOverride: first.columnAffinities[i],
                            collation: first.columnCollations[i].isEmpty
                                ? 'binary'
                                : first.columnCollations[i])
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
            final recursive = query.compounds
                .where((part) => part.$2.leafSources.any((source) =>
                    source.schema == null &&
                    asciiLower(source.table ?? '') == name))
                .toList();
            if (recursive.isEmpty ||
                recursive
                    .any((part) => !['UNION', 'UNION ALL'].contains(part.$1)) ||
                recursive.any((part) => part.$1 != recursive.first.$1)) {
              throw const SqlException('Invalid recursive compound');
            }
            cache[name] = materialize([]);
            for (final part in query.compounds) {
              final metadataQuery = _copy(part.$2, part.$2.items,
                  tail: false, limitOverride: Literal(BigInt.zero))
                ..sources.addAll(part.$2.sources)
                ..ctes.addAll(part.$2.ctes);
              if (evaluate(metadataQuery, cache, outer).columns.length !=
                  columns.length) {
                throw const SqlException('Recursive CTE width mismatch');
              }
            }
            for (final part in recursive) {
              if (part.$2.leafSources
                      .where((source) =>
                          source.schema == null &&
                          asciiLower(source.table ?? '') == name)
                      .length !=
                  1) {
                throw const SqlException('Multiple recursive references');
              }
              if (part.$2.groupBy.isNotEmpty ||
                  part.$2.having != null ||
                  _expressions(part.$2)
                      .any((e) => e.containsAggregate || e.containsWindow)) {
                throw const SqlException('Aggregate/window in recursive query');
              }
            }
            final orderSlots = <int>[];
            for (final term in query.order) {
              final operand = indexOperand(term.expression);
              final ordinal = expressionOrdinal(term.expression);
              var slot = ordinal == null ? -1 : ordinal.toInt() - 1;
              if (ordinal == null) {
                for (final component in [
                  query,
                  ...query.compounds.map((p) => p.$2)
                ]) {
                  slot = component.items.indexWhere((item) =>
                      operand is ColumnExpr &&
                          asciiLower(item.label) == operand.key ||
                      item.expression != null &&
                          sameExpression(indexOperand(term.expression),
                              indexOperand(item.expression!)));
                  if (slot >= 0) break;
                }
              }
              if (slot < 0 || slot >= columns.length) {
                throw const SqlException(
                    'Recursive ORDER BY must name an output column');
              }
              orderSlots.add(slot);
            }
            int priority(List<Object?> a, List<Object?> b) {
              for (var i = 0; i < orderSlots.length; i++) {
                final term = query.order[i], slot = orderSlots[i];
                final context =
                    EvalContext({}, {}, bound, _pager.header.textEncoding);
                final collation = term.expression.explicitCollation(context) ??
                    first.columnCollations[slot];
                final order = OrderTerm(
                    CollateExpr(Literal(null),
                        collation.isEmpty ? 'binary' : collation),
                    term.descending,
                    term.nullsFirst);
                final comparison = order.compare(a[slot], b[slot], context);
                if (comparison != 0) return comparison;
              }
              return 0;
            }

            final queue = _CteWorkQueue(priority);
            final seen = <List<Object?>>[];
            final rows = <List<Object?>>[];
            final distinct = recursive.first.$1 == 'UNION';
            void enqueue(List<Object?> row) {
              if (distinct &&
                  seen.any((old) => _same(old, row, first.columnCollations))) {
                return;
              }
              if (seen.length >= 100000) {
                throw const SqlException('Recursive CTE row limit exceeded');
              }
              seen.add(row);
              queue.add(row);
            }

            if (recursiveLimit != 0) {
              for (final row in first.rows) {
                enqueue(row);
              }
              for (final part in query.compounds
                  .where((part) => !recursive.contains(part))) {
                final seed = evaluate(part.$2, cache, outer);
                for (final row in seed.rows) {
                  enqueue(row);
                }
              }
            }
            var skipped = 0;
            while (queue.isNotEmpty) {
              final current = queue.removeFirst();
              if (skipped < recursiveOffset) {
                skipped++;
              } else {
                rows.add(current);
                if (recursiveLimit >= 0 && rows.length >= recursiveLimit) break;
              }
              cache[name] = materialize([current]);
              for (final part in recursive) {
                final result = evaluate(part.$2, cache, outer);
                if (result.columns.length != columns.length) {
                  throw const SqlException('Recursive CTE width mismatch');
                }
                for (final row in result.rows) {
                  enqueue(row);
                }
              }
            }
            cache[name] = materialize(rows);
          } else {
            cache[name] = materialize(first.rows);
          }
          if (mutationCtes?.containsKey(query) ?? false) {
            mutationCtes![query] = cache[name]!;
          }
          pending.remove(name);
          progressed = true;
        }
        if (!progressed) throw const SqlException('Circular CTE definition');
      }
    }
    final sources = s.normalizedSources;
    final consumedPragmaConditions = <Expr>{};
    final inaccessibleGroupQualifiers = {
      for (final source in sources.where((source) => source.group.isNotEmpty))
        for (final child in source.leafSources)
          if (child.alias?.contains('.') ?? false) asciiLower(child.alias!)
    };
    final canonical = <String, String>{};
    final nestedImplicit = <String>{};
    final wildcardOverrides = <String, String>{};
    final ambiguousMerged = <String>{};
    final soleAliasedGroup = s.sources.length == 1 &&
        s.sources.single.group.isNotEmpty &&
        s.sources.single.alias != null;
    final fieldOrder = <String>[];
    Iterable<RowValues> joined = <RowValues>[{}];
    final aliases = <String>{};
    final refs = <String, List<String>>{};
    final implicitRefs = <String>{};
    final mergedValues = <String, (String, String, String)>{};
    final joinColumns = <String, CatalogColumn>{};
    final declared = <String, CatalogColumn>{};
    final labels = <String, String>{};
    final star = <(String, String)>[];
    final sourceStars = <String, List<(String, String)>>{};
    Set<String> keysBefore = {};
    final joinSteps = <Iterable<RowValues> Function(Iterable<RowValues>)>[];
    final columnStages = <String, int>{};
    final onStages = <QuerySource, int>{};
    final onConditions = <QuerySource, Expr>{};
    final onAliases = <String, Expr>{};
    final onRefs = <String, List<String>>{};
    final identityAliases = {
      for (final source in sources)
        if (source.rowIdentity != null)
          asciiLower(source.alias ?? source.table!),
    };
    bool identityKey(String key) => identityAliases.any(
        (alias) => key.startsWith('$alias.') || key.startsWith('main.$alias.'));
    final onAffinities = <String, String>{};
    final onCollations = <String, String>{};
    Map<String, Object?> scope(RowValues row) {
      final result = <String, Object?>{...?outer?.row, ...row};
      for (final entry in refs.entries) {
        result.remove(entry.key);
        if (entry.value.length == 1) {
          result[entry.key] = row[entry.value.single];
        }
      }
      return result;
    }

    EvalContext onContext(RowValues row) {
      final values = Map<String, Object?>.of(row);
      for (final entry in mergedValues.entries) {
        if (values.containsKey(entry.key)) continue;
        final (left, right, join) = entry.value;
        if (join == 'RIGHT' && values.containsKey(right)) {
          values[entry.key] = values[right];
        } else if (join == 'FULL' &&
            values.containsKey(left) &&
            values.containsKey(right)) {
          values[entry.key] = values[left] ?? values[right];
        } else if (join != 'RIGHT' &&
            join != 'FULL' &&
            values.containsKey(left)) {
          values[entry.key] = values[left];
        }
      }
      final visible = <String, Object?>{
        ...?outer?.row,
        for (final entry in values.entries)
          if (!identityKey(entry.key)) entry.key: entry.value,
      };
      for (final name in refs.keys) {
        visible.remove(name);
        if (onRefs[name]?.length == 1) {
          visible[name] = values[onRefs[name]!.single];
        }
      }
      return EvalContext(
          visible, onAffinities, bound, _pager.header.textEncoding)
        ..inTrigger = outer?.inTrigger ?? false
        ..collations = onCollations
        ..columnAliases = onAliases
        ..subquery = subquery;
    }

    bool matchesOn(Expr expression, EvalContext context) {
      if (expression is BinaryExpr && expression.op == 'AND') {
        return matchesOn(expression.left, context) &&
            matchesOn(expression.right, context);
      }
      if (expression is BinaryExpr && expression.op == 'OR') {
        return matchesOn(expression.left, context) ||
            matchesOn(expression.right, context);
      }
      return truth(expression.evaluate(context), context.encoding) == true;
    }

    for (var index = 0; index < sources.length; index++) {
      final source = sources[index];
      CatalogTable table;
      List<RowValues> rows;
      _JoinedGroup? group;
      final pragmaEntry = source.table == null
          ? null
          : cache[source.schema == null
              ? asciiLower(source.table!)
              : 'main.${asciiLower(source.table!)}'];
      final pragmaSource = _isPragmaTableSource(source) &&
          (source.pragmaArguments != null || pragmaEntry?.$1.rootPage == -1);
      final precedingRefs = {
        for (final entry in refs.entries)
          if (entry.value.length == 1) entry.key: entry.value.single
      };
      final precedingColumns = Map<String, CatalogColumn>.of(declared);
      final pragmaKnown = {
        ...declared.keys,
        ...precedingRefs.keys,
        ...?outer?.row.keys
      };
      final (pragmaArguments, consumedConditions) = pragmaSource
          ? _pragmaSourceArguments(source, s, pragmaKnown)
          : (const <Expr>[], const <Expr>{});
      consumedPragmaConditions.addAll(consumedConditions);
      for (final expression in pragmaArguments) {
        if (expression.containsAggregate || expression.containsWindow) {
          throw const SqlException('Aggregate or window in a PRAGMA source');
        }
        expression.validate(pragmaKnown);
      }
      bool localReference(Expr expression) =>
          expression is ColumnExpr &&
              (declared.containsKey(expression.key) ||
                  precedingRefs.containsKey(expression.key)) ||
          expression.children.any(localReference);
      if (pragmaSource &&
          ['RIGHT', 'FULL'].contains(source.join) &&
          pragmaArguments.any(localReference)) {
        throw const SqlException('Correlated PRAGMA source in RIGHT/FULL JOIN');
      }
      if (pragmaSource) {
        table = _pragmaSourceTable(source);
        rows = [];
      } else if (source.group.isNotEmpty) {
        group = _JoinedGroup('${sourceGroup?.prefix ?? ''}.$index');
        final query = SelectStatement(
            [], null, null, [], null, null, false, s.parameterCount)
          ..sources.addAll(source.group);
        _relational(query, bound, cache, outer,
            mutationSubqueries: mutationSubqueries,
            mutationCtes: mutationCtes,
            sourceGroup: group);
        group.materialize(source.alias);
        table = CatalogTable('@group$index', 0, [], withoutRowid: true);
        rows = group.rows;
      } else if (source.query != null) {
        final query = source.query!;
        final metadata = _pragmaColumnMetadata(query, cache, outerMetadata);
        final names = _relationColumnNames(
            metadata.map((column) => column.name).toList());
        table = CatalogTable(
            '@$index',
            0,
            [
              for (var i = 0; i < names.length; i++)
                CatalogColumn(names[i], metadata[i].declaredType,
                    affinityOverride: metadata[i].affinity,
                    collation: metadata[i].collation.isEmpty
                        ? 'binary'
                        : metadata[i].collation)
            ],
            withoutRowid: true);
        rows = _QueryRelationRows(
            query,
            names,
            (query, deferred) => _relationalExecution(
                query, bound, cache, outer,
                mutationSubqueries: mutationSubqueries,
                mutationCtes: mutationCtes,
                deferredProjection: deferred),
            describe: (query) =>
                _pragmaColumnMetadata(query, cache, outerMetadata));
      } else {
        final entry = cache[source.schema == null
            ? asciiLower(source.table!)
            : 'main.${asciiLower(source.table!)}'];
        if (entry == null) {
          throw SqlException('Unknown or circular source: ${source.table}');
        }
        (table, rows) = entry;
      }
      final alias = asciiLower(source.alias ?? source.table ?? '@$index');
      if (rows is _QueryRelationRows) {
        final prepared =
            _prepareRelationSource(rows, s, source, alias, index, subquery);
        rows = prepared.$1;
        if (prepared.$2 != null) s = prepared.$2!;
      }
      if (group == null) {
        if (!aliases.add(alias)) {
          throw const SqlException('Duplicate table alias');
        }
      } else {
        for (final name in group.aliases) {
          if (!aliases.add(name)) {
            throw const SqlException('Duplicate table alias');
          }
        }
      }
      final rightNames = group == null
          ? {for (final c in table.columns) asciiLower(c.name)}
          : {for (final slot in group.star) asciiLower(slot.$1)};
      final leftNames = star.map((c) => asciiLower(c.$1)).toSet();
      final using = source.natural
          ? leftNames.where(rightNames.contains).toSet()
          : source.using.map(asciiLower).toSet();
      for (final name in using) {
        if (!leftNames.contains(name) || !rightNames.contains(name)) {
          throw SqlException('USING column missing: $name');
        }
        if (['RIGHT', 'FULL'].contains(source.join) && refs[name]!.length > 1) {
          throw SqlException('Ambiguous USING column: $name');
        }
      }
      final leftRefs = {for (final name in using) name: refs[name]!.first};
      final leftColumns = {
        for (final name in using)
          name: joinColumns[leftRefs[name]] ?? declared[leftRefs[name]]!
      };
      final rightKeys = <String>{};
      final allStar = <(String, String)>[];
      final rightRefs = <String, String>{};
      if (group != null) {
        rightKeys.addAll(group.declared.keys);
        declared.addAll(group.declared);
        labels.addAll(group.labels);
        canonical.addAll(group.canonical);
        fieldOrder.addAll(group.fieldOrder);
        implicitRefs.addAll(group.implicit);
        nestedImplicit
            .addAll(group.implicit.map((key) => group!.canonical[key] ?? key));
        nestedImplicit.addAll(group.nestedImplicit);
        sourceStars.addAll(group.sourceStars);
        for (final entry in group.refs.entries) {
          final actual =
              entry.value.where((key) => !group!.implicit.contains(key));
          if (actual.isNotEmpty) {
            refs[entry.key]?.removeWhere(implicitRefs.contains);
          }
          final visible = actual.isNotEmpty
              ? actual
              : refs[entry.key]?.any((key) => !implicitRefs.contains(key)) ==
                      true
                  ? const <String>[]
                  : entry.value;
          refs.putIfAbsent(entry.key, () => []).addAll(visible);
        }
        for (final slot in group.star) {
          final name = asciiLower(slot.$1);
          rightRefs.putIfAbsent(name, () => slot.$2);
          if (!using.contains(name)) star.add(slot);
        }
      } else {
        final available = [
          ...table.columns,
          if (source.rowIdentity != null)
            CatalogColumn(source.rowIdentity!, 'INTEGER')
        ];
        if (!table.withoutRowid) {
          for (final name in ['rowid', '_rowid_', 'oid']) {
            if (!rightNames.contains(name)) {
              available.add(CatalogColumn(name, 'INTEGER'));
            }
          }
        }
        for (final column in available) {
          final name = asciiLower(column.name);
          final key = '$alias.$name';
          rightKeys.add(key);
          declared[key] = column;
          canonical[key] = key;
          if (source.table != null &&
              (table.rootPage > 0 ||
                  identical(
                      cache[source.schema == null
                          ? asciiLower(source.table!)
                          : 'main.${asciiLower(source.table!)}'],
                      cache['main.${asciiLower(source.table!)}']))) {
            declared['main.$key'] = column;
            canonical['main.$key'] = key;
            rightKeys.add('main.$key');
            labels['main.$key'] = column.name;
          }
          labels[key] = rightNames.contains(name)
              ? column.name
              : table.rowidAlias ?? 'rowid';
          if (rightNames.contains(name)) {
            refs[name]?.removeWhere(implicitRefs.contains);
            refs.putIfAbsent(name, () => []).add(key);
          } else {
            implicitRefs.add(key);
            if (!(refs[name]?.any((k) => !implicitRefs.contains(k)) ?? false)) {
              refs.putIfAbsent(name, () => []).add(key);
            }
          }
          if (rightNames.contains(name) && !column.hidden) {
            allStar.add((column.name, key));
            if (!using.contains(name)) star.add((column.name, key));
          }
        }
        sourceStars[alias] = allStar;
        final implicitKeys = implicitRefs.intersection(rightKeys).toList();
        final rowidKey = implicitKeys.firstOrNull;
        for (final key in rightKeys) {
          canonical.putIfAbsent(key, () => key);
          if (implicitKeys.contains(canonical[key]) && rowidKey != null) {
            canonical[key] = rowidKey;
          }
        }
        fieldOrder.addAll([
          ...allStar.map((slot) => slot.$2),
          if (rowidKey != null) rowidKey,
        ]);
        for (final name in rightNames) {
          rightRefs[name] = '$alias.$name';
        }
      }
      final mergedKeys = <String>{};
      for (final name in using) {
        final rightKey = rightRefs[name]!;
        final mergedKey =
            '\u0000using${sourceGroup?.prefix ?? ''}.$index.$name';
        mergedKeys.add(mergedKey);
        if (ambiguousMerged.contains(leftRefs[name]) ||
            group != null &&
                ['RIGHT', 'FULL'].contains(source.join) &&
                (group.refs[name]?.length ?? 0) > 1) {
          ambiguousMerged.add(mergedKey);
        }
        joinColumns[mergedKey] = leftColumns[name]!;
        mergedValues[mergedKey] = (leftRefs[name]!, rightKey, source.join);
        declared[mergedKey] = source.join == 'RIGHT'
            ? declared[rightKey]!
            : source.join == 'FULL'
                ? CatalogColumn(name, '',
                    affinityOverride: 'none', collation: '')
                : declared[leftRefs[name]]!;
        labels[mergedKey] = declared[mergedKey]!.name;
        for (final slot in sourceStars.values.expand((slots) => slots)) {
          if ((wildcardOverrides[slot.$2] ?? slot.$2) == leftRefs[name]) {
            wildcardOverrides[slot.$2] = mergedKey;
          }
        }
        refs[name] = [
          for (final key in refs[name]!)
            if (key == leftRefs[name])
              mergedKey
            else if (key != rightKey &&
                !(group != null &&
                    !['RIGHT', 'FULL'].contains(source.join) &&
                    (group.refs[name]?.contains(key) ?? false)))
              key
        ];
        for (var i = 0; i < star.length; i++) {
          if (star[i].$2 == leftRefs[name]) {
            star[i] = (star[i].$1, mergedKey);
            break;
          }
        }
      }
      final af = <String, String>{
        ...?outer?.affinities,
        for (final e in declared.entries) e.key: e.value.affinity,
        for (final e in refs.entries)
          if (e.value.length == 1) e.key: declared[e.value.first]!.affinity
      };
      final cs = <String, String>{
        ...?outer?.collations,
        for (final e in declared.entries) e.key: e.value.collation,
        for (final e in refs.entries)
          if (e.value.length == 1) e.key: declared[e.value.first]!.collation
      };
      Iterable<RowValues> qualifyRows(Iterable<RowValues> input) sync* {
        var rowIndex = 0;
        for (final row in input) {
          yield {
            for (final key in rightKeys)
              key: source.rowIdentity != null &&
                      key == '$alias.${source.rowIdentity}'
                  ? BigInt.from(rowIndex + 1)
                  : row[key.substring((key.startsWith('main.$alias.') ? 5 : 0) +
                      alias.length +
                      1)],
            for (final entry in row.entries)
              if (entry.key.startsWith('\u0000relation')) entry.key: entry.value
          };
          rowIndex++;
        }
      }

      final right = group != null ? rows : qualifyRows(rows);
      Iterable<RowValues> rightFor(RowValues left) {
        if (!pragmaSource) return right;
        final context = EvalContext({
          ...?outer?.row,
          ...left,
          for (final entry in precedingRefs.entries)
            entry.key: left[entry.value]
        }, {
          ...?outer?.affinities,
          for (final entry in precedingColumns.entries)
            entry.key: entry.value.affinity,
          for (final entry in precedingRefs.entries)
            entry.key: precedingColumns[entry.value]!.affinity
        }, bound, _pager.header.textEncoding)
          ..inTrigger = outer?.inTrigger ?? false
          ..collations = {
            ...?outer?.collations,
            for (final entry in precedingColumns.entries)
              entry.key: entry.value.collation,
            for (final entry in precedingRefs.entries)
              entry.key: precedingColumns[entry.value]!.collation
          }
          ..subquery = subquery;
        return qualifyRows(_pragmaSourceRows(source, pragmaArguments, context));
      }

      for (final key in rightKeys) {
        columnStages[key] = index;
      }
      for (final key in mergedKeys) {
        final (left, right, join) = mergedValues[key]!;
        columnStages[key] =
            join == 'RIGHT' || join == 'FULL' ? index : columnStages[left]!;
      }
      // Rowid access bounds are applied by SQLite's source scan before ON
      // callbacks, even when the textual predicate follows a callback term.
      final rowidKeys = {
        if (!table.withoutRowid && table.rootPage > 0) ...{
          if (table.rowidAlias != null)
            '$alias.${asciiLower(table.rowidAlias!)}',
          for (final name in ['rowid', '_rowid_', 'oid'])
            if (!table.columns.any((column) => asciiLower(column.name) == name))
              '$alias.$name'
        }
      };
      bool scanConstant(Expr expression) =>
          expression is Literal ||
          expression is ParameterExpr ||
          expression is UnaryExpr && expression.children.every(scanConstant);
      Iterable<Expr> rowidBounds(Expr? expression) sync* {
        if (expression is BinaryExpr && expression.op == 'AND') {
          yield* rowidBounds(expression.left);
          yield* rowidBounds(expression.right);
        } else if (expression is BinaryExpr &&
            ['=', '==', '<', '<=', '>', '>='].contains(expression.op)) {
          final left = indexOperand(expression.left),
              right = indexOperand(expression.right);
          if (left is ColumnExpr &&
                  rowidKeys.contains(left.key.replaceFirst('main.', '')) &&
                  scanConstant(right) ||
              right is ColumnExpr &&
                  rowidKeys.contains(right.key.replaceFirst('main.', '')) &&
                  scanConstant(left)) {
            yield expression;
          }
        }
      }

      final scanBounds = ['RIGHT', 'FULL'].contains(source.join)
          ? const <Expr>[]
          : rowidBounds(source.on).toList();
      final leftKeys = Set<String>.of(keysBefore);
      joinSteps.add((leftRows) sync* {
        RowValues merge(RowValues row) {
          for (final key in mergedKeys) {
            final (left, right, join) = mergedValues[key]!;
            row[key] = join == 'RIGHT'
                ? row[right]
                : join == 'FULL'
                    ? row[left] ?? row[right]
                    : row[left];
          }
          return row;
        }

        final matched = <int>{};
        Iterable<RowValues> combine() sync* {
          for (final left in leftRows) {
            var found = false;
            var r = -1;
            for (final rightRow in rightFor(left)) {
              r++;
              final combined = merge({...left, ...rightRow});
              if (scanBounds.isNotEmpty &&
                  scanBounds.any((bound) =>
                      truth(bound.evaluate(onContext(combined)),
                          _pager.header.textEncoding) !=
                      true)) {
                continue;
              }
              var equal = true;
              for (final name in using) {
                final rightKey = rightRefs[name]!;
                final leftValue = combined[leftRefs[name]];
                final ctx = EvalContext({
                  ...combined,
                  '@left': applyAffinity(leftValue, leftColumns[name]!.affinity)
                }, {
                  ...af,
                  '@left': leftColumns[name]!.affinity
                }, bound, _pager.header.textEncoding)
                  ..collations = {...cs, '@left': leftColumns[name]!.collation};
                if (BinaryExpr('=', ColumnExpr('@left'), ColumnExpr(rightKey))
                        .evaluate(ctx) !=
                    BigInt.one) {
                  equal = false;
                  break;
                }
              }
              if (!equal) continue;
              final ctx = onContext(combined);
              if (source.on != null &&
                  onStages[source]! <= index &&
                  !matchesOn(onConditions[source]!, ctx)) {
                continue;
              }
              found = true;
              matched.add(r);
              yield combined;
            }
            if (!found && ['LEFT', 'FULL'].contains(source.join)) {
              yield merge({...left, for (final key in rightKeys) key: null});
            }
          }
          if (['RIGHT', 'FULL'].contains(source.join)) {
            var r = -1;
            for (final rightRow in rightFor({})) {
              r++;
              if (!matched.contains(r)) {
                yield merge(
                    {for (final key in leftKeys) key: null, ...rightRow});
              }
            }
          }
        }

        yield* combine().where((row) {
          for (var earlier = 0; earlier < index; earlier++) {
            final pending = sources[earlier];
            if (pending.on != null && onStages[pending] == index) {
              final context = onContext(row);
              if (!matchesOn(onConditions[pending]!, context)) {
                return false;
              }
            }
          }
          return true;
        });
      });
      keysBefore = {...keysBefore, ...rightKeys, ...mergedKeys};
    }
    for (final entry in refs.entries) {
      final visible = entry.value.where((key) => !identityKey(key)).toList();
      if (visible.isNotEmpty) onRefs[entry.key] = visible;
    }
    final known = <String>{
      for (final key in declared.keys)
        if (!identityKey(key)) key,
      ...?outer?.row.keys,
      for (final entry in onRefs.entries)
        if (entry.value.length == 1) entry.key,
    };
    void checkGroupBinding(Expr expression) {
      if (expression is ColumnExpr) {
        final key =
            expression.qualifier == null && refs[expression.key]?.length == 1
                ? refs[expression.key]!.single
                : expression.key;
        if (inaccessibleGroupQualifiers
            .any((alias) => key.startsWith('$alias.'))) {
          throw SqlException('No such grouped column: ${expression.name}');
        }
      }
      for (final child in expression.children) {
        checkGroupBinding(child);
      }
    }

    if (inaccessibleGroupQualifiers.isNotEmpty) {
      _expressions(s).forEach(checkGroupBinding);
    }
    onAffinities.addAll({
      ...?outer?.affinities,
      for (final entry in declared.entries)
        if (!identityKey(entry.key)) entry.key: entry.value.affinity,
      for (final entry in onRefs.entries)
        if (entry.value.length == 1)
          entry.key: declared[entry.value.single]!.affinity,
    });
    onCollations.addAll({
      ...?outer?.collations,
      for (final entry in declared.entries)
        if (!identityKey(entry.key)) entry.key: entry.value.collation,
      for (final entry in onRefs.entries)
        if (entry.value.length == 1)
          entry.key: declared[entry.value.single]!.collation,
    });
    for (final item in s.items) {
      final name = asciiLower(item.label);
      if (item.expression != null &&
          !known.contains(name) &&
          !onRefs.containsKey(name)) {
        onAliases.putIfAbsent(name, () => item.expression!);
      }
    }
    Iterable<String> references(Expr expr,
        [Set<String> local = const {}]) sync* {
      if (expr is ColumnExpr && !local.contains(expr.key)) yield expr.key;
      for (final nested in [
        if (expr is SubqueryExpr) expr.statement,
        if (expr is InSelectExpr) expr.statement,
      ]) {
        final shadow = {...local};
        for (final source in nested.sources) {
          final alias = asciiLower(source.alias ?? source.table ?? '');
          final table = source.table == null
              ? null
              : cache[source.schema == null
                      ? asciiLower(source.table!)
                      : 'main.${asciiLower(source.table!)}']
                  ?.$1;
          final names = table != null
              ? table.columns.map((column) => asciiLower(column.name))
              : source.query?.items.map((item) => asciiLower(item.label)) ??
                  nested.ctes[asciiLower(source.table ?? '')]?.$1
                      .map(asciiLower) ??
                  const <String>[];
          for (final name in names) {
            shadow.add(name);
            shadow.add('$alias.$name');
            if (table != null) shadow.add('main.$alias.$name');
          }
        }
        for (final expression in _expressions(nested)) {
          yield* references(expression, shadow);
        }
      }
      for (final child in expr.children) {
        yield* references(child, local);
      }
    }

    int stage(Expr expression) {
      var result = -1;
      for (final name in references(expression)) {
        final alias = known.contains(name) ? null : onAliases[name];
        if (alias != null) {
          alias.validate(known);
          if (alias.containsAggregate || alias.containsWindow) {
            throw const SqlException('Aggregate or window alias in JOIN ON');
          }
          final value = stage(alias);
          if (value > result) result = value;
        } else {
          final key = onRefs[name]?.length == 1 ? onRefs[name]!.single : name;
          final value = columnStages[key] ?? -1;
          if (value > result) result = value;
        }
      }
      return result;
    }

    Expr preparedOn(Expr expression) {
      if (expression is! BinaryExpr || !['AND', 'OR'].contains(expression.op)) {
        return expression;
      }
      final left = preparedOn(expression.left),
          right = preparedOn(expression.right);
      bool zero(Expr operand) =>
          operand is Literal &&
          operand.spelling == null &&
          operand.value == BigInt.zero;
      if (expression.op == 'AND' && (zero(left) || zero(right))) {
        return Literal(BigInt.zero);
      }
      return BinaryExpr(expression.op, left, right);
    }

    for (var index = 0; index < sources.length; index++) {
      final source = sources[index], condition = source.on;
      if (condition == null) continue;
      if (condition.containsAggregate || condition.containsWindow) {
        throw const SqlException('Aggregate or window in JOIN ON');
      }
      final prepared = preparedOn(
          _omitPragmaConstraints(condition, consumedPragmaConditions));
      prepared.validate({...known, ...onAliases.keys});
      onConditions[source] = prepared;
      final ready = stage(prepared);
      if (ready > index &&
          (['LEFT', 'RIGHT', 'FULL'].contains(source.join) ||
              sources
                  .skip(index + 1)
                  .take(ready - index)
                  .any((later) => ['RIGHT', 'FULL'].contains(later.join)))) {
        throw const SqlException('ON clause references tables to its right');
      }
      onStages[source] = ready > index ? ready : index;
    }
    final columns = <CatalogColumn>[
      ...declared.entries.map((e) => CatalogColumn(e.key, e.value.declaredType,
          affinityOverride: e.value.affinity, collation: e.value.collation))
    ];
    for (final entry in refs.entries) {
      if (entry.value.length == 1) {
        final original = declared[entry.value.first]!;
        columns.add(CatalogColumn(original.name, original.declaredType,
            affinityOverride: original.affinity,
            collation: original.collation));
      }
    }
    if (outer != null) {
      for (final name in outer.row.keys) {
        if (!columns.any((c) => asciiLower(c.name) == name)) {
          columns.add(CatalogColumn(
              name, _affinityType(outer.affinities[name] ?? 'none'),
              affinityOverride: outer.affinities[name] ?? 'none',
              collation: outer.collations[name] ?? 'binary'));
        }
      }
    }
    _prepareScalarMetadata(s, cache, columns);
    for (final step in joinSteps) {
      joined = step(joined);
    }
    if (sourceGroup != null) {
      sourceGroup.rows = joined.toList();
      sourceGroup.aliases.addAll(aliases);
      sourceGroup.declared.addAll(declared);
      sourceGroup.refs.addAll(refs);
      sourceGroup.implicit.addAll(implicitRefs);
      sourceGroup.nestedImplicit.addAll(nestedImplicit);
      sourceGroup.labels.addAll(labels);
      for (final key in implicitRefs) {
        sourceGroup.labels[key] = '_ROWID_';
      }
      sourceGroup.star.addAll(star);
      sourceGroup.sourceStars.addAll(sourceStars);
      sourceGroup.canonical.addAll(canonical);
      sourceGroup.fieldOrder.addAll(fieldOrder);
      return _QueryExecution(star.map((slot) => slot.$1).toList(), [
        for (final row in sourceGroup.rows)
          [for (final slot in star) row[slot.$2]]
      ], [], [], []);
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
        for (final slot in list) {
          final key = soleAliasedGroup
              ? slot.$1
              : item.label == '*'
                  ? slot.$2
                  : wildcardOverrides[slot.$2] ?? slot.$2;
          if (ambiguousMerged.contains(key)) {
            throw const SqlException('Ambiguous joined wildcard column');
          }
          items.add(SelectItem(ColumnExpr(key), slot.$1, explicitAlias: true));
        }
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
    if (inaccessibleGroupQualifiers.isNotEmpty) {
      for (final item in items) {
        if (item.expression != null) checkGroupBinding(item.expression!);
      }
    }
    final virtual = CatalogTable('@scope', 0, columns, withoutRowid: true);
    final component = _copy(s, items,
        tail: s.compounds.isEmpty, omitConditions: consumedPragmaConditions);
    Iterable<RowValues> inputs = joined.map(scope);
    var inputOrdered = false;
    if (sources.length == 1 && s.compounds.isEmpty) {
      final source = sources.single;
      if (source.table != null &&
          source.query == null &&
          source.group.isEmpty &&
          !_isPragmaTableSource(source)) {
        final physical = cache[source.schema == null
                ? asciiLower(source.table!)
                : 'main.${asciiLower(source.table!)}']
            ?.$1;
        if (physical != null && physical.rootPage > 0) {
          final alias = asciiLower(source.alias ?? source.table!);
          final scanOrder = _physicalScanOrder(s, physical, prefix: '$alias.');
          if (scanOrder != null) {
            final ordered = inputs.toList();
            _sortPhysicalRows(ordered, scanOrder);
            inputs = ordered;
            inputOrdered = true;
          }
        }
      }
    }
    var result = _evaluate(component, bound, virtual, inputs,
        inTrigger: outer?.inTrigger ?? false,
        subquery: subquery,
        omitProjection: s.subqueryExists &&
            s.compounds.every((part) => part.$1 == 'UNION ALL'),
        inputOrdered: inputOrdered,
        deferredProjection: deferredProjection);
    if (s.compounds.isEmpty) return result;
    final operands = [
      for (final part in s.compounds)
        (
          part.$1,
          _relationalExecution(
              part.$2
                ..subqueryExists = s.subqueryExists &&
                    s.compounds.every((part) => part.$1 == 'UNION ALL'),
              bound,
              cache,
              outer,
              mutationSubqueries: mutationSubqueries,
              mutationCtes: mutationCtes,
              deferredProjection: deferredProjection)
        )
    ];
    for (final part in operands) {
      if (part.$2.columns.length != result.columns.length) {
        throw const SqlException('Compound SELECT width mismatch');
      }
    }
    int count(Expr? expr, int fallback) {
      if (expr == null) return fallback;
      expr.validate({});
      var value = expr.evaluate(
          EvalContext({}, {}, bound, _pager.header.textEncoding)
            ..inTrigger = outer?.inTrigger ?? false);
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
    final compoundCollations = result.columnCollations.toList();
    final positions = <int>[];
    if (s.order.isNotEmpty) {
      for (final term in s.order) {
        final expr = indexOperand(term.expression);
        final ordinal = expressionOrdinal(term.expression);
        var index = ordinal == null ? -1 : ordinal.toInt() - 1;
        if (ordinal == null && expr is ColumnExpr) {
          index =
              result.columns.indexWhere((name) => asciiLower(name) == expr.key);
        }
        if (ordinal == null && index < 0) {
          for (final component in [s, ...s.compounds.map((part) => part.$2)]) {
            index = component.items.indexWhere((item) =>
                expr is ColumnExpr &&
                    item.explicitAlias &&
                    asciiLower(item.label) == expr.key ||
                item.expression != null &&
                    sameExpression(expr, indexOperand(item.expression!)));
            if (index >= 0) break;
          }
        }
        if (index < 0 || index >= result.columns.length) {
          throw const SqlException(
              'Compound ORDER BY must name an output expression');
        }
        positions.add(index);
      }
    }
    for (final part in operands) {
      for (var i = 0; i < compoundCollations.length; i++) {
        if (compoundCollations[i].isEmpty) {
          compoundCollations[i] = part.$2.columnCollations[i];
        }
      }
    }
    Iterable<List<Object?>> compoundRows() sync* {
      if (limit == 0) return;
      if (s.order.isEmpty && operands.every((part) => part.$1 == 'UNION ALL')) {
        final consumerOffset = _QueryOffset(offset < 0 ? 0 : offset);
        Iterable<List<Object?>> concatenate() sync* {
          yield* result.consume(consumerOffset);
          for (final part in operands) {
            yield* part.$2.consume(consumerOffset);
          }
        }

        var selected = concatenate();
        if (limit >= 0) selected = selected.take(limit);
        yield* selected;
        return;
      }
      var values = result.rows.map((row) => row.toList()).toList();
      bool same(List<Object?> a, List<Object?> b) {
        for (var i = 0; i < a.length; i++) {
          if (compareValues(a[i], b[i], _pager.header.textEncoding,
                  compoundCollations[i]) !=
              0) {
            return false;
          }
        }
        return true;
      }

      for (final part in operands) {
        final rhs = part.$2.materialize();
        if (rhs.columns.length != result.columns.length) {
          throw const SqlException('Compound SELECT width mismatch');
        }
        for (var i = 0; i < compoundCollations.length; i++) {
          if (compoundCollations[i].isEmpty) {
            compoundCollations[i] = rhs.columnCollations[i];
          }
        }
        if (part.$1 == 'UNION ALL') {
          values.addAll(rhs.rows);
        } else if (part.$1 == 'UNION') {
          values.addAll(rhs.rows);
          final unique = <List<Object?>>[];
          for (final row in values) {
            unique.removeWhere((old) => same(old, row));
            unique.add(row);
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
        if (part.$1 != 'UNION ALL') {
          values.sort((a, b) {
            for (var i = 0; i < a.length; i++) {
              final comparison = compareValues(a[i], b[i],
                  _pager.header.textEncoding, compoundCollations[i]);
              if (comparison != 0) return comparison;
            }
            return 0;
          });
        }
      }
      if (s.order.isNotEmpty) {
        values.sort((a, b) {
          final context =
              EvalContext({}, {}, bound, _pager.header.textEncoding);
          for (var i = 0; i < positions.length; i++) {
            final term = s.order[i], slot = positions[i];
            final collation = term.expression.explicitCollation(context) ??
                compoundCollations[slot];
            final order = OrderTerm(
                CollateExpr(
                    Literal(null), collation.isEmpty ? 'binary' : collation),
                term.descending,
                term.nullsFirst);
            final comparison = order.compare(a[slot], b[slot], context);
            if (comparison != 0) return comparison;
          }
          return 0;
        });
      }

      var selected = values.skip(offset < 0 ? 0 : offset);
      if (limit >= 0) selected = selected.take(limit);
      yield* selected;
    }

    return _QueryExecution(
        result.columns,
        compoundRows(),
        result.columnAffinities,
        result.columnDeclaredTypes,
        compoundCollations);
  }
}

/// Stable priority queue; equal priorities preserve SQLite's FIFO extraction.
final class _CteWorkQueue {
  _CteWorkQueue(this.compare);
  final int Function(List<Object?>, List<Object?>) compare;
  final List<(int, List<Object?>)> _heap = [];
  int _sequence = 0;
  bool get isNotEmpty => _heap.isNotEmpty;
  int _compare((int, List<Object?>) a, (int, List<Object?>) b) {
    final result = compare(a.$2, b.$2);
    return result == 0 ? a.$1.compareTo(b.$1) : result;
  }

  void add(List<Object?> row) {
    final entry = (_sequence++, row);
    _heap.add(entry);
    var slot = _heap.length - 1;
    while (slot > 0) {
      final parent = (slot - 1) ~/ 2;
      if (_compare(_heap[parent], entry) <= 0) break;
      _heap[slot] = _heap[parent];
      slot = parent;
    }
    _heap[slot] = entry;
  }

  List<Object?> removeFirst() {
    final result = _heap.first.$2, last = _heap.removeLast();
    if (_heap.isEmpty) return result;
    var slot = 0;
    while (slot * 2 + 1 < _heap.length) {
      var child = slot * 2 + 1;
      if (child + 1 < _heap.length &&
          _compare(_heap[child + 1], _heap[child]) < 0) {
        child++;
      }
      if (_compare(last, _heap[child]) <= 0) break;
      _heap[slot] = _heap[child];
      slot = child;
    }
    _heap[slot] = last;
    return result;
  }
}
