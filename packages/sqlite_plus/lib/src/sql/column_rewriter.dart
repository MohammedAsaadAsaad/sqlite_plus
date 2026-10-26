import 'expressions.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'triggers.dart';
import 'values.dart';

typedef SchemaColumns = ({List<String> columns, bool rowid});
typedef DependentSchema = ({
  String type,
  String name,
  String owner,
  String sql
});

/// Resolve subquery output widths before row evaluation, including wildcards.
/// This uses names only and never invokes user functions or scans data.
void prepareSubqueryWidths(
    SelectStatement statement, Map<String, SchemaColumns> tables) {
  final resolver = _Columns(tables, {});
  void visit(SelectStatement query, _Ctes inherited) {
    final ctes = resolver.ctes(query, inherited);
    query.preparedColumnCount = resolver.columns(query, inherited).length;
    for (final name in usedCteNames(query)) {
      visit(query.ctes[name]!.$2, ctes);
    }
    for (final source in query.leafSources) {
      if (source.query != null) visit(source.query!, ctes);
    }
    void expression(Expr expr) {
      if (expr is SubqueryExpr) visit(expr.statement, ctes);
      if (expr is InSelectExpr) visit(expr.statement, ctes);
      for (final child in expr.children) {
        expression(child);
      }
    }

    final expressions = [
      ...query.items.map((item) => item.expression),
      query.where,
      ...query.groupBy,
      query.having,
      ...query.order.map((term) => term.expression),
      query.limit,
      query.offset,
      ...query.allSources.map((source) => source.on),
      ...query.allSources.expand((source) => source.pragmaArguments ?? <Expr>[])
    ].whereType<Expr>();
    for (final expr in expressions) {
      expression(expr);
      final names = <String>{};
      void columns(Expr value) {
        if (value is ColumnExpr) names.add(value.key);
        for (final child in value.children) {
          columns(child);
        }
      }

      columns(expr);
      // Binding is validated by the executor. Here every name is allowed so
      // structural row misuse also rejects when an enclosing input is empty.
      expr.validate(names);
    }
    for (final part in query.compounds) {
      visit(part.$2, ctes);
      if (part.$2.preparedColumnCount != query.preparedColumnCount) {
        throw const SqlException('Compound SELECT width mismatch');
      }
    }
  }

  visit(statement, {});
}

Map<int, String> renamedColumnReferences(
    String sql,
    String type,
    String owner,
    String table,
    String oldColumn,
    String newColumn,
    Map<String, SchemaColumns> tables,
    Map<String, String> views) {
  final visitor = _ColumnVisitor(_Columns(tables, views), asciiLower(table),
      asciiLower(oldColumn), newColumn);
  visitor.object(sql, type, owner);
  return visitor.edits;
}

void validateColumnDependencies(
    Map<String, SchemaColumns> tables, List<DependentSchema> objects) {
  final resolver = _Columns(tables, {
    for (final object in objects.where((o) => o.type == 'view'))
      asciiLower(object.name): object.sql
  });
  for (final object in objects) {
    _ColumnVisitor(resolver, null, '', '')
        .object(object.sql, object.type, object.owner);
  }
}

(SelectStatement, List<String>) _view(String sql) {
  final p = SqlParser(sql);
  p.require('CREATE');
  p.require('VIEW');
  if (p.take('IF')) {
    p.require('NOT');
    p.require('EXISTS');
  }
  p.qualifiedIdentifier();
  final names = <String>[];
  if (p.take('(')) {
    do {
      names.add(asciiLower(p.identifier()));
    } while (p.take(','));
    p.require(')');
  }
  p.require('AS');
  return (p.select(), names);
}

typedef _Ctes = Map<String, List<String> Function()>;

