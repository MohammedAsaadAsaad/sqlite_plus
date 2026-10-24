import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

final class TriggerDefinition {
  TriggerDefinition(this.name, this.table, this.timing, this.event,
      this.columns, this.when, this.statements);
  final String name, table, timing, event;
  final List<String> columns, statements;
  final Expr? when;
  static TriggerDefinition parse(String sql) {
    final p = SqlParser(sql);
    p.require('CREATE');
    p.require('TRIGGER');
    if (p.take('IF')) {
      p.require('NOT');
      p.require('EXISTS');
    }
    final name = p.identifier();
    var timing = 'BEFORE';
    if (p.take('BEFORE')) {
      timing = 'BEFORE';
    } else if (p.take('AFTER')) {
      timing = 'AFTER';
    } else if (p.take('INSTEAD')) {
      p.require('OF');
      timing = 'INSTEAD OF';
    }
    final event = p.identifier().toUpperCase();
    if (!['INSERT', 'UPDATE', 'DELETE'].contains(event)) {
      throw const SqlException('Invalid trigger event');
    }
    final columns = <String>[];
    if (event == 'UPDATE' && p.take('OF')) {
      do {
        columns.add(asciiLower(p.identifier()));
      } while (p.take(','));
    }
    p.require('ON');
    final table = p.identifier();
    if (p.take('FOR')) {
      p.require('EACH');
      p.require('ROW');
    }
    final when = p.take('WHEN') ? p.expression() : null;
    p.require('BEGIN');
    final end = p.tokens.lastIndexWhere((token) => token.keyword == 'END');
    if (end < p.position) throw const SqlException('Unterminated trigger');
    final statements = <String>[];
    var start = p.current.offset;
    for (var i = p.position; i < end; i++) {
      final token = p.tokens[i];
      if (token.kind == SqlTokenKind.symbol && token.text == ';') {
        final statement = sql.substring(start, token.offset).trim();
        if (statement.isNotEmpty) statements.add(statement);
        start = token.offset + 1;
      }
    }
    if (sql.substring(start, p.tokens[end].offset).trim().isNotEmpty ||
        statements.isEmpty) {
      throw const SqlException('Trigger statements require semicolons');
    }
    p.position = end + 1;
    p.finish();
    return TriggerDefinition(
        name, table, timing, event, columns, when, statements);
  }
}

final class TriggerIgnore implements Exception {}

final class RaiseExpr extends Expr {
  RaiseExpr(this.action, this.message);
  final String action;
  final Expr? message;
  @override
  Iterable<Expr> get children => [if (message != null) message!];
  @override
  void validate(Set<String> columns) => message?.validate(columns);
  @override
  Object? evaluate(EvalContext context) {
    if (!context.inTrigger) {
      throw const SqlException('RAISE is only valid in a trigger');
    }
    if (action == 'IGNORE') throw TriggerIgnore();
    if (action != 'ABORT') {
      throw const SqlException('Trigger RAISE policy unsupported');
    }
    final value = message?.evaluate(context);
    throw SqlException(value == null
        ? 'constraint failed'
        : stringify(value, context.encoding));
  }
}
