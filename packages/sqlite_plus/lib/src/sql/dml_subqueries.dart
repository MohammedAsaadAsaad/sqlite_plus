part of 'database.dart';

/// Prepared, synchronous subqueries for image mutations. Physical relations may
/// be supplied again before each evaluation so correlated SET/RETURNING queries
/// see earlier writes, while uncorrelated queries keep SQLite's lazy once value.
extension MutationSubqueries on SqliteDatabase {
  Future<SqlRows Function(SelectStatement, EvalContext)> prepareSubqueries(
      Iterable<Expr> expressions,
      {Map<String, (CatalogTable, List<RowValues>)> Function(Set<String>)?
          relations,
      Map<SelectStatement, (CatalogTable, List<RowValues>)?>?
          materializedCtes}) async {
    final queries = <SelectStatement>{};
    for (final expression in expressions) {
      queries.addAll(_nested(expression));
    }
    final cache = <String, (CatalogTable, List<RowValues>)>{};
    for (final query in queries) {
      await _loadRelations(query, cache, <String>{});
    }
    final schemas = {
      for (final entry in cache.entries)
        for (final name in {
          entry.key,
          if (entry.key.startsWith('main.')) entry.key.substring(5)
        })
          name: (
            columns:
                entry.value.$1.columns.map((column) => column.name).toList(),
            rowid: !entry.value.$1.withoutRowid
          )
    };
    for (final query in queries) {
      prepareSubqueryWidths(query, schemas);
    }
    // Width-dependent scalar/row validation also applies to the enclosing
    // mutation expression, even when its target has no rows to evaluate.
    for (final expression in expressions) {
      final names = <String>{};
      void columns(Expr value) {
        if (value is ColumnExpr) names.add(value.key);
        for (final child in value.children) {
          columns(child);
        }
      }

      columns(expression);
      expression.validate(names);
    }
    final views = <String, SelectStatement>{};
    for (final entry in catalog.entries.where((entry) =>
        entry.type == 'view' &&
        cache.keys.any((key) =>
            key == asciiLower(entry.name) ||
            key == 'main.${asciiLower(entry.name)}'))) {
      final parser = SqlParser(entry.sql!);
      parser.require('CREATE');
      parser.require('VIEW');
      if (parser.take('IF')) {
        parser.require('NOT');
        parser.require('EXISTS');
      }
      parser.identifier();
      if (parser.take('(')) {
        do {
          parser.identifier();
        } while (parser.take(','));
        parser.require(')');
      }
      parser.require('AS');
      final parsed =
          SqlParser(entry.sql!.substring(parser.current.offset)).select();
      for (final key in [
        asciiLower(entry.name),
        'main.${asciiLower(entry.name)}'
      ]) {
        if (cache.containsKey(key)) views[key] = parsed;
      }
    }
    final once = <SelectStatement, SqlRows>{};
    late SqlRows Function(SelectStatement, EvalContext,
        Map<String, (CatalogTable, List<RowValues>)>) run;
    run = (query, context, scope) {
      final correlated =
          _mutationCorrelated(query, scope, context.row.keys.toSet());
      if (!correlated && once.containsKey(query)) return once[query]!;
      if (relations != null) {
        scope.addAll(relations(scope.keys.toSet()));
        for (final entry in views.entries) {
          final schema = scope[entry.key]!.$1;
          scope[entry.key] = (
            schema,
            _DeferredRelationRows(() {
              final values = _relational(
                  entry.value, context.parameters, scope, null,
                  mutationSubqueries: run, mutationCtes: materializedCtes);
              return [
                for (final row in values.rows)
                  {
                    for (var i = 0; i < schema.columns.length; i++)
                      asciiLower(schema.columns[i].name): row[i]
                  }
              ];
            })
          );
        }
      }
      final result = _relational(query, context.parameters, scope, context,
          mutationSubqueries: run, mutationCtes: materializedCtes);
      if (!correlated) once[query] = result;
      return result;
    };
    return (query, context) => run(query, context, cache);
  }

