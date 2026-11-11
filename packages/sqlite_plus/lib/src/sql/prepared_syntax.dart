part of 'parser.dart';

/// Reusable syntax, never result rows or bound values. Used by prepared handles.
/// Relational/function/subquery trees are not shared across executions.
final class SqlPreparation {
  SqlPreparation(this.sql)
      : tokens = List.unmodifiable(SqlTokenizer.tokenize(sql)) {
    if (sql.length > 65536) {
      throw UnsupportedError('Prepared SQL exceeds 64Ki code units');
    }
    var count = 0;
    final names = <String, int>{};
    for (final token in tokens) {
      if (token.kind != SqlTokenKind.parameter) continue;
      final int? index;
      if (token.text.startsWith('?')) {
        index = token.text.length == 1
            ? count + 1
            : int.tryParse(token.text.substring(1));
      } else {
        namedBindings = true;
        index = names.putIfAbsent(token.text, () => count + 1);
      }
      if (index == null || index < 1 || index > 32766) {
        throw const SqlException('Invalid parameter index');
      }
      if (index > count) count = index;
    }
    parameterCount = count;
  }
  final String sql;
  final List<SqlToken> tokens;
  late final int parameterCount;
  bool namedBindings = false;
  int expressionParses = 0, expressionHits = 0, selectParses = 0;
  final _expressions = <(int, int, int, bool, bool), (Expr, int, int)>{};
  SelectStatement? _select;

  SelectStatement selectSyntax() {
    final cached = _select;
    if (cached != null) return cached;
    selectParses++;
    return _select = SqlParser.prepared(this).select();
  }

  void resetSyntax() {
    _expressions.clear();
    _select = null;
  }

  static bool reusableExpression(Expr e) {
    if (e is Literal) return e.value is! Uint8List;
    // TRUE/FALSE names carry mutable scope-resolution state.
    if (e is BoolNameExpr) return false;
    if (e is ColumnExpr || e is ParameterExpr) return true;
    if (e is InExpr) {
      return reusableExpression(e.operand) &&
          e.values.every(reusableExpression);
    }
    return (e is UnaryExpr ||
            e is BinaryExpr ||
            e is CollateExpr ||
            e is BetweenExpr ||
            e is CastExpr ||
            e is CaseExpr) &&
        e.children.every(reusableExpression);
  }

  bool get reusableSelect {
    final s = selectSyntax();
    return !s.valuesQuery &&
        s.ctes.isEmpty &&
        s.compounds.isEmpty &&
        s.groupBy.isEmpty &&
        s.having == null &&
        s.windowDefinitions.isEmpty &&
        s.sources.length <= 1 &&
        s.sources.every((x) =>
            x.table != null &&
            x.alias == null &&
            x.query == null &&
            x.group.isEmpty &&
            x.pragmaArguments == null) &&
        s.items.every((x) => x.expression == null
            ? x.label == '*'
            : reusableExpression(x.expression!)) &&
        (s.where == null || reusableExpression(s.where!)) &&
        s.order.every((x) => reusableExpression(x.expression)) &&
        (s.limit == null || reusableExpression(s.limit!)) &&
        (s.offset == null || reusableExpression(s.offset!));
  }
}

final class _PreparedSqlParser extends SqlParser {
  _PreparedSqlParser(this.preparation,
      {super.deferFunctionResolution = false,
      super.deferFunctionValidation = false})
      : super._prepared(preparation.sql, preparation.tokens);
  final SqlPreparation preparation;
  @override
  Expr expression([int minimum = 0]) {
    final key = (
      position,
      minimum,
      parameterCount,
      deferFunctionResolution,
      deferFunctionValidation
    );
    final hit =
        preparation.namedBindings ? null : preparation._expressions[key];
    if (hit != null) {
      preparation.expressionHits++;
      position = hit.$2;
      parameterCount = hit.$3;
      return hit.$1;
    }
    preparation.expressionParses++;
    final result = super.expression(minimum);
    if (!preparation.namedBindings &&
        preparation._expressions.length < 2048 &&
        SqlPreparation.reusableExpression(result)) {
      preparation._expressions[key] = (result, position, parameterCount);
    }
    return result;
  }
}