final class _Columns {
  _Columns(Map<String, SchemaColumns> tables, this.views)
      : tables = {
          ...tables,
          'sqlite_schema': (
            columns: ['type', 'name', 'tbl_name', 'rootpage', 'sql'],
            rowid: true
          ),
          'sqlite_master': (
            columns: ['type', 'name', 'tbl_name', 'rootpage', 'sql'],
            rowid: true
          ),
        };
  final Map<String, SchemaColumns> tables;
  final Map<String, String> views;
  final _cached = <String, List<String>>{};
  final _loading = <String>{};
  List<String> relation(String name) {
    final key = asciiLower(name);
    final table = tables[key];
    if (table != null) return table.columns.map(asciiLower).toList();
    if (_cached.containsKey(key)) return _cached[key]!;
    final sql = views[key];
    if (sql == null) throw SqlException('Unknown dependent relation: $name');
    if (!_loading.add(key)) throw const SqlException('Circular dependent view');
    try {
      final parsed = _view(sql);
      final actual = columns(parsed.$1, {});
      if (parsed.$2.isNotEmpty && parsed.$2.length != actual.length) {
        throw const SqlException('Dependent view width mismatch');
      }
      return _cached[key] = _unique(parsed.$2.isEmpty ? actual : parsed.$2);
    } finally {
      _loading.remove(key);
    }
  }

  _Ctes ctes(SelectStatement query, _Ctes inherited) {
    final result = {...inherited};
    final cached = <String, List<String>>{}, active = <String>{};
    for (final entry in query.ctes.entries) {
      result[entry.key] = () {
        if (entry.value.$1.isNotEmpty) {
          return _unique(entry.value.$1.map(asciiLower).toList());
        }
        if (cached.containsKey(entry.key)) return cached[entry.key]!;
        if (!active.add(entry.key)) {
          throw const SqlException('Circular CTE metadata');
        }
        try {
          return cached[entry.key] = _unique(columns(entry.value.$2, result));
        } finally {
          active.remove(entry.key);
        }
      };
    }
    return result;
  }

  bool pragmaSource(QuerySource source, _Ctes scope) {
    final key = asciiLower(source.table ?? '');
    return pragmaTableColumns.containsKey(key) &&
        (source.pragmaArguments != null ||
            !tables.containsKey(key) &&
                !views.containsKey(key) &&
                (source.schema != null || !scope.containsKey(key)));
  }

  List<String> source(QuerySource source, _Ctes scope) {
    if (source.group.isNotEmpty) {
      final query = SelectStatement(
          [SelectItem(null, '*')], null, null, [], null, null, false, 0)
        ..sources.addAll(source.group);
      return _unique(columns(query, scope));
    }
    if (source.query != null) return _unique(columns(source.query!, scope));
    final key = asciiLower(source.table!);
    if (pragmaSource(source, scope)) return pragmaTableColumns[key]!;
    return source.schema == null && scope.containsKey(key)
        ? scope[key]!()
        : relation(key);
  }

  Set<String> groupQualifiedNames(QuerySource group, _Ctes ctes) {
    var ordinal = 0;
    ({List<(String, int)> visible, List<(String, int)> physical}) layout(
        QuerySource source) {
      if (source.group.isEmpty) {
        final fields = [
          for (final name in this.source(source, ctes)) (name, ordinal++)
        ];
        return (visible: fields, physical: fields);
      }
      final visible = <(String, int)>[], physical = <(String, int)>[];
      final inner = SelectStatement([], null, null, [], null, null, false, 0)
        ..sources.addAll(source.group);
      for (final child in inner.normalizedSources) {
        final right = layout(child);
        final keys = child.natural
            ? right.visible
                .map((field) => field.$1)
                .where((name) => visible.any((field) => field.$1 == name))
                .toSet()
            : child.using.map(asciiLower).toSet();
        for (final key in keys) {
          final left = visible.indexWhere((field) => field.$1 == key);
          if (left < 0 || !right.visible.any((field) => field.$1 == key)) {
            throw const SqlException('Unresolved dependent USING column');
          }
          visible[left] = (key, ordinal++);
        }
        visible
            .addAll(right.visible.where((field) => !keys.contains(field.$1)));
        physical.addAll(right.physical);
      }
      final assigned = <int, String>{}, used = <String>{};
      for (final field in [...visible, ...physical]) {
        if (assigned.containsKey(field.$2)) continue;
        var name = field.$1, suffix = 0;
        while (!used.add(name)) {
          name = '${field.$1.replaceFirst(RegExp(r':\d+$'), '')}:${++suffix}';
        }
        assigned[field.$2] = name;
      }
      return (
        visible: [for (final field in visible) (assigned[field.$2]!, field.$2)],
        physical: [
          for (final entry in assigned.entries) (entry.value, entry.key)
        ]
      );
    }

    return layout(group).physical.map((field) => field.$1).toSet();
  }

