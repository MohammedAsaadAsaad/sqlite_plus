part of 'database.dart';

/// Relation rows resume on demand. Repeated scans replay the already produced
/// prefix without forcing later callbacks, as a SQLite coroutine does.
final class _DeferredRelationRows extends ListBase<RowValues> {
  _DeferredRelationRows(this._evaluate);
  final Iterable<RowValues> Function() _evaluate;
  final List<RowValues> _rows = [];
  Iterator<RowValues>? _input;
  bool _complete = false;
  bool _evaluating = false;

  bool _advance() {
    if (_complete) return false;
    if (_evaluating) throw const SqlException('Circular relation evaluation');
    _evaluating = true;
    try {
      _input ??= _evaluate().iterator;
      if (_input!.moveNext()) {
        _rows.add(_input!.current);
        return true;
      }
      _complete = true;
      return false;
    } catch (_) {
      _input = null;
      _rows.clear();
      rethrow;
    } finally {
      _evaluating = false;
    }
  }

  @override
  Iterator<RowValues> get iterator => _iterate().iterator;
  Iterable<RowValues> _iterate() sync* {
    var index = 0;
    while (index < _rows.length || _advance()) {
      yield _rows[index++];
    }
  }

  @override
  int get length {
    while (_advance()) {}
    return _rows.length;
  }

  @override
  set length(int value) => throw UnsupportedError('Read-only relation rows');
  @override
  RowValues operator [](int index) {
    while (_rows.length <= index && _advance()) {}
    return _rows[index];
  }

  @override
  void operator []=(int index, RowValues value) =>
      throw UnsupportedError('Read-only relation rows');
}

/// Retain a relation's query until its consumer determines whether SQLite can
/// substitute expressions or requires a coroutine/materialization boundary.
final class _QueryRelationRows extends ListBase<RowValues> {
  _QueryRelationRows(this.query, this.names, this.execute,
      {this.materialized = false, this.cte = false, required this.describe});
  final SelectStatement query;
  final List<String> names;
  final _QueryExecution Function(SelectStatement, bool) execute;
  final List<CatalogColumn> Function(SelectStatement) describe;
  final bool materialized, cte;
  late final List<RowValues> values = _DeferredRelationRows(
      () => rows(execute(query, false)).toList(growable: false));

  Iterable<RowValues> rows(_QueryExecution execution,
      [List<String>? outputNames]) sync* {
    final labels = outputNames ?? names;
    for (final row in execution.rows) {
      yield {
        for (var i = 0; i < labels.length; i++)
          asciiLower(labels[i]): publishSqlValue(row[i])
      };
    }
  }

  @override
  Iterator<RowValues> get iterator => values.iterator;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only relation rows');
  @override
  RowValues operator [](int index) => values[index];
  @override
  void operator []=(int index, RowValues value) =>
      throw UnsupportedError('Read-only relation rows');
}

/// Sorting inherited from a flattened source evaluates the source expression
/// after the consumer's projections, using a hidden binding in the same row.
final class _RelationOrderExpr extends Expr {
  _RelationOrderExpr(this.key, this.columnCollation);
  final String key, columnCollation;
  @override
  String? collation(EvalContext context) =>
      columnCollation.isEmpty ? null : columnCollation;
  @override
  Object? evaluate(EvalContext context) => resolveSqlValue(context.row[key]);
}

final class _RelationPredicateExpr extends Expr {
  _RelationPredicateExpr(this.predicate);
  final Object? Function(EvalContext) predicate;
  @override
  Object? evaluate(EvalContext context) => predicate(context);
}

