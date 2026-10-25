import 'expressions.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'triggers.dart';
import 'values.dart';

/// Token offsets identify resolved references for schema identifier rewriting.
Map<int, String> renamedTableReferences(
    String sql, String type, String oldName, String newName) {
  final visitor = _TableRenameVisitor(asciiLower(oldName), newName);
  if (type == 'view') {
    final p = SqlParser(sql);
    p.require('CREATE');
    p.require('VIEW');
    if (p.take('IF')) {
      p.require('NOT');
      p.require('EXISTS');
    }
    p.qualifiedIdentifier();
    if (p.take('(')) {
      do {
        p.identifier();
      } while (p.take(','));
      p.require(')');
    }
    p.require('AS');
    visitor.query(p.select(), {}, {});
  } else if (type == 'trigger') {
    visitor.inTrigger = true;
    final trigger = TriggerDefinition.parse(sql);
    if (asciiLower(trigger.table) == visitor.oldName) {
      visitor.put(trigger.tableOffset);
    }
    if (trigger.when != null) visitor.expression(trigger.when!, {}, {});
    for (var i = 0; i < trigger.statements.length; i++) {
      visitor.base = trigger.statementOffsets[i];
      visitor.statement(trigger.statements[i]);
    }
  } else {
    throw const SqlException('Unsupported dependent schema object');
  }
  if (type == 'trigger' &&
      visitor.edits.isNotEmpty &&
      [asciiLower(oldName), asciiLower(newName)]
          .any(['old', 'new', 'excluded'].contains)) {
    throw const SqlException('Trigger pseudo-row/table namespace collision');
  }
  return visitor.edits;
}

final class _TableRenameVisitor {
  _TableRenameVisitor(this.oldName, this.newName);
  final String oldName, newName;
  final edits = <int, String>{};
  int base = 0;
  bool inTrigger = false;
  void put(int? offset) {
    if (offset == null) {
      throw const SqlException('Missing schema source offset');
    }
    edits[base + offset] = newName;
  }

  void expression(Expr expr, Map<String, bool> bindings, Set<String> shadows) {
    if (expr is ColumnExpr &&
        expr.qualifier != null &&
        [oldName, 'main.$oldName'].contains(asciiLower(expr.qualifier!)) &&
        !bindings.containsKey(asciiLower(expr.qualifier!)) &&
        !(inTrigger && ['old', 'new'].contains(oldName))) {
      throw const SqlException('Unresolved dependent table qualifier');
    }
    if (expr is ColumnExpr &&
        expr.qualifier != null &&
        bindings[asciiLower(expr.qualifier!)] == true) {
      if (inTrigger && ['old', 'new'].contains(oldName)) {
        throw const SqlException(
            'Ambiguous trigger pseudo-row/table qualifier');
      }
      put(expr.offset);
    }
    if (expr is SubqueryExpr) query(expr.statement, bindings, shadows);
    if (expr is InSelectExpr) query(expr.statement, bindings, shadows);
    for (final child in expr.children) {
      expression(child, bindings, shadows);
    }
  }

  void query(
      SelectStatement select, Map<String, bool> outer, Set<String> shadows) {
    final visibleCtes = {...shadows, ...select.ctes.keys};
    for (final cte in select.ctes.values) {
      query(cte.$2, outer, visibleCtes);
    }
    final local = <String, bool>{};
    for (final source in select.sources) {
      final name = source.table == null ? null : asciiLower(source.table!);
      final physical = source.table != null &&
          (source.schema != null || !visibleCtes.contains(name));
      final renamed = name == oldName && physical;
      if (renamed) put(source.tableOffset);
      final alias = source.alias == null ? name : asciiLower(source.alias!);
      if (alias != null) {
        if (local.containsKey(alias)) {
          throw const SqlException('Ambiguous dependent source alias');
        }
        local[alias] = renamed && source.alias == null;
        if (physical) local['main.$alias'] = renamed && source.alias == null;
      }
      if (source.query != null) query(source.query!, outer, visibleCtes);
    }
    final bindings = {...outer, ...local};
    for (final item in select.items) {
      if (item.expression != null) {
        expression(item.expression!, bindings, visibleCtes);
      } else if (item.label.endsWith('.*')) {
        final qualifier =
            asciiLower(item.label.substring(0, item.label.length - 2));
        if (qualifier == oldName &&
            !bindings.containsKey(qualifier) &&
            !(inTrigger && ['old', 'new'].contains(qualifier))) {
          throw const SqlException('Unresolved dependent wildcard qualifier');
        }
        if (bindings[qualifier] == true) put(item.qualifierOffset);
      }
    }
    for (final expr in [
      select.where,
      ...select.groupBy,
      select.having,
      ...select.order.map((t) => t.expression),
      select.limit,
      select.offset,
      ...select.sources.map((s) => s.on),
      ...select.windowDefinitions.values
    ]) {
      if (expr != null) expression(expr, bindings, visibleCtes);
    }
    for (final compound in select.compounds) {
      query(compound.$2, outer, visibleCtes);
    }
  }

  void statement(String sql) {
    final p = SqlParser(sql);
    if (['SELECT', 'WITH', 'VALUES'].contains(p.current.keyword)) {
      query(p.select(), {}, {});
      return;
    }
    final insert = p.take('INSERT') || p.take('REPLACE');
    final update = !insert && p.take('UPDATE');
    if (!insert && !update) p.require('DELETE');
    if ((insert || update) && p.take('OR')) p.identifier();
    if (insert) p.require('INTO');
    if (!insert && !update) p.require('FROM');
    final tableOffset = p.current.offset;
    final name = asciiLower(p.identifier());
    if (name == oldName) put(tableOffset);
    final bindings = <String, bool>{name: name == oldName, 'excluded': false};
    void expr({bool target = true}) =>
        expression(p.expression(), target ? bindings : {}, {});
    void assignments() {
      p.require('SET');
      do {
        p.identifier();
        p.require('=');
        expr();
      } while (p.take(','));
    }

    if (insert) {
      if (p.take('(')) {
        do {
          p.identifier();
        } while (p.take(','));
        p.require(')');
      }
      if (p.take('DEFAULT')) {
        p.require('VALUES');
      } else if (p.take('VALUES')) {
        do {
          p.require('(');
          do {
            expr(target: false);
          } while (p.take(','));
          p.require(')');
        } while (p.take(','));
      } else {
        query(p.select(nested: true), {}, {});
      }
      while (p.take('ON')) {
        p.require('CONFLICT');
        if (p.take('(')) {
          do {
            expr();
            if (!p.take('DESC')) p.take('ASC');
          } while (p.take(','));
          p.require(')');
          if (p.take('WHERE')) expr();
        }
        p.require('DO');
        if (!p.take('NOTHING')) {
          p.require('UPDATE');
          // SQLite 3.53.1 rebinds the trigger UPSERT pseudo-table here when
          // renaming its target, including EXCLUDED column qualifiers.
          if (name == oldName) {
            if (oldName == 'excluded') {
              throw const SqlException('Ambiguous EXCLUDED table binding');
            }
            bindings['excluded'] = true;
          }
          assignments();
          if (p.take('WHERE')) expr();
        }
      }
    } else {
      if (update) assignments();
      if (p.take('WHERE')) expr();
    }
    p.finish();
  }
}