  List<String> columns(SelectStatement query, _Ctes inherited) {
    final scope = ctes(query, inherited);
    final star = <String>[], qualified = <String, List<String>>{};
    for (final source in query.normalizedSources) {
      final names = this.source(source, scope);
      if (source.group.isNotEmpty) {
        for (final child in source.leafSources) {
          if (child.alias != null || child.table != null) {
            qualified[asciiLower(child.alias ?? child.table!)] =
                this.source(child, scope);
          }
        }
      }
      final using = source.natural
          ? names.where(star.contains).toSet()
          : source.using.toSet();
      star.addAll(names.where((name) => !using.contains(name)));
      if (source.alias != null || source.table != null) {
        qualified[asciiLower(source.alias ?? source.table!)] = names;
      }
    }
    final result = <String>[];
    for (final item in query.items) {
      if (item.expression == null) {
        if (item.label == '*') {
          if (query.sources.isEmpty) {
            throw const SqlException('Dependent wildcard has no source');
          }
          result.addAll(star);
        } else {
          final names = qualified[
              asciiLower(item.label.substring(0, item.label.length - 2))];
          if (names == null) {
            throw const SqlException('Unresolved dependent wildcard');
          }
          result.addAll(names);
        }
      } else if (!item.explicitAlias &&
          item.expression is BoolNameExpr &&
          !star.contains((item.expression as BoolNameExpr).key)) {
        result.add(asciiLower(item.label));
      } else if (!item.explicitAlias && item.expression is ColumnExpr) {
        final expr = item.expression as ColumnExpr;
        result.add(asciiLower(expr.qualifier == null
            ? expr.name
            : expr.name.substring(expr.qualifier!.length + 1)));
      } else {
        result.add(asciiLower(item.label));
      }
    }
    return result;
  }

  List<String> _unique(List<String> columns) => relationColumnNames(columns);
}

final class _SourceColumns {
  _SourceColumns(this.alias, this.names, this.target,
      {this.qualifiedNames,
      this.qualifiedOnly = false,
      this.mainQualified = false,
      this.implicit = const {}});
  final Set<String>? qualifiedNames;
  final bool mainQualified;
  final Set<String> implicit;
  final bool qualifiedOnly;
  final String alias;
  final Set<String> names;
  final bool target;
}

final class _ColumnScope {
  _ColumnScope(this.sources, [this.outer, this.unqualified]);
  final Map<String, List<_SourceColumns>>? unqualified;
  final List<_SourceColumns> sources;
  final _ColumnScope? outer;
  _SourceColumns? find(ColumnExpr expr) {
    final key = expr.qualifier == null
        ? expr.key
        : asciiLower(expr.name.substring(expr.qualifier!.length + 1));
    var matches = expr.qualifier == null
        ? (unqualified?[key]?.toList() ??
            sources
                .where((s) => !s.qualifiedOnly && s.names.contains(key))
                .toList())
        : sources
            .where((s) =>
                s.alias == asciiLower(expr.qualifier!) ||
                s.mainQualified &&
                    'main.${s.alias}' == asciiLower(expr.qualifier!))
            .toList();
    if (expr.qualifier == null &&
        matches.any((s) => !s.implicit.contains(key))) {
      matches = matches.where((s) => !s.implicit.contains(key)).toList();
    }
    if (matches.length > 1) {
      throw const SqlException('Ambiguous dependent column');
    }
    if (matches.isNotEmpty) {
      final fields = expr.qualifier == null
          ? matches.single.names
          : matches.single.qualifiedNames ?? matches.single.names;
      if (!fields.contains(key)) {
        throw SqlException('Unknown dependent column: ${expr.name}');
      }
      return matches.single;
    }
    return outer?.find(expr);
  }
}

final class _ColumnVisitor {
  _ColumnVisitor(this.resolver, this.table, this.oldColumn, this.newColumn);
  final _Columns resolver;
  final String? table;
  final String oldColumn, newColumn;
  final edits = <int, String>{};
  int base = 0;
  void put(int? offset) {
    if (offset == null) {
      throw const SqlException('Missing dependent column source offset');
    }
    edits[base + offset] = newColumn;
  }

