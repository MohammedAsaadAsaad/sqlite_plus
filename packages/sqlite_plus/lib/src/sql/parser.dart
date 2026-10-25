import 'dart:typed_data';

import 'tokenizer.dart';
import 'values.dart';
import 'functions.dart';
import 'expressions.dart';
import 'triggers.dart';
import 'windows.dart';

abstract interface class SqlRows {
  List<String> get columns;
  List<List<Object?>> get rows;
  List<String> get columnAffinities;
}

typedef RowValues = Map<String, Object?>;

final class EvalContext {
  EvalContext(this.row, this.affinities, this.parameters, [this.encoding = 1]);
  Map<RowValues, List<RowValues>> windowGroups = {};
  Map<RowValues, Map<Expr, Object?>> windowAggregates = {};
  EvalContext forRow(RowValues values) {
    final result = EvalContext(values, affinities, parameters, encoding)
      ..subquery = subquery
      ..collations = collations
      ..group = windowGroups[values]
      ..schemaExpression = schemaExpression
      ..inTrigger = inTrigger;
    result.windowGroups = windowGroups;
    result.windowAggregates = windowAggregates;
    result.aggregateValues.addAll(windowAggregates[values] ?? {});
    return result;
  }

  SqlRows Function(SelectStatement, EvalContext)? subquery;
  bool inTrigger = false;
  bool schemaExpression = false;
  List<RowValues>? windowRows;
  RowValues? windowRow;
  Map<Expr, Object> windowCache = {};
  Map<String, String> collations = {};
  List<RowValues>? group;
  final Map<Expr, Object?> aggregateValues = {};
  final int encoding;
  final RowValues row;
  final Map<String, String> affinities;
  final List<Object?> parameters;
}

abstract class Expr {
  bool get containsWindow => children.any((c) => c.containsWindow);
  Iterable<Expr> get children => const [];
  bool get containsAggregate =>
      children.any((child) => child.containsAggregate);
  Object? evaluate(EvalContext context);
  Set<String> get unaggregatedColumns =>
      children.expand((child) => child.unaggregatedColumns).toSet();
  String affinity(EvalContext context) => 'none';
  String? explicitCollation(EvalContext context) {
    for (final child in children) {
      final value = child.explicitCollation(context);
      if (value != null) return value;
    }
    return null;
  }

  String? collation(EvalContext context) => explicitCollation(context);

  void validate(Set<String> columns) {}
}

final class Literal extends Expr {
  Literal(this.value, [this.spelling]);
  final Object? value;
  final String? spelling;
  @override
  Object? evaluate(EvalContext context) => value;
}

/// SQLite treats signed integer syntax (including COLLATE wrappers) as result
/// ordinals, but TRUE/FALSE and real literals remain ordinary constants.
BigInt? expressionOrdinal(Expr expression) {
  var sign = BigInt.one;
  var expr = expression;
  while (true) {
    if (expr is CollateExpr) {
      expr = expr.operand;
      continue;
    }
    if (expr is UnaryExpr && ['+', '-'].contains(expr.op)) {
      if (expr.op == '-') sign = -sign;
      expr = expr.operand;
      continue;
    }
    break;
  }
  return expr is Literal && expr.value is BigInt && expr.spelling == null
      ? (expr.value as BigInt) * sign
      : null;
}

final class ColumnExpr extends Expr {
  ColumnExpr(this.name, {this.offset, this.qualifier, this.columnOffset});
  final int? columnOffset;
  final int? offset;
  final String? qualifier;
  final String name;
  String get key => asciiLower(name);
  @override
  Set<String> get unaggregatedColumns => {key};
  @override
  Object? evaluate(EvalContext context) {
    if (!context.row.containsKey(key)) {
      throw SqlException('No such column: $name');
    }
    return context.row[key];
  }

  @override
  String affinity(EvalContext context) => context.affinities[key] ?? 'none';
  @override
  String? collation(EvalContext context) => context.collations[key];
  @override
  void validate(Set<String> columns) {
    if (!columns.contains(key)) throw SqlException('No such column: $name');
  }
}

final class ParameterExpr extends Expr {
  ParameterExpr(this.index);
  final int index;
  @override
  Object? evaluate(EvalContext context) => context.parameters[index];
}

bool isLiteralConstant(Expr expression) =>
    expression is Literal ||
    expression is UnaryExpr && isLiteralConstant(expression.operand);

