import 'expressions.dart';
import 'parser.dart';
import 'functions.dart';
import 'tokenizer.dart';
import 'triggers.dart';

void validateSchemaExpression(Expr expression, Set<String> columns) {
  expression.validate(columns);
  void visit(Expr e) {
    if (e is RaiseExpr ||
        e is ParameterExpr ||
        e is SubqueryExpr ||
        e is InSelectExpr ||
        e.containsAggregate ||
        e.containsWindow) {
      throw const SqlException(
          'Parameters/subqueries/aggregates/windows prohibited in schema expressions');
    }
    if (e is FunctionExpr) {
      if (e.registered != null && !e.registered!.deterministic ||
          e.registered == null &&
              ['current_date', 'current_time', 'current_timestamp']
                  .contains(e.key)) {
        throw const SqlException(
            'Non-deterministic function in schema expression');
      }
    }
    for (final child in e.children) {
      visit(child);
    }
  }

  visit(expression);
}