  _SourceColumns relation(String name, String alias, _Ctes ctes,
      {bool schemaQualified = false}) {
    final key = asciiLower(name);
    final isCte = !schemaQualified && ctes.containsKey(key);
    final names = (isCte ? ctes[key]!() : resolver.relation(key)).toSet();
    final implicit = <String>{};
    if (!isCte && resolver.tables[key]?.rowid == true) {
      implicit.addAll(
          ['rowid', '_rowid_', 'oid'].where((name) => !names.contains(name)));
      names.addAll(implicit);
    }
    return _SourceColumns(asciiLower(alias), names, !isCte && key == table,
        mainQualified: !isCte, implicit: implicit);
  }

  void expression(Expr expr, _ColumnScope scope, _Ctes ctes,
      {Set<String> aliases = const {}, bool preferAlias = false}) {
    if (expr is ColumnExpr) {
      if (preferAlias && expr.qualifier == null && aliases.contains(expr.key)) {
        return;
      }
      final binding = scope.find(expr);
      if (binding == null) {
        if (expr is BoolNameExpr) return;
        if (expr.qualifier == null && aliases.contains(expr.key)) return;
        throw SqlException('Unknown dependent column: ${expr.name}');
      }
      final column = asciiLower(expr.qualifier == null
          ? expr.name
          : expr.name.substring(expr.qualifier!.length + 1));
      if (binding.target && column == oldColumn) put(expr.columnOffset);
    }
    if (expr is ParameterExpr) {
      throw const SqlException('Parameter in dependent schema');
    }
    if (expr is SubqueryExpr) query(expr.statement, scope, ctes);
    if (expr is InSelectExpr) query(expr.statement, scope, ctes);
    for (final child in expr.children) {
      expression(child, scope, ctes, aliases: aliases);
    }
  }

  _ColumnScope sourceBindings(
      List<QuerySource> querySources, _ColumnScope? outer, _Ctes ctes) {
    final sources = <_SourceColumns>[];
    for (var i = 0; i < querySources.length; i++) {
      final source = querySources[i];
      if (source.group.isNotEmpty) {
        final inner = SelectStatement(
            [SelectItem(null, '*')], null, null, [], null, null, false, 0)
          ..sources.addAll(source.group);
        // ALTER resolves a parenthesized joined unit as a materialized source.
        // Child namespaces remain local despite ordinary SELECT visibility.
        query(inner, null, ctes);
        sources.add(_SourceColumns(asciiLower(source.alias ?? '@$i'),
            resolver.source(source, ctes).toSet(), false,
            qualifiedNames: resolver.groupQualifiedNames(source, ctes)));
        continue;
      }
      if (resolver.pragmaSource(source, ctes)) {
        final name = asciiLower(source.table!);
        const implicit = {'rowid', '_rowid_', 'oid'};
        sources.add(_SourceColumns(
            asciiLower(source.alias ?? source.table!),
            {
              ...pragmaTableColumns[name]!,
              if (pragmaTableHasArgument(name)) ...{'arg', 'schema'},
              ...implicit
            },
            false,
            mainQualified: true,
            implicit: implicit));
      } else if (source.query != null) {
        query(source.query!, outer, ctes);
        sources.add(_SourceColumns(asciiLower(source.alias ?? '@$i'),
            resolver.source(source, ctes).toSet(), false));
      } else {
        sources.add(relation(source.table!, source.alias ?? source.table!, ctes,
            schemaQualified: source.schema != null));
      }
    }
    final exposed = <String, List<_SourceColumns>>{};
    final previous = <String>{};
    final visible = [
      for (final source in querySources) resolver.source(source, ctes).toSet()
    ];
    for (var i = 0; i < sources.length; i++) {
      final source = querySources[i];
      final keys = source.natural
          ? visible[i].where(previous.contains).toSet()
          : source.using.map(asciiLower).toSet();
      for (final key in keys) {
        final left = (exposed[key] ?? [])
            .where((binding) => !binding.implicit.contains(key))
            .toList();
        if (!visible[i].contains(key) || left.isEmpty) {
          throw const SqlException('Unresolved dependent USING column');
        }
        if (left.length > 1 &&
            (source.join == 'RIGHT' || source.join == 'FULL')) {
          throw const SqlException('Ambiguous dependent USING column');
        }
        final origin = switch (source.join) {
          'RIGHT' => sources[i],
          'FULL' => _SourceColumns('@merged$i', {key}, false),
          _ => left.first,
        };
        // USING combines the first exposed left field with this right field.
        // Other independent fields with the same name remain ambiguous.
        final group = exposed[key]!;
        group[group.indexOf(left.first)] = origin;
      }
      for (final key in sources[i].names.where((key) => !keys.contains(key))) {
        (exposed[key] ??= []).add(sources[i]);
      }
      previous.addAll(visible[i]);
    }
    return _ColumnScope(sources, outer, exposed);
  }