final class UnaryExpr extends Expr {
  UnaryExpr(this.op, this.operand);
  final String op;
  final Expr operand;
  @override
  String? collation(EvalContext context) =>
      op == '+' ? operand.collation(context) : super.collation(context);
  @override
  Iterable<Expr> get children => [operand];
  @override
  void validate(Set<String> columns) => operand.validate(columns);
  @override
  Object? evaluate(EvalContext context) {
    final value = operand.evaluate(context);
    if (op == '+') return value;
    if (op == 'NOT') {
      return truth(value, context.encoding) == null
          ? null
          : boolean(!truth(value, context.encoding)!);
    }
    if (value == null) return null;
    final n =
        numeric(value, prefix: true, encoding: context.encoding) ?? BigInt.zero;
    if (op == '-') return n is BigInt ? narrowInteger(-n) : -(n as double);
    if (op == '~') {
      return ~toSqlInteger(n).toSigned(64);
    }
    throw SqlException('Unsupported unary operator $op');
  }
}

final class TruthExpr extends Expr {
  TruthExpr(this.operand, this.expected, this.negate);
  final Expr operand;
  @override
  Iterable<Expr> get children => [operand];
  final bool expected;
  final bool negate;
  @override
  void validate(Set<String> columns) => operand.validate(columns);
  @override
  Object? evaluate(EvalContext context) {
    final result =
        truth(operand.evaluate(context), context.encoding) == expected;
    return boolean(negate ? !result : result);
  }
}

final class BinaryExpr extends Expr {
  BinaryExpr(this.op, this.left, this.right);
  final String op;
  final Expr left;
  final Expr right;
  @override
  Iterable<Expr> get children => [left, right];
  @override
  void validate(Set<String> columns) {
    left.validate(columns);
    right.validate(columns);
  }

  @override
  Object? evaluate(EvalContext context) {
    var a = left.evaluate(context);
    var b = right.evaluate(context);
    if (op == 'AND' || op == 'OR') {
      final aa = truth(a, context.encoding);
      final bb = truth(b, context.encoding);
      if (op == 'AND') {
        return aa == false || bb == false
            ? BigInt.zero
            : aa == null || bb == null
                ? null
                : BigInt.one;
      }
      return aa == true || bb == true
          ? BigInt.one
          : aa == null || bb == null
              ? null
              : BigInt.zero;
    }
    if (['=', '==', '!=', '<>', '<', '>', '<=', '>=', 'IS', 'IS NOT']
        .contains(op)) {
      final la = left.affinity(context);
      final ra = right.affinity(context);
      if (la == 'numeric' && ra != 'numeric') {
        b = applyAffinity(b, 'numeric');
      } else if (ra == 'numeric' && la != 'numeric') {
        a = applyAffinity(a, 'numeric');
      } else if (la == 'text' && ra == 'none') {
        b = applyAffinity(b, 'text');
      } else if (ra == 'text' && la == 'none') {
        a = applyAffinity(a, 'text');
      }
      if (op == 'IS' || op == 'IS NOT') {
        final equal = a == null || b == null
            ? a == b
            : compareValues(
                    a,
                    b,
                    context.encoding,
                    left.explicitCollation(context) ??
                        right.explicitCollation(context) ??
                        left.collation(context) ??
                        right.collation(context)) ==
                0;
        return boolean(op == 'IS' ? equal : !equal);
      }
      if (a == null || b == null) return null;
      final c = compareValues(
          a,
          b,
          context.encoding,
          left.explicitCollation(context) ??
              right.explicitCollation(context) ??
              left.collation(context) ??
              right.collation(context));
      return boolean(switch (op) {
        '=' || '==' => c == 0,
        '!=' || '<>' => c != 0,
        '<' => c < 0,
        '>' => c > 0,
        '<=' => c <= 0,
        _ => c >= 0,
      });
    }
    if (a == null || b == null) return null;
    if (op == '||') {
      return stringify(a, context.encoding) + stringify(b, context.encoding);
    }
    a = numeric(a, prefix: true, encoding: context.encoding) ?? BigInt.zero;
    b = numeric(b, prefix: true, encoding: context.encoding) ?? BigInt.zero;
    if (['&', '|', '<<', '>>'].contains(op)) {
      final aa = toSqlInteger(a);
      final bb = toSqlInteger(b);
      if (op == '&') return (aa & bb).toSigned(64);
      if (op == '|') return (aa | bb).toSigned(64);
      final shift = bb.abs() > BigInt.from(64) ? 64 : bb.abs().toInt();
      final leftShift = (op == '<<') == (bb >= BigInt.zero);
      return leftShift
          ? (aa << shift).toSigned(64)
          : (aa.toSigned(64) >> shift);
    }
    if ((op == '/' || op == '%') && compareValues(b, BigInt.zero) == 0) {
      return null;
    }
    if (a is BigInt && b is BigInt) {
      return switch (op) {
        '+' => narrowInteger(a + b),
        '-' => narrowInteger(a - b),
        '*' => narrowInteger(a * b),
        '/' => narrowInteger(a ~/ b),
        '%' => a.remainder(b),
        _ => throw SqlException('Unsupported operator $op'),
      };
    }
    final aa = a is BigInt ? a.toDouble() : a as double;
    final bb = b is BigInt ? b.toDouble() : b as double;
    if (op == '%') {
      final divisor = toSqlInteger(bb);
      return divisor == BigInt.zero
          ? null
          : toSqlInteger(aa).remainder(divisor).toDouble();
    }
    final result = switch (op) {
      '+' => aa + bb,
      '-' => aa - bb,
      '*' => aa * bb,
      '/' => aa / bb,
      _ => throw SqlException('Unsupported operator $op')
    };
    return result.isNaN ? null : result;
  }
}

