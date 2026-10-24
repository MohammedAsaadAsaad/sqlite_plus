import 'dart:typed_data';

import 'tokenizer.dart';
import 'values.dart';
import 'functions.dart';

typedef RowValues = Map<String, Object?>;

final class EvalContext {
  EvalContext(this.row, this.affinities, this.parameters, [this.encoding = 1]);
  List<RowValues>? group;
  final Map<Expr, Object?> aggregateValues = {};
  final int encoding;
  final RowValues row;
  final Map<String, String> affinities;
  final List<Object?> parameters;
}

abstract class Expr {
  Iterable<Expr> get children => const [];
  bool get containsAggregate =>
      children.any((child) => child.containsAggregate);
  Object? evaluate(EvalContext context);
  Set<String> get unaggregatedColumns =>
      children.expand((child) => child.unaggregatedColumns).toSet();
  String affinity(EvalContext context) => 'none';
  void validate(Set<String> columns) {}
}

final class Literal extends Expr {
  Literal(this.value);
  final Object? value;
  @override
  Object? evaluate(EvalContext context) => value;
}

final class ColumnExpr extends Expr {
  ColumnExpr(this.name);
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

final class UnaryExpr extends Expr {
  UnaryExpr(this.op, this.operand);
  final String op;
  final Expr operand;
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
            : compareValues(a, b, context.encoding) == 0;
        return boolean(op == 'IS' ? equal : !equal);
      }
      if (a == null || b == null) return null;
      final c = compareValues(a, b, context.encoding);
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
  SelectItem(this.expression, this.label, {this.explicitAlias = false});
  final bool explicitAlias;
  final Expr? expression; // null denotes *
  final String label;
}

final class OrderTerm {
  OrderTerm(this.expression, this.descending);
  final Expr expression;
  final bool descending;
}

final class SelectStatement {
  SelectStatement(this.items, this.table, this.where, this.order, this.limit,
      this.offset, this.distinct, this.parameterCount);
  final List<Expr> groupBy = [];
  Expr? having;
  final List<SelectItem> items;
  final String? table;
  final Expr? where;
  final List<OrderTerm> order;
  final Expr? limit;
  final Expr? offset;
  final bool distinct;
  final int parameterCount;
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

  SelectStatement select() {
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
      final explicitAlias = take('AS');
      final label = explicitAlias
          ? identifier()
          : expr is ColumnExpr
              ? expr.name
              : display;
      items.add(SelectItem(expr, label, explicitAlias: explicitAlias));
    } while (take(','));
    String? table;
    if (take('FROM')) table = identifier();
    final where = take('WHERE') ? expression() : null;
    final groups = <Expr>[];
    if (take('GROUP')) {
      require('BY');
      do {
        groups.add(expression());
      } while (take(','));
    }
    final having = take('HAVING') ? expression() : null;
    final order = <OrderTerm>[];
    if (take('ORDER')) {
      require('BY');
      do {
        final expr = expression();
        final desc = take('DESC');
        if (!desc) take('ASC');
        order.add(OrderTerm(expr, desc));
      } while (take(','));
    }
    Expr? limit;
    Expr? offset;
    if (take('LIMIT')) {
      limit = expression();
      if (take('OFFSET')) {
        offset = expression();
      } else if (take(',')) {
        offset = limit;
        limit = expression();
      }
    }
    finish();
    return SelectStatement(
        items, table, where, order, limit, offset, distinct, parameterCount)
      ..groupBy.addAll(groups)
      ..having = having;
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
    if (take('NOT')) {
      left = UnaryExpr('NOT', expression(3));
    } else if (take('+')) {
      left = UnaryExpr('+', expression(8));
    } else if (take('-')) {
      if (current.kind == SqlTokenKind.number &&
          current.text == '9223372036854775808') {
        position++;
        left = Literal(-(BigInt.one << 63));
      } else {
        left = UnaryExpr('-', expression(8));
      }
    } else if (take('~')) {
      left = UnaryExpr('~', expression(8));
    } else if (take('(')) {
      left = expression();
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
        left = Literal(value);
      } else if (token.kind == SqlTokenKind.string) {
        left = Literal(token.text);
      } else if (token.kind == SqlTokenKind.blob) {
        left = Literal(Uint8List.fromList([
          for (var i = 0; i < token.text.length; i += 2)
            int.parse(token.text.substring(i, i + 2), radix: 16)
        ]));
      } else if (token.kind == SqlTokenKind.parameter) {
        final index = token.text.length == 1
            ? parameterCount + 1
            : int.tryParse(token.text.substring(1));
        if (index == null || index < 1 || index > 32766) {
          throw const SqlException('Invalid parameter index');
        }
        if (index > parameterCount) parameterCount = index;
        left = ParameterExpr(index - 1);
      } else if (token.keyword == 'NULL') {
        left = Literal(null);
      } else if (token.keyword == 'TRUE' || token.keyword == 'FALSE') {
        left = Literal(boolean(token.keyword == 'TRUE'));
      } else if (token.kind == SqlTokenKind.identifier) {
        if (take('(')) {
          final args = <Expr>[];
          var star = false;
          final distinct = take('DISTINCT');
          if (take('*')) {
            star = true;
            require(')');
          } else if (!take(')')) {
            do {
              args.add(expression());
            } while (take(','));
            require(')');
          }
          left = FunctionExpr(token.text, args, distinct: distinct, star: star);
        } else {
          left = ColumnExpr(token.text);
        }
      } else {
        throw SqlException('Expected expression', token.offset);
      }
    }
    const precedence = {
      'OR': 1,
      'AND': 2,
      '=': 3,
      '==': 3,
      '!=': 3,
      '<>': 3,
      'IS': 3,
      '<': 4,
      '>': 4,
      '<=': 4,
      '>=': 4,
      '+': 5,
      '-': 5,
      '*': 6,
      '/': 6,
      '%': 6,
      '||': 7
    };
    while (true) {
      var op =
          current.kind == SqlTokenKind.symbol ? current.text : current.keyword;
      final level = precedence[op];
      if (level == null || level < minimum) break;
      position++;
      if (op == 'IS' && take('NOT')) op = 'IS NOT';
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