  void query(SelectStatement select, _ColumnScope? outer, _Ctes inherited) {
    final ctes = resolver.ctes(select, inherited);
    for (final entry in select.ctes.values) {
      query(entry.$2, outer, ctes);
    }
    final querySources = select.normalizedSources;
    final scope = sourceBindings(querySources, outer, ctes);
    final onAliases = {
      for (final item in select.items)
        if (item.expression != null) asciiLower(item.label): item.expression!
    };
    for (var i = 0; i < querySources.length; i++) {
      final source = querySources[i];
      if (source.on != null) {
        expression(source.on!, scope, ctes, aliases: onAliases.keys.toSet());
      }
      for (final argument in source.pragmaArguments ?? const <Expr>[]) {
        expression(argument, scope, ctes);
      }
    }
    // Resolve wildcard names as well as explicit expressions without running SQL.
    resolver.columns(select, inherited);
    for (final item in select.items
        .where((item) => item.expression == null && item.label != '*')) {
      final qualifier =
          asciiLower(item.label.substring(0, item.label.length - 2));
      if (querySources.any((source) =>
          source.group.isNotEmpty &&
          (asciiLower(source.alias ?? '') == qualifier ||
              source.leafSources.any((child) =>
                  asciiLower(child.alias ?? child.table ?? '') ==
                  qualifier)))) {
        throw const SqlException('Unresolved dependent group wildcard');
      }
    }
    for (final item in select.items) {
      if (item.expression != null) expression(item.expression!, scope, ctes);
    }
    for (final definition in select.windowDefinitions.values) {
      expression(definition, scope, ctes);
    }
    final aliases = select.items.map((i) => asciiLower(i.label)).toSet();
    final explicit = select.items
        .where((i) => i.explicitAlias)
        .map((i) => asciiLower(i.label))
        .toSet();
    if (select.where != null) {
      expression(select.where!, scope, ctes, aliases: aliases);
    }
    for (final group in select.groupBy) {
      expression(group, scope, ctes, aliases: aliases);
    }
    if (select.having != null) {
      expression(select.having!, scope, ctes, aliases: aliases);
    }
    for (final order in select.order) {
      expression(order.expression, scope, ctes,
          aliases: {...aliases, ...explicit},
          preferAlias: explicit.contains(order.expression is ColumnExpr
              ? (order.expression as ColumnExpr).key
              : ''));
    }
    for (final expr in [select.limit, select.offset]) {
      if (expr != null) expression(expr, _ColumnScope([]), ctes);
    }
    for (final part in select.compounds) {
      query(part.$2, outer, ctes);
    }
  }

  void object(String sql, String type, String owner) {
    if (type == 'view') {
      query(_view(sql).$1, null, {});
      return;
    }
    final trigger = TriggerDefinition.parse(sql);
    final ownerFields = relation(owner, '', {});
    final pseudo = _ColumnScope([
      if (trigger.event != 'INSERT')
        _SourceColumns('old', ownerFields.names, ownerFields.target,
            qualifiedOnly: true),
      if (trigger.event != 'DELETE')
        _SourceColumns('new', ownerFields.names, ownerFields.target,
            qualifiedOnly: true)
    ]);
    if (ownerFields.target) {
      final p = SqlParser(sql);
      p.require('CREATE');
      p.require('TRIGGER');
      if (p.take('IF')) {
        p.require('NOT');
        p.require('EXISTS');
      }
      p.identifier();
      if (!p.take('BEFORE') && !p.take('AFTER') && p.take('INSTEAD')) {
        p.require('OF');
      }
      if (p.take('UPDATE') && p.take('OF')) {
        do {
          final offset = p.current.offset;
          if (asciiLower(p.identifier()) == oldColumn) put(offset);
        } while (p.take(','));
      }
    }
    if (trigger.when != null) expression(trigger.when!, pseudo, {});
    for (var i = 0; i < trigger.statements.length; i++) {
      base = trigger.statementOffsets[i];
      statement(trigger.statements[i], pseudo);
    }
  }