final class SelectItem {
  SelectItem(this.expression, this.label,
      {this.explicitAlias = false, this.qualifierOffset});
  final int? qualifierOffset;
  final bool explicitAlias;
  final Expr? expression; // null denotes *
  final String label;
}

final class OrderTerm {
  OrderTerm(this.expression, this.descending, [this.nullsFirst]);
  final bool? nullsFirst;
  int compare(Object? a, Object? b, EvalContext context) {
    if (nullsFirst != null && (a == null || b == null)) {
      if (a == null && b == null) return 0;
      return a == null ? (nullsFirst! ? -1 : 1) : (nullsFirst! ? 1 : -1);
    }
    final result =
        compareValues(a, b, context.encoding, expression.collation(context));
    return descending ? -result : result;
  }

  final Expr expression;
  final bool descending;
}

final class SelectStatement {
  SelectStatement(this.items, this.table, this.where, this.order, this.limit,
      this.offset, this.distinct, this.parameterCount);
  final Map<String, (List<String>, SelectStatement)> ctes = {};
  final List<QuerySource> sources = [];
  final List<(String, SelectStatement)> compounds = [];
  final List<Expr> groupBy = [];
  final Map<String, WindowExpr> windowDefinitions = {};
  Expr? having;
  final List<SelectItem> items;
  final String? table;
  final Expr? where;
  final List<OrderTerm> order;
  final Expr? limit;
  final Expr? offset;
  final bool distinct;
  final int parameterCount;
  bool valuesQuery = false;
}

final class QuerySource {
  QuerySource(
      {this.table,
      this.tableOffset,
      this.query,
      this.alias,
      this.join = 'CROSS',
      this.on,
      this.using = const [],
      this.natural = false});
  final String? table, alias;
  final int? tableOffset;
  final SelectStatement? query;
  final String join;
  final Expr? on;
  final List<String> using;
  final bool natural;
}

/// Strict parser for the M3 single-table SELECT grammar. Unsupported syntax fails.
final class SqlParser {
  SqlParser(String sql)
      : source = sql,
        tokens = SqlTokenizer.tokenize(sql);
  SqlParser.tokens(this.tokens) : source = null;
  final String? source;
  final List<SqlToken> tokens;
  int position = 0;
  int parameterCount = 0;
  final Map<String, int> parameterNames = {};
  SqlToken get current => tokens[position];
  bool take(String text) {
    if (current.keyword == text ||
        current.kind == SqlTokenKind.symbol && current.text == text) {
      position++;
      return true;
    }
    return false;
  }

  void require(String text) {
    if (!take(text)) throw SqlException('Expected $text', current.offset);
  }

  String identifier() {
    if (current.kind != SqlTokenKind.identifier) {
      throw SqlException('Expected identifier', current.offset);
    }
    return tokens[position++].text;
  }

  void finish() {
    take(';');
    if (current.kind != SqlTokenKind.end) {
      throw SqlException('Unsupported or trailing SQL', current.offset);
    }
  }

