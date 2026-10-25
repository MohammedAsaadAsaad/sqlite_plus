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
  p.identifier();
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
          return entry.value.$1.map(asciiLower).toList();
        }
        if (cached.containsKey(entry.key)) return cached[entry.key]!;
        if (!active.add(entry.key)) {
          throw const SqlException('Circular CTE metadata');
        }
        try {
          return cached[entry.key] = columns(entry.value.$2, result);
        } finally {
          active.remove(entry.key);
        }
      };
    }
    return result;
  }

  List<String> source(QuerySource source, _Ctes scope) {
    if (source.query != null) return _unique(columns(source.query!, scope));
    final key = asciiLower(source.table!);
    return scope.containsKey(key) ? scope[key]!() : relation(key);
  }

  List<String> columns(SelectStatement query, _Ctes inherited) {
    final scope = ctes(query, inherited);
    final star = <String>[], qualified = <String, List<String>>{};
    for (final source in query.sources) {
      final names = this.source(source, scope);
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

  List<String> _unique(List<String> columns) {
    final result = <String>[], seen = <String>{};
    for (final name in columns) {
      var candidate = name, suffix = 0;
      while (seen.contains(candidate)) {
        candidate = '${name.replaceFirst(RegExp(r':\d+$'), '')}:${++suffix}';
      }
      seen.add(candidate);
      result.add(candidate);
    }
    return result;
  }
}

final class _SourceColumns {
  _SourceColumns(this.alias, this.names, this.target,
      {this.qualifiedOnly = false});
  final bool qualifiedOnly;
  final String alias;
  final Set<String> names;
  final bool target;
}

final class _ColumnScope {
  _ColumnScope(this.sources, [this.outer, this.merged = const {}]);
  final Set<String> merged;
  final List<_SourceColumns> sources;
  final _ColumnScope? outer;
  _SourceColumns? find(ColumnExpr expr) {
    final key = expr.qualifier == null
        ? expr.key
        : asciiLower(expr.name.substring(expr.qualifier!.length + 1));
    final matches = expr.qualifier == null
        ? sources
            .where((s) => !s.qualifiedOnly && s.names.contains(key))
            .toList()
        : sources.where((s) => s.alias == asciiLower(expr.qualifier!)).toList();
    if (matches.length > 1 && expr.qualifier == null && merged.contains(key)) {
      return matches.first;
    }
    if (matches.length > 1) {
      throw const SqlException('Ambiguous dependent column');
    }
    if (matches.isNotEmpty) {
      if (!matches.single.names.contains(key)) {
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

  _SourceColumns relation(String name, String alias, _Ctes ctes) {
    final key = asciiLower(name);
    final names =
        (ctes.containsKey(key) ? ctes[key]!() : resolver.relation(key)).toSet();
    if (!ctes.containsKey(key) && resolver.tables[key]?.rowid == true) {
      names.addAll(['rowid', '_rowid_', 'oid']);
    }
    return _SourceColumns(
        asciiLower(alias), names, !ctes.containsKey(key) && key == table);
  }

  void expression(Expr expr, _ColumnScope scope, _Ctes ctes,
      {Set<String> aliases = const {}, bool preferAlias = false}) {
    if (expr is ColumnExpr) {
      if (preferAlias && expr.qualifier == null && aliases.contains(expr.key)) {
        return;
      }
      final binding = scope.find(expr);
      if (binding == null) {
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

  void query(SelectStatement select, _ColumnScope? outer, _Ctes inherited) {
    final ctes = resolver.ctes(select, inherited);
    for (final entry in select.ctes.values) {
      query(entry.$2, outer, ctes);
    }
    final sources = <_SourceColumns>[];
    for (var i = 0; i < select.sources.length; i++) {
      final source = select.sources[i];
      if (source.query != null) {
        query(source.query!, outer, ctes);
        sources.add(_SourceColumns(asciiLower(source.alias ?? '@$i'),
            resolver.source(source, ctes).toSet(), false));
      } else {
        sources
            .add(relation(source.table!, source.alias ?? source.table!, ctes));
      }
    }
    final merged = <String>{};
    final previous = <String>{};
    for (var i = 0; i < sources.length; i++) {
      final source = select.sources[i];
      merged.addAll(source.using.map(asciiLower));
      if (source.natural) {
        merged.addAll(sources[i].names.where(previous.contains));
      }
      previous.addAll(sources[i].names);
    }
    final scope = _ColumnScope(sources, outer, merged);
    for (var i = 0; i < select.sources.length; i++) {
      final source = select.sources[i];
      if (source.natural || source.using.isNotEmpty) {
        if (sources.any((s) => s.target) &&
            (source.natural ||
                source.using.map(asciiLower).contains(oldColumn))) {
          throw const SqlException(
              'Column rewrite through NATURAL/USING requires explicit schema changes');
        }
        for (final name in source.using) {
          if (!sources[i].names.contains(asciiLower(name)) ||
              !sources.take(i).any((s) => s.names.contains(asciiLower(name)))) {
            throw const SqlException('Unresolved dependent USING column');
          }
        }
      }
      if (source.on != null) expression(source.on!, scope, ctes);
    }
    // Resolve wildcard names as well as explicit expressions without running SQL.
    resolver.columns(select, inherited);
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
        field();
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
      if (update) assignments(scope);
      if (p.take('WHERE')) expr(scope);
    }
    p.finish();
  }
}