  void statement(String sql, _ColumnScope pseudo) {
    final p = SqlParser(sql);
    if (['SELECT', 'WITH', 'VALUES'].contains(p.current.keyword)) {
      query(p.select(), pseudo, {});
      return;
    }
    final insert = p.take('INSERT') || p.take('REPLACE');
    final update = !insert && p.take('UPDATE');
    if (!insert && !update) p.require('DELETE');
    if ((insert || update) && p.take('OR')) p.identifier();
    if (insert) p.require('INTO');
    if (!insert && !update) p.require('FROM');
    final name = p.identifier(), target = relation(name, name, {});
    if (pseudo.sources.any((s) => s.alias == target.alias)) {
      throw const SqlException('Ambiguous trigger table/pseudo-row binding');
    }
    final scope = _ColumnScope([target], pseudo);
    void field() {
      final offset = p.current.offset, column = asciiLower(p.identifier());
      if (!target.names.contains(column)) {
        throw const SqlException('Unknown dependent write column');
      }
      if (target.target && column == oldColumn) put(offset);
    }

    void expr(_ColumnScope bindings) =>
        expression(p.expression(), bindings, {});
    void assignments(_ColumnScope bindings) {
      p.require('SET');
      do {
        if (p.take('(')) {
          do {
            field();
          } while (p.take(','));
          p.require(')');
        } else {
          field();
        }
        p.require('=');
        expr(bindings);
      } while (p.take(','));
    }

    if (insert) {
      if (p.take('(')) {
        do {
          field();
        } while (p.take(','));
        p.require(')');
      }
      if (p.take('DEFAULT')) {
        p.require('VALUES');
      } else if (p.take('VALUES')) {
        do {
          p.require('(');
          do {
            expr(pseudo);
          } while (p.take(','));
          p.require(')');
        } while (p.take(','));
      } else {
        query(p.select(nested: true), pseudo, {});
      }
      while (p.take('ON')) {
        p.require('CONFLICT');
        if (p.take('(')) {
          do {
            expr(scope);
            if (!p.take('DESC')) p.take('ASC');
          } while (p.take(','));
          p.require(')');
          if (p.take('WHERE')) expr(scope);
        }
        p.require('DO');
        if (!p.take('NOTHING')) {
          p.require('UPDATE');
          final upsert = _ColumnScope([
            target,
            _SourceColumns('excluded', target.names, target.target,
                qualifiedOnly: true)
          ], pseudo);
          assignments(upsert);
          if (p.take('WHERE')) expr(upsert);
        }
      }
    } else {
      var updateScope = scope;
      if (update) {
        p.require('SET');
        final expressions = <Expr>[];
        do {
          if (p.take('(')) {
            do {
              field();
            } while (p.take(','));
            p.require(')');
          } else {
            field();
          }
          p.require('=');
          expressions.add(p.expression());
        } while (p.take(','));
        if (p.take('FROM')) {
          final from = p.joinedSources();
          final probe = SelectStatement([SelectItem(Literal(BigInt.one), '1')],
              null, null, [], null, null, false, 0)
            ..sources.addAll(from);
          query(probe, pseudo, {});
          final fromScope = sourceBindings(probe.normalizedSources, pseudo, {});
          updateScope = _ColumnScope(
              [target, ...fromScope.sources],
              pseudo,
              {
                for (final key in {
                  ...target.names,
                  ...?fromScope.unqualified?.keys
                })
                  key: [
                    if (target.names.contains(key)) target,
                    ...?fromScope.unqualified?[key]
                  ]
              });
        }
        for (final value in expressions) {
          expression(value, updateScope, {});
        }
      }
      if (p.take('WHERE')) expr(updateScope);
    }
    p.finish();
  }
}