  int _selectDepth = 0;
  SelectStatement select({bool nested = false, bool component = false}) {
    if (++_selectDepth > 64) {
      _selectDepth--;
      throw const SqlException('SELECT nesting limit exceeded');
    }
    try {
      return _select(nested: nested, component: component);
    } finally {
      _selectDepth--;
    }
  }

  SelectStatement _select({bool nested = false, bool component = false}) {
    final ctes = <String, (List<String>, SelectStatement)>{};
    if (take('WITH')) {
      take('RECURSIVE');
      do {
        final name = asciiLower(identifier());
        if (ctes.containsKey(name)) throw const SqlException('Duplicate CTE');
        final columns = <String>[];
        if (take('(')) {
          do {
            columns.add(identifier());
          } while (take(','));
          require(')');
        }
        require('AS');
        if (take('NOT')) {
          require('MATERIALIZED');
        } else {
          take('MATERIALIZED');
        }
        require('(');
        final query = select(nested: true);
        require(')');
        ctes[name] = (columns, query);
      } while (take(','));
    }
    if (take('VALUES')) {
      return _values(ctes, nested: nested, component: component);
    }
    require('SELECT');
    final distinct = take('DISTINCT');
    if (!distinct) take('ALL');
    final items = <SelectItem>[];
    do {
      if (take('*')) {
        items.add(SelectItem(null, '*'));
        continue;
      }
      final start = current;
      final expr = expression();
      final display =
          source?.substring(start.offset, current.offset).trim() ?? start.text;
      final explicitAlias = take('AS') || _implicitAlias();
      final label = explicitAlias
          ? _alias()
          : expr is ColumnExpr
              ? expr.name
              : display;
      items.add(expr is ColumnExpr && expr.name.endsWith('.*')
          ? SelectItem(null, expr.name, qualifierOffset: expr.offset)
          : SelectItem(expr, label, explicitAlias: explicitAlias));
    } while (take(','));
    final sources = <QuerySource>[];
    if (take('FROM')) {
      sources.add(_source('CROSS', false));
      while (true) {
        if (take(',')) {
          sources.add(_source('CROSS', false));
          continue;
        }
        final natural = take('NATURAL');
        String? join;
        for (final type in ['LEFT', 'RIGHT', 'FULL', 'INNER', 'CROSS']) {
          if (take(type)) {
            join = type;
            break;
          }
        }
        if (join != null) {
          take('OUTER');
          require('JOIN');
        } else if (take('JOIN')) {
          join = 'INNER';
        } else {
          if (natural) throw const SqlException('Expected JOIN');
          break;
        }
        sources.add(_source(join, natural));
      }
    }
    final table = sources.isEmpty ? null : sources.first.table;
    final where = take('WHERE') ? expression() : null;
    final groups = <Expr>[];
    if (take('GROUP')) {
      require('BY');
      do {
        groups.add(expression());
      } while (take(','));
    }
    final having = take('HAVING') ? expression() : null;
    final windows = <String, WindowExpr>{};
    if (take('WINDOW')) {
      do {
        final name = asciiLower(identifier());
        require('AS');
        if (windows.containsKey(name)) {
          throw const SqlException('Duplicate window name');
        }
        windows[name] =
            _window(FunctionExpr('count', [], star: true), definition: true);
      } while (take(','));
    }

    final compounds = <(String, SelectStatement)>[];
    if (!component) {
      while (['UNION', 'INTERSECT', 'EXCEPT'].contains(current.keyword)) {
        var op = current.keyword;
        position++;
        if (op == 'UNION' && take('ALL')) op = 'UNION ALL';
        compounds.add((op, select(nested: true, component: true)));
      }
    }
    if (compounds.isNotEmpty &&
        compounds.last.$2.valuesQuery &&
        ['ORDER', 'LIMIT'].contains(current.keyword)) {
      throw const SqlException('VALUES cannot have ORDER BY/LIMIT');
    }
    final order = <OrderTerm>[];
    if (!component && take('ORDER')) {
      require('BY');
      do {
        final expr = expression();
        final desc = take('DESC');
        if (!desc) take('ASC');
        order.add(OrderTerm(expr, desc, _nulls()));
      } while (take(','));
    }
    Expr? limit;
    Expr? offset;
    if (!component && take('LIMIT')) {
      limit = expression();
      if (take('OFFSET')) {
        offset = expression();
      } else if (take(',')) {
        offset = limit;
        limit = expression();
      }
    }
    if (!nested) finish();
    void resolve(Expr expr) {
      if (expr is WindowExpr) expr.resolve(windows, {});
      for (final child in expr.children) {
        resolve(child);
      }
    }

    for (final expr in [
      ...items.map((i) => i.expression),
      where,
      ...groups,
      having,
      ...order.map((o) => o.expression)
    ]) {
      if (expr != null) resolve(expr);
    }
    return SelectStatement(
        items, table, where, order, limit, offset, distinct, parameterCount)
      ..ctes.addAll(ctes)
      ..sources.addAll(sources)
      ..compounds.addAll(compounds)
      ..groupBy.addAll(groups)
      ..windowDefinitions.addAll(windows)
      ..having = having;
  }