  bool _mutationCorrelated(SelectStatement query,
      Map<String, (CatalogTable, List<RowValues>)> cache, Set<String> outer) {
    final activeRelations = <_QueryRelationRows>{};
    Set<String> output(
        SelectStatement s, Map<String, (List<String>, SelectStatement)> ctes,
        [Set<SelectStatement>? visiting]) {
      visiting ??= {};
      if (!visiting.add(s)) {
        return s.items.map((i) => asciiLower(i.label)).toSet();
      }
      final result = <String>{};
      for (final item in s.items) {
        if (item.expression != null) {
          result.add(asciiLower(item.label));
        } else {
          for (final source in s.leafSources) {
            final alias = asciiLower(source.alias ?? source.table ?? '');
            if (item.label != '*' && asciiLower(item.label) != '$alias.*') {
              continue;
            }
            if (source.query != null) {
              result.addAll(output(source.query!, ctes, visiting));
            } else {
              final name = source.schema == null
                  ? asciiLower(source.table!)
                  : 'main.${asciiLower(source.table!)}';
              final cte = source.schema == null ? ctes[name] : null;
              result.addAll(cte == null
                  ? cache[name]!.$1.columns.map((c) => asciiLower(c.name))
                  : cte.$1.isNotEmpty
                      ? cte.$1.map(asciiLower)
                      : output(cte.$2, ctes, visiting));
            }
          }
        }
      }
      visiting.remove(s);
      return result;
    }

    late bool Function(SelectStatement, Set<String>,
        Map<String, (List<String>, SelectStatement)>) visit;
    bool expression(Expr expr, Set<String> local,
        Map<String, (List<String>, SelectStatement)> ctes) {
      if (expr is ColumnExpr &&
          !local.contains(expr.key) &&
          !(expr.qualifier != null &&
              local.contains('${asciiLower(expr.qualifier!)}.*')) &&
          outer.contains(expr.key)) {
        return true;
      }
      if (expr is SubqueryExpr && visit(expr.statement, local, ctes)) {
        return true;
      }
      if (expr is InSelectExpr && visit(expr.statement, local, ctes)) {
        return true;
      }
      return expr.children.any((child) => expression(child, local, ctes));
    }

    visit = (s, inherited, inheritedCtes) {
      final ctes = {...inheritedCtes, ...s.ctes};
      final local = {...inherited};
      for (final source in s.leafSources) {
        Set<String> names;
        if (source.query != null) {
          names = output(source.query!, ctes);
        } else {
          final name = source.schema == null
              ? asciiLower(source.table!)
              : 'main.${asciiLower(source.table!)}';
          final cte = source.schema == null ? ctes[name] : null;
          final relation = cache[name]?.$2;
          if (cte == null &&
              relation is _QueryRelationRows &&
              activeRelations.add(relation)) {
            try {
              if (visit(relation.query, inherited, ctes)) return true;
            } finally {
              activeRelations.remove(relation);
            }
          }
          names = cte != null
              ? (cte.$1.isNotEmpty
                  ? cte.$1.map(asciiLower).toSet()
                  : output(cte.$2, ctes))
              : {
                  ...cache[name]!.$1.columns.map((c) => asciiLower(c.name)),
                  if (!cache[name]!.$1.withoutRowid) ...[
                    'rowid',
                    '_rowid_',
                    'oid'
                  ]
                };
        }
        final alias = asciiLower(source.alias ?? source.table ?? '@derived');
        local.addAll(names);
        local.addAll(names.map((name) => '$alias.$name'));
        local.add('$alias.*');
        if (source.schema != null) local.add('main.$alias.*');
      }
      // A joined group's qualified namespace also contains hidden physical
      // columns. It cannot be described with groupAlias.* (SQLite itself may
      // reject that wildcard). Binding validation remains with the executor;
      // here a local qualifier is sufficient to rule out outer correlation.
      for (final source in s.allSources) {
        if (source.group.isNotEmpty && source.alias != null) {
          local.add('${asciiLower(source.alias!)}.*');
        }
      }
      // SELECT aliases can bind in the clauses accepted by the query engine.
      local.addAll(s.items
          .where((i) => i.explicitAlias)
          .map((i) => asciiLower(i.label)));
      if (_expressions(s).any((e) => expression(e, local, ctes))) return true;
      if (s.limit != null && expression(s.limit!, local, ctes)) {
        return true;
      }
      if (s.offset != null && expression(s.offset!, local, ctes)) return true;
      if (usedCteNames(s)
          .any((name) => visit(s.ctes[name]!.$2, inherited, ctes))) {
        return true;
      }
      if (s.leafSources.any((source) =>
          source.query != null && visit(source.query!, inherited, ctes))) {
        return true;
      }
      return s.compounds.any((part) => visit(part.$2, inherited, ctes));
    };
    return visit(query, {}, {});
  }
}