extension _DeferredQuerySources on SqliteDatabase {
  bool _queryReadsTable(SelectStatement statement, String target) {
    final wanted = asciiLower(target);
    final views = <String>{};
    final activeCtes = <SelectStatement>{};
    bool visit(
        SelectStatement query, Map<String, SelectStatement> inheritedCtes) {
      final ctes = <String, SelectStatement>{
        ...inheritedCtes,
        for (final entry in query.ctes.entries) entry.key: entry.value.$2
      };
      for (final source in query.leafSources) {
        if (source.query != null && visit(source.query!, ctes)) return true;
        if (source.table == null) continue;
        final name = asciiLower(source.table!);
        if (source.schema == null && ctes.containsKey(name)) {
          final cte = ctes[name]!;
          if (activeCtes.add(cte)) {
            try {
              if (visit(cte, ctes)) return true;
            } finally {
              activeCtes.remove(cte);
            }
          }
          continue;
        }
        if (name == wanted) return true;
        final entry = catalog.entries
            .where((entry) =>
                entry.type == 'view' && asciiLower(entry.name) == name)
            .firstOrNull;
        if (entry == null || !views.add(name)) continue;
        try {
          final parser = SqlParser(entry.sql!);
          parser.require('CREATE');
          parser.require('VIEW');
          if (parser.take('IF')) {
            parser.require('NOT');
            parser.require('EXISTS');
          }
          parser.qualifiedIdentifier();
          if (parser.take('(')) {
            do {
              parser.identifier();
            } while (parser.take(','));
            parser.require(')');
          }
          parser.require('AS');
          if (visit(parser.select(), const {})) return true;
        } finally {
          views.remove(name);
        }
      }
      for (final expression in _expressions(query)) {
        for (final nested in _nested(expression)) {
          if (visit(nested, ctes)) return true;
        }
      }
      for (final source in query.allSources) {
        for (final expression in source.pragmaArguments ?? const <Expr>[]) {
          for (final nested in _nested(expression)) {
            if (visit(nested, ctes)) return true;
          }
        }
      }
      return query.compounds.any((part) => visit(part.$2, ctes));
    }

    return visit(statement, const {});
  }

  SelectStatement _relationQuery(SelectStatement query,
          {List<SelectItem>? items,
          Expr? where,
          Expr? having,
          List<OrderTerm>? order,
          Expr? limitOverride,
          bool removeLimit = false,
          bool removeCompounds = false}) =>
      SelectStatement(
          items ?? query.items,
          query.table,
          where ?? query.where,
          order ?? query.order,
          limitOverride ?? (removeLimit ? null : query.limit),
          removeLimit ? null : query.offset,
          query.distinct,
          query.parameterCount)
        ..sources.addAll(query.sources)
        ..ctes.addAll(query.ctes)
        ..cteMaterialization.addAll(query.cteMaterialization)
        ..compounds.addAll(removeCompounds ? [] : query.compounds)
        ..groupBy.addAll(query.groupBy)
        ..having = having ?? query.having
        ..valuesQuery = query.valuesQuery
        ..subqueryFirstRowOnly = query.subqueryFirstRowOnly
        ..subqueryExists = query.subqueryExists
        ..windowDefinitions.addAll(query.windowDefinitions);

  bool _aggregateQuery(SelectStatement query) =>
      query.groupBy.isNotEmpty ||
      query.having != null ||
      _expressions(query).any((expression) => expression.containsAggregate);

  bool _windowQuery(SelectStatement query) =>
      _expressions(query).any((expression) => expression.containsWindow);

  bool _flattenRelation(
      SelectStatement query, SelectStatement consumer, QuerySource source) {
    if (query.sources.isEmpty ||
        query.distinct ||
        _aggregateQuery(query) ||
        _windowQuery(query) ||
        query.offset != null ||
        ['RIGHT', 'FULL'].contains(source.join)) {
      return false;
    }
    if (source.join == 'LEFT' &&
        (query.normalizedSources.length > 1 || consumer.distinct)) {
      return false;
    }
    if (query.limit != null &&
        (consumer.normalizedSources.length > 1 ||
            _aggregateQuery(consumer) ||
            consumer.limit != null ||
            consumer.where != null ||
            consumer.distinct ||
            consumer.compounds.isNotEmpty)) {
      return false;
    }
    if (query.order.isNotEmpty && _aggregateQuery(consumer)) return false;
    if (query.compounds.isNotEmpty &&
        (_aggregateQuery(consumer) ||
            consumer.distinct ||
            query.compounds.any((part) =>
                part.$1 != 'UNION ALL' ||
                part.$2.sources.isEmpty ||
                part.$2.distinct ||
                _aggregateQuery(part.$2) ||
                _windowQuery(part.$2)))) {
      return false;
    }
    return true;
  }