  SelectStatement _values(Map<String, (List<String>, SelectStatement)> ctes,
      {required bool nested, required bool component}) {
    final rows = <SelectStatement>[];
    var width = -1;
    do {
      require('(');
      final items = <SelectItem>[];
      do {
        final expr = expression();
        void resolve(Expr e) {
          if (e is WindowExpr) e.resolve({}, {});
          for (final child in e.children) {
            resolve(child);
          }
        }

        resolve(expr);
        items.add(
            SelectItem(expr, 'column${items.length + 1}', explicitAlias: true));
      } while (take(','));
      require(')');
      if (width >= 0 && width != items.length) {
        throw const SqlException('VALUES width mismatch');
      }
      width = items.length;
      rows.add(SelectStatement(
          items, null, null, [], null, null, false, parameterCount)
        ..valuesQuery = true);
    } while (take(','));
    if (rows.length > 1 &&
        rows.any((row) =>
            row.items.any((item) => item.expression!.containsAggregate))) {
      throw const SqlException('Aggregate in multirow VALUES');
    }
    final first = rows.first;
    final compounds = <(String, SelectStatement)>[
      for (final row in rows.skip(1)) ('UNION ALL', row)
    ];
    if (!component) {
      while (['UNION', 'INTERSECT', 'EXCEPT'].contains(current.keyword)) {
        var op = current.keyword;
        position++;
        if (op == 'UNION' && take('ALL')) op = 'UNION ALL';
        compounds.add((op, select(nested: true, component: true)));
      }
    }
    final endsInValues = compounds.isEmpty || compounds.last.$2.valuesQuery;
    if (endsInValues && ['ORDER', 'LIMIT'].contains(current.keyword)) {
      throw const SqlException('VALUES cannot have ORDER BY/LIMIT');
    }
    final order = <OrderTerm>[];
    if (!component && take('ORDER')) {
      require('BY');
      do {
        final expr = expression(), desc = take('DESC');
        if (!desc) take('ASC');
        order.add(OrderTerm(expr, desc, _nulls()));
      } while (take(','));
    }
    Expr? limit, offset;
    if (!component && take('LIMIT')) {
      limit = expression();
      if (take('OFFSET')) {
        offset = expression();
      } else if (take(',')) {
        offset = limit;
        limit = expression();
      }
    }
    if (!nested) finish();
    return SelectStatement(
        first.items, null, null, order, limit, offset, false, parameterCount)
      ..valuesQuery = endsInValues
      ..ctes.addAll(ctes)
      ..compounds.addAll(compounds);
  }

