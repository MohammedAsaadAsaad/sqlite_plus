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
        final refreshed = <String>{};
        void refresh(String name) {
          if (!refreshed.add(name)) return;
          final view = views[name];
          if (view == null) return;
          // Views have already been cycle-checked while loading relations.
          Iterable<String> dependencies(SelectStatement statement,
              [Set<String> inheritedCtes = const {}]) sync* {
            final ctes = {...inheritedCtes, ...statement.ctes.keys};
            for (final source in statement.sources) {
              if (source.query != null) {
                yield* dependencies(source.query!, ctes);
              } else if (source.schema != null ||
                  !ctes.contains(asciiLower(source.table!))) {
                yield source.schema == null
                    ? asciiLower(source.table!)
                    : 'main.${asciiLower(source.table!)}';
              }
            }
            for (final cte in statement.ctes.values) {
              yield* dependencies(cte.$2, ctes);
            }
            for (final part in statement.compounds) {
              yield* dependencies(part.$2, ctes);
            }
            for (final expression in _expressions(statement)) {
              for (final nested in _nested(expression)) {
                yield* dependencies(nested, ctes);
              }
            }
          }

          dependencies(view).forEach(refresh);
          final schema = scope[name]!.$1;
          final values = _relational(view, context.parameters, scope, null,
              mutationSubqueries: run, mutationCtes: materializedCtes);
          scope[name] = (
            schema,
            [
              for (final row in values.rows)
                {
                  for (var i = 0; i < schema.columns.length; i++)
                    asciiLower(schema.columns[i].name): row[i]
                }
            ]
          );
        }

        views.keys.forEach(refresh);
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
          for (final source in s.sources) {
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
      for (final source in s.sources) {
        Set<String> names;
        if (source.query != null) {
          names = output(source.query!, ctes);
        } else {
          final name = source.schema == null
              ? asciiLower(source.table!)
              : 'main.${asciiLower(source.table!)}';
          final cte = source.schema == null ? ctes[name] : null;
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
      if (s.ctes.values.any((cte) => visit(cte.$2, inherited, ctes))) {
        return true;
      }
      if (s.sources.any((source) =>
          source.query != null && visit(source.query!, inherited, ctes))) {
        return true;
      }
      return s.compounds.any((part) => visit(part.$2, inherited, ctes));
    };
    return visit(query, {}, {});
  }
}