  List<Expr>? _relationProjectionExpressions(_QueryRelationRows relation,
      [SelectStatement? query]) {
    final items = (query ?? relation.query).items;
    if (items.any((item) => item.expression == null)) return null;
    return items.map((item) => item.expression!).toList();
  }

  SelectStatement _pushRelationPredicate(
      _QueryRelationRows relation,
      SelectStatement query,
      SelectStatement consumer,
      String alias,
      SqlRows Function(SelectStatement, EvalContext) subquery) {
    if (consumer.where == null ||
        consumer.normalizedSources.length != 1 ||
        query.limit != null ||
        query.offset != null ||
        _windowQuery(query)) {
      return query;
    }
    SelectStatement push(SelectStatement branch) {
      final expressions = _relationProjectionExpressions(relation, branch);
      if (expressions == null) return branch;
      final predicate = _RelationPredicateExpr((context) {
        final row = <String, Object?>{...context.row};
        final affinities = Map<String, String>.of(context.affinities);
        final collations = Map<String, String>.of(context.collations);
        for (var i = 0; i < relation.names.length; i++) {
          final name = asciiLower(relation.names[i]);
          final expression = expressions[i];
          final value = SqlValueBinding(() => expression.evaluate(context));
          for (final key in [name, '$alias.$name']) {
            row[key] = value;
            affinities[key] = expression.affinity(context);
            collations[key] = expression.collation(context) ?? '';
          }
        }
        return consumer.where!.evaluate(
            EvalContext(row, affinities, context.parameters, context.encoding)
              ..collations = collations
              ..inTrigger = context.inTrigger
              ..subquery = subquery);
      });
      final aggregate =
          expressions.any((expression) => expression.containsAggregate);
      final result = aggregate
          ? _relationQuery(branch,
              having: branch.having == null
                  ? predicate
                  : BinaryExpr('AND', branch.having!, predicate),
              removeCompounds: true)
          : _relationQuery(branch,
              where: branch.where == null
                  ? predicate
                  : BinaryExpr('AND', branch.where!, predicate),
              removeCompounds: true);
      result.compounds.addAll(
          [for (final part in branch.compounds) (part.$1, push(part.$2))]);
      return result;
    }

    return push(query);
  }