  WindowExpr _window(FunctionExpr function, {bool definition = false}) {
    function.windowFunction = true;
    if (!take('(')) {
      if (definition) {
        throw const SqlException('Window definition requires parentheses');
      }
      final name = identifier();
      return WindowExpr(
          function,
          [],
          [],
          'RANGE',
          WindowBound('UNBOUNDED PRECEDING'),
          WindowBound('UNBOUNDED FOLLOWING'))
        ..baseName = asciiLower(name)
        ..directName = true;
    }
    String? baseName;
    if (current.kind == SqlTokenKind.identifier &&
        !['PARTITION', 'ORDER', 'ROWS', 'RANGE', 'GROUPS', 'EXCLUDE']
            .contains(current.keyword)) {
      baseName = asciiLower(identifier());
    }
    final partition = <Expr>[];
    final order = <OrderTerm>[];
    if (take('PARTITION')) {
      require('BY');
      do {
        partition.add(expression());
      } while (take(','));
    }
    if (take('ORDER')) {
      require('BY');
      do {
        final expr = expression();
        final descending = take('DESC');
        if (!descending) take('ASC');
        order.add(OrderTerm(expr, descending, _nulls()));
      } while (take(','));
    }
    var mode = 'RANGE';
    var start = WindowBound('UNBOUNDED PRECEDING');
    var end =
        WindowBound(order.isEmpty ? 'UNBOUNDED FOLLOWING' : 'CURRENT ROW');
    WindowBound bound() {
      if (take('UNBOUNDED')) {
        final direction = identifier().toUpperCase();
        if (!['PRECEDING', 'FOLLOWING'].contains(direction)) {
          throw const SqlException('Invalid frame bound');
        }
        return WindowBound('UNBOUNDED $direction');
      }
      if (take('CURRENT')) {
        require('ROW');
        return WindowBound('CURRENT ROW');
      }
      final offset = expression();
      final direction = identifier().toUpperCase();
      if (!['PRECEDING', 'FOLLOWING'].contains(direction)) {
        throw const SqlException('Invalid frame bound');
      }
      return WindowBound(direction, offset);
    }

    var explicitFrame = false;
    if (['ROWS', 'RANGE', 'GROUPS'].contains(current.keyword)) {
      explicitFrame = true;
      mode = identifier().toUpperCase();
      if (take('BETWEEN')) {
        start = bound();
        require('AND');
        end = bound();
      } else {
        start = bound();
        end = WindowBound('CURRENT ROW');
      }
    }
    var exclusion = 'NO OTHERS';
    if (take('EXCLUDE')) {
      if (take('CURRENT')) {
        require('ROW');
        exclusion = 'CURRENT ROW';
      } else if (take('GROUP')) {
        exclusion = 'GROUP';
      } else if (take('TIES')) {
        exclusion = 'TIES';
      } else {
        require('NO');
        require('OTHERS');
      }
    }
    require(')');
    if (start.kind == 'UNBOUNDED FOLLOWING' ||
        end.kind == 'UNBOUNDED PRECEDING') {
      throw const SqlException('Invalid frame bounds');
    }
    const boundOrder = [
      'UNBOUNDED PRECEDING',
      'PRECEDING',
      'CURRENT ROW',
      'FOLLOWING',
      'UNBOUNDED FOLLOWING'
    ];
    if (boundOrder.indexOf(start.kind) > boundOrder.indexOf(end.kind)) {
      throw const SqlException('Invalid frame ordering');
    }
    return WindowExpr(function, partition, order, mode, start, end, exclusion)
      ..baseName = baseName
      ..explicitFrame = explicitFrame;
  }

  bool? _nulls() {
    if (!take('NULLS')) return null;
    if (take('FIRST')) return true;
    require('LAST');
    return false;
  }

  String _alias() => current.kind == SqlTokenKind.string
      ? tokens[position++].text
      : identifier();

  bool _implicitAlias() =>
      (current.kind == SqlTokenKind.identifier ||
          current.kind == SqlTokenKind.string) &&
      !const {
        'FROM',
        'WHERE',
        'GROUP',
        'HAVING',
        'ORDER',
        'LIMIT',
        'OFFSET',
        'UNION',
        'INTERSECT',
        'EXCEPT',
        'JOIN',
        'LEFT',
        'RIGHT',
        'FULL',
        'INNER',
        'OUTER',
        'CROSS',
        'NATURAL',
        'ON',
        'USING',
        'WINDOW',
        'WHEN',
        'THEN',
        'ELSE',
        'END',
        'AS',
        'COLLATE',
        'ASC',
        'DESC'
      }.contains(current.keyword);
  QuerySource _source(String join, bool natural) {
    String? table;
    int? tableOffset;
    SelectStatement? query;
    if (take('(')) {
      query = select(nested: true);
      require(')');
    } else {
      tableOffset = current.offset;
      table = identifier();
    }
    final alias = take('AS') || _implicitAlias() ? _alias() : null;
    Expr? on;
    final using = <String>[];
    if (take('ON')) {
      on = expression();
    } else if (take('USING')) {
      require('(');
      do {
        using.add(identifier());
      } while (take(','));
      require(')');
    }
    if (natural && (on != null || using.isNotEmpty)) {
      throw const SqlException('NATURAL JOIN cannot have ON/USING');
    }
    return QuerySource(
        table: table,
        tableOffset: tableOffset,
        query: query,
        alias: alias,
        join: join,
        on: on,
        using: using,
        natural: natural);
  }

