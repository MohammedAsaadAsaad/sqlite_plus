import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

final class TriggerDefinition {
  TriggerDefinition(this.name, this.table, this.timing, this.event,
      this.columns, this.when, this.statements,
      [this.whenSql, this.tableOffset = 0, this.statementOffsets = const []]);
  final String name, table, timing, event;
  final List<String> columns, statements;
  final Expr? when;
  final String? whenSql;
  final int tableOffset;
  final List<int> statementOffsets;
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
    var tableOffset = p.current.offset;
    if (p.position + 1 < p.tokens.length &&
        p.tokens[p.position + 1].text == '.') {
      tableOffset = p.tokens[p.position + 2].offset;
    }
    final table = p.qualifiedIdentifier();
    if (p.take('FOR')) {
      p.require('EACH');
      p.require('ROW');
    }
    Expr? when;
    String? whenSql;
    if (p.take('WHEN')) {
      final start = p.current.offset;
      when = p.expression();
      whenSql = sql.substring(start, p.current.offset);
    }
    p.require('BEGIN');
    final end = p.tokens.lastIndexWhere((token) => token.keyword == 'END');
    if (end < p.position) throw const SqlException('Unterminated trigger');
    final statements = <String>[];
    final offsets = <int>[];
    var start = p.current.offset;
    for (var i = p.position; i < end; i++) {
      final token = p.tokens[i];
      if (token.kind == SqlTokenKind.symbol && token.text == ';') {
        final statement = sql.substring(start, token.offset).trim();
        if (statement.isNotEmpty) {
          statements.add(statement);
          offsets.add(sql.indexOf(statement, start));
        }
        start = token.offset + 1;
      }
    }
    if (sql.substring(start, p.tokens[end].offset).trim().isNotEmpty ||
        statements.isEmpty) {
      throw const SqlException('Trigger statements require semicolons');
    }
    p.position = end + 1;
    p.finish();
    return TriggerDefinition(name, table, timing, event, columns, when,
        statements, whenSql, tableOffset, offsets);
  }
}

final class TriggerIgnore implements Exception {}

final class RaiseExpr extends Expr {
  RaiseExpr(this.action, this.message) {
    if (!['ABORT', 'FAIL', 'ROLLBACK', 'IGNORE'].contains(action)) {
      throw const SqlException('Invalid RAISE policy');
    }
  }
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
    final value = message?.evaluate(context);
    final text = value == null
        ? 'constraint failed'
        : stringify(value, context.encoding);
    if (action == 'ABORT') throw SqlException(text);
    throw SqlTriggerFailure(action, text);
  }
}
