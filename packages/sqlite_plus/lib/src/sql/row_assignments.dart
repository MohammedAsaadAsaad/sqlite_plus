part of 'expressions.dart';

/// Assignment vectors are expanded before duplicate target columns are removed.
/// A literal row has independent fields; a SELECT evaluates its complete row once.
List<Expr> assignmentFields(Expr expression, int width) {
  final known = _rowWidth(expression);
  if (known != null && known != width) {
    throw const SqlException('Assignment row width mismatch');
  }
  if (expression is RowExpr) return expression.fields;
  if (expression is! SubqueryExpr || expression.exists) {
    if (width != 1) throw const SqlException('Row value misused in assignment');
    return [expression];
  }
  final source = _AssignmentRow(expression, width);
  return [for (var i = 0; i < width; i++) _AssignmentField(source, i)];
}

final class _AssignmentRow {
  _AssignmentRow(this.expression, this.width);
  final SubqueryExpr expression;
  final int width;
  final _values = Expando<List<Object?>>();
  void validate() {
    final known = _rowWidth(expression);
    if (known != null && known != width) {
      throw const SqlException('Assignment row width mismatch');
    }
  }

  List<Object?> evaluate(EvalContext context) {
    final saved = _values[context];
    if (saved != null) return saved;
    final result = expression.result(context);
    if (result.columns.length != width) {
      throw const SqlException('Assignment row width mismatch');
    }
    return _values[context] = result.rows.isEmpty
        ? List<Object?>.filled(width, null)
        : List<Object?>.of(result.rows.first);
  }
}

final class _AssignmentField extends Expr {
  _AssignmentField(this.source, this.index);
  final _AssignmentRow source;
  final int index;
  @override
  Iterable<Expr> get children => [source.expression];
  @override
  void validate(Set<String> columns) => source.validate();
  @override
  Object? evaluate(EvalContext context) => source.evaluate(context)[index];
}