  int _depth = 0;
  Expr expression([int minimum = 0]) {
    if (++_depth > 128) {
      _depth--;
      throw const SqlException('Expression nesting limit exceeded');
    }
    try {
      return _expression(minimum);
    } finally {
      _depth--;
    }
  }

  Expr _expression(int minimum) {
    Expr left;
    if (take('CASE')) {
      Expr? base;
      if (current.keyword != 'WHEN') base = expression();
      final branches = <(Expr, Expr)>[];
      do {
        require('WHEN');
        final condition = expression();
        require('THEN');
        final value = expression();
        branches.add((condition, value));
      } while (current.keyword == 'WHEN');
      final otherwise = take('ELSE') ? expression() : null;
      require('END');
      left = CaseExpr(base, branches, otherwise);
    } else if (take('CAST')) {
      require('(');
      final value = expression();
      require('AS');
      final type = <String>[identifier()];
      while (current.kind == SqlTokenKind.identifier) {
        type.add(identifier());
      }
      if (take('(')) {
        if (current.kind != SqlTokenKind.number) {
          throw const SqlException('Invalid cast type');
        }
        position++;
        if (take(',')) position++;
        require(')');
      }
      require(')');
      left = CastExpr(value, type.join(' '));
    } else if (take('NOT')) {
      left = UnaryExpr('NOT', expression(3));
    } else if (take('+')) {
      left = UnaryExpr('+', expression(15));
    } else if (take('-')) {
      if (current.kind == SqlTokenKind.number &&
          current.text == '9223372036854775808') {
        position++;
        left = Literal(-(BigInt.one << 63));
      } else {
        left = UnaryExpr('-', expression(15));
      }
    } else if (take('~')) {
      left = UnaryExpr('~', expression(15));
    } else if (take('EXISTS')) {
      require('(');
      left = SubqueryExpr(select(nested: true), exists: true);
      require(')');
    } else if (take('(')) {
      left = ['SELECT', 'WITH', 'VALUES'].contains(current.keyword)
          ? SubqueryExpr(select(nested: true))
          : expression();
      require(')');
    } else {
      final token = current;
      position++;
      if (token.kind == SqlTokenKind.number) {
        final text = token.text;
        Object value;
        if (text.toLowerCase().startsWith('0x')) {
          final integer = BigInt.parse(text.substring(2), radix: 16);
          if (integer.bitLength > 64) {
            throw SqlException('Hex integer too large', token.offset);
          }
          value = integer.toSigned(64);
        } else {
          value = numeric(text) ??
              (throw SqlException('Invalid number', token.offset));
        }
        left = Literal(value, value is double ? asciiLower(token.text) : null);
      } else if (token.kind == SqlTokenKind.string) {
        left = Literal(token.text);
      } else if (token.kind == SqlTokenKind.blob) {
        left = Literal(Uint8List.fromList([
          for (var i = 0; i < token.text.length; i += 2)
            int.parse(token.text.substring(i, i + 2), radix: 16)
        ]));
      } else if (token.kind == SqlTokenKind.parameter) {
        final index = token.text.startsWith('?')
            ? token.text.length == 1
                ? parameterCount + 1
                : int.tryParse(token.text.substring(1))
            : parameterNames.putIfAbsent(token.text, () => parameterCount + 1);
        if (index == null || index < 1 || index > 32766) {
          throw const SqlException('Invalid parameter index');
        }
        if (index > parameterCount) parameterCount = index;
        left = ParameterExpr(index - 1);
      } else if (token.keyword == 'NULL') {
        left = Literal(null);
      } else if (token.keyword == 'TRUE' || token.keyword == 'FALSE') {
        left = Literal(boolean(token.keyword == 'TRUE'), token.keyword);
      } else if (['CURRENT_DATE', 'CURRENT_TIME', 'CURRENT_TIMESTAMP']
          .contains(token.keyword)) {
        left = FunctionExpr(asciiLower(token.text), []);
      } else if (token.kind == SqlTokenKind.identifier) {
        if (take('(')) {
          if (asciiLower(token.text) == 'raise') {
            final action = identifier().toUpperCase();
            Expr? message;
            if (action != 'IGNORE') {
              require(',');
              message = expression();
            }
            require(')');
            left = RaiseExpr(action, message);
          } else {
            final args = <Expr>[];
            final argumentOrder = <OrderTerm>[];
            var star = false;
            final distinct = take('DISTINCT');
            if (take('*')) {
              star = true;
              require(')');
            } else if (!take(')')) {
              do {
                args.add(expression());
              } while (take(','));
              if (take('ORDER')) {
                require('BY');
                do {
                  final expr = expression(), descending = take('DESC');
                  if (!descending) take('ASC');
                  argumentOrder.add(OrderTerm(expr, descending, _nulls()));
                } while (take(','));
              }
              require(')');
            }
            left =
                FunctionExpr(token.text, args, distinct: distinct, star: star)
                  ..order.addAll(argumentOrder);
            if (take('FILTER')) {
              final function = left as FunctionExpr;
              if (!function.isAggregate) {
                throw const SqlException('FILTER requires an aggregate');
              }
              require('(');
              require('WHERE');
              function.filter = expression();
              require(')');
            }
            if (take('OVER')) {
              left = _window(left as FunctionExpr);
            }
          }
        } else {
          var name = token.text;
          String? qualifier;
          var columnOffset = token.offset;
          if (take('.')) {
            columnOffset = current.offset;
            qualifier = token.text;
            name += '.${take('*') ? '*' : identifier()}';
          }
          left = ColumnExpr(name,
              offset: token.offset,
              qualifier: qualifier,
              columnOffset: columnOffset);
        }
      } else {
        throw SqlException('Expected expression', token.offset);
      }
    }
    const precedence = {
      'OR': 1,
      'AND': 2,
      '=': 7,
      '==': 7,
      '!=': 7,
      '<>': 7,
      'IS': 7,
      '<': 8,
      '>': 8,
      '<=': 8,
      '>=': 8,
      '&': 10,
      '|': 10,
      '<<': 10,
      '>>': 10,
      '+': 11,
      '-': 11,
      '*': 12,
      '/': 12,
      '%': 12,
      '||': 13,
    };
    while (true) {
      if (minimum <= 14 && take('COLLATE')) {
        left = CollateExpr(left, identifier());
        continue;
      }
      if (minimum <=
              (current.keyword == 'BETWEEN' ||
                      current.keyword == 'NOT' &&
                          tokens[position + 1].keyword == 'BETWEEN'
                  ? 6
                  : 5) &&
          (current.keyword == 'IN' ||
              current.keyword == 'BETWEEN' ||
              current.keyword == 'LIKE' ||
              current.keyword == 'GLOB' ||
              current.keyword == 'NOT' &&
                  ['IN', 'BETWEEN', 'LIKE', 'GLOB']
                      .contains(tokens[position + 1].keyword))) {
        final negate = take('NOT');
        final op = current.keyword;
        position++;
        if (op == 'IN') {
          require('(');
          if (['SELECT', 'WITH', 'VALUES'].contains(current.keyword)) {
            left = InSelectExpr(left, select(nested: true), negate: negate);
            require(')');
            continue;
          }
          final values = <Expr>[];
          if (!take(')')) {
            do {
              values.add(expression());
            } while (take(','));
            require(')');
          }
          left = InExpr(left, values, negate: negate);
        } else if (op == 'BETWEEN') {
          final low = expression(7);
          require('AND');
          left = BetweenExpr(left, low, expression(7), negate: negate);
        } else {
          final pattern = expression(6);
          final escape = take('ESCAPE') ? expression(10) : null;
          left = PatternExpr(left, pattern,
              escape: escape, glob: op == 'GLOB', negate: negate);
        }
        continue;
      }
      if (minimum <= 4 && (take('ISNULL') || take('NOTNULL'))) {
        left = BinaryExpr(
            tokens[position - 1].keyword == 'ISNULL' ? 'IS' : 'IS NOT',
            left,
            Literal(null));
        continue;
      }
      var op =
          current.kind == SqlTokenKind.symbol ? current.text : current.keyword;
      final level = precedence[op];
      if (level == null || level < minimum) break;
      position++;
      if (op == 'IS' && take('NOT')) op = 'IS NOT';
      if ((op == 'IS' || op == 'IS NOT') && take('DISTINCT')) {
        require('FROM');
        op = op == 'IS' ? 'IS NOT' : 'IS';
      }
      if ((op == 'IS' || op == 'IS NOT') &&
          (current.keyword == 'TRUE' || current.keyword == 'FALSE')) {
        final expected = current.keyword == 'TRUE';
        position++;
        left = TruthExpr(left, expected, op == 'IS NOT');
      } else {
        left = BinaryExpr(op, left, expression(level + 1));
      }
    }
    return left;
  }
}