  (List<RowValues>, SelectStatement?) _prepareRelationSource(
      _QueryRelationRows relation,
      SelectStatement consumer,
      QuerySource source,
      String alias,
      int sourceIndex,
      SqlRows Function(SelectStatement, EvalContext) subquery) {
    if (relation.materialized) return (relation.values, null);
    var query = relation.query;
    final flat = _flattenRelation(query, consumer, source);
    if (!flat) {
      final multiple = relation.cte &&
          consumer.leafSources
                  .where((candidate) =>
                      candidate.schema == null &&
                      asciiLower(candidate.table ?? '') ==
                          asciiLower(source.table ?? ''))
                  .length >
              1;
      if (multiple) return (relation.values, null);
      query =
          _pushRelationPredicate(relation, query, consumer, alias, subquery);
      bool usesSourceValue(Expr expression) =>
          expression is ColumnExpr &&
              (expression.qualifier != null
                  ? asciiLower(expression.qualifier!) == alias
                  : relation.names
                      .any((name) => asciiLower(name) == expression.key)) ||
          expression is SubqueryExpr ||
          expression is InSelectExpr ||
          expression.children.any(usesSourceValue);
      // SQLite prunes unused projections from views/derived queries, while
      // ordinary CTE coroutine projections remain part of the execution.
      if (!relation.cte &&
          consumer.items.isNotEmpty &&
          !query.distinct &&
          !_aggregateQuery(query) &&
          !_windowQuery(query) &&
          query.compounds.every((part) => part.$1 == 'UNION ALL') &&
          consumer.items.every((item) =>
              item.expression is FunctionExpr &&
              (item.expression as FunctionExpr).key == 'count' &&
              (item.expression as FunctionExpr).star) &&
          !_expressions(consumer).any(usesSourceValue) &&
          consumer.where == null) {
        final orderExpressions = <Expr>[];
        for (final term in query.order) {
          var expression = term.expression;
          final ordinal = expressionOrdinal(expression);
          final projections = _relationProjectionExpressions(relation);
          if (projections != null) {
            var slot = ordinal == null ? -1 : ordinal.toInt() - 1;
            if (slot < 0 && expression is ColumnExpr) {
              slot = relation.names.indexWhere(
                  (name) => asciiLower(name) == (expression as ColumnExpr).key);
            }
            if (slot >= 0 && slot < projections.length) {
              expression = projections[slot];
            }
          }
          orderExpressions.add(expression);
        }
        SelectStatement prune(SelectStatement branch,
            {List<OrderTerm>? order}) {
          final result = _relationQuery(branch,
              items: [
                for (var i = 0; i < relation.names.length; i++)
                  SelectItem(Literal(null), relation.names[i],
                      explicitAlias: true)
              ],
              order: order,
              removeCompounds: true);
          result.compounds.addAll(
              [for (final part in branch.compounds) (part.$1, prune(part.$2))]);
          return result;
        }

        query = prune(query, order: [
          for (var i = 0; i < query.order.length; i++)
            OrderTerm(orderExpressions[i], query.order[i].descending,
                query.order[i].nullsFirst)
        ]);
      }
      return (
        _DeferredRelationRows(
            () => relation.rows(relation.execute(query, false))),
        null
      );
    }
    var effective = consumer;
    final names = [...relation.names];
    if (query.order.isNotEmpty &&
        consumer.order.isEmpty &&
        consumer.normalizedSources.length == 1) {
      final extra = <SelectItem>[];
      final inherited = <OrderTerm>[];
      final projections = _relationProjectionExpressions(relation);
      for (var i = 0; i < query.order.length; i++) {
        final term = query.order[i];
        var expression = term.expression;
        final ordinal = expressionOrdinal(expression);
        var slot = ordinal == null ? -1 : ordinal.toInt() - 1;
        if (slot < 0 && expression is ColumnExpr) {
          slot = relation.names.indexWhere(
              (name) => asciiLower(name) == (expression as ColumnExpr).key);
        }
        if (projections != null && slot >= 0 && slot < projections.length) {
          expression = projections[slot];
        }
        final key = '\u0000relation$sourceIndex.order$i';
        names.add(key);
        extra.add(SelectItem(expression, key, explicitAlias: true));
        final descriptor = relation
            .describe(_relationQuery(query,
                items: [SelectItem(expression, key, explicitAlias: true)],
                removeCompounds: true))
            .single;
        inherited.add(OrderTerm(_RelationOrderExpr(key, descriptor.collation),
            term.descending, term.nullsFirst));
      }
      query =
          _relationQuery(query, items: [...query.items, ...extra], order: []);
      effective = _relationQuery(consumer, order: inherited);
    } else if (query.order.isNotEmpty) {
      query = _relationQuery(query, order: []);
    }
    if (query.limit != null) {
      effective = SelectStatement(
          effective.items,
          effective.table,
          effective.where,
          effective.order,
          query.limit,
          null,
          effective.distinct,
          effective.parameterCount)
        ..sources.addAll(effective.sources)
        ..ctes.addAll(effective.ctes)
        ..cteMaterialization.addAll(effective.cteMaterialization)
        ..compounds.addAll(effective.compounds)
        ..groupBy.addAll(effective.groupBy)
        ..having = effective.having
        ..subqueryFirstRowOnly = effective.subqueryFirstRowOnly
        ..subqueryExists = effective.subqueryExists
        ..windowDefinitions.addAll(effective.windowDefinitions);
      query = _relationQuery(query, removeLimit: true);
    }
    return (
      _DeferredRelationRows(
          () => relation.rows(relation.execute(query, true), names)),
      effective
    );
  }
}
