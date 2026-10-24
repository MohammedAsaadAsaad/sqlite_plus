import 'dart:typed_data';

import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

final class ValueExpr extends Expr {
  ValueExpr(this.value, this.valueAffinity, [this.valueCollation]);
  final Object? value;
  final String valueAffinity;
  final String? valueCollation;
  @override
  Object? evaluate(EvalContext context) => value;
  @override
  String affinity(EvalContext context) => valueAffinity;
  @override
  String? collation(EvalContext context) => valueCollation;
}

final class CollateExpr extends Expr {
  CollateExpr(this.operand, String name) : name = asciiLower(name) {
    if (!['binary', 'nocase', 'rtrim'].contains(this.name)) {
      throw SqlException('No such collation: $name');
    }
  }
  final Expr operand;
  final String name;
  @override
  Iterable<Expr> get children => [operand];
  @override
  void validate(Set<String> columns) => operand.validate(columns);
  @override
  Object? evaluate(EvalContext context) => operand.evaluate(context);
  @override
  String affinity(EvalContext context) => operand.affinity(context);
  @override
  String? collation(EvalContext context) => name;
  @override
  String? explicitCollation(EvalContext context) => name;
}

final class InExpr extends Expr {
  InExpr(this.operand, this.values, {this.negate = false});
  final Expr operand;
  final List<Expr> values;
  final bool negate;
  @override
  Iterable<Expr> get children => [operand, ...values];
  @override
  void validate(Set<String> columns) {
    for (final expr in children) {
      expr.validate(columns);
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    if (values.isEmpty) return boolean(negate);
    final left = ValueExpr(operand.evaluate(context), operand.affinity(context),
        operand.collation(context));
    var unknown = false;
    for (final expr in values) {
      final equal =
          BinaryExpr('=', left, UnaryExpr('+', expr)).evaluate(context);
      if (equal == BigInt.one) return boolean(!negate);
      if (equal == null) unknown = true;
    }
    return unknown ? null : boolean(negate);
  }
}

final class BetweenExpr extends Expr {
  BetweenExpr(this.operand, this.low, this.high, {this.negate = false});
  final Expr operand, low, high;
  final bool negate;
  @override
  Iterable<Expr> get children => [operand, low, high];
  @override
  void validate(Set<String> columns) {
    for (final expr in children) {
      expr.validate(columns);
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    final value = ValueExpr(operand.evaluate(context),
        operand.affinity(context), operand.collation(context));
    final result = BinaryExpr(
            'AND', BinaryExpr('>=', value, low), BinaryExpr('<=', value, high))
        .evaluate(context);
    return result == null
        ? null
        : boolean(negate ? result == BigInt.zero : result == BigInt.one);
  }
}

final class CaseExpr extends Expr {
  CaseExpr(this.base, this.branches, this.otherwise);
  final Expr? base, otherwise;
  final List<(Expr, Expr)> branches;
  @override
  Iterable<Expr> get children => [
        if (base != null) base!,
        for (final b in branches) ...[b.$1, b.$2],
        if (otherwise != null) otherwise!
      ];
  @override
  void validate(Set<String> columns) {
    for (final expr in children) {
      expr.validate(columns);
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    final left = base == null
        ? null
        : ValueExpr(base!.evaluate(context), base!.affinity(context),
            base!.collation(context));
    for (final branch in branches) {
      final condition = left == null
          ? branch.$1.evaluate(context)
          : BinaryExpr('=', left, branch.$1).evaluate(context);
      if (truth(condition, context.encoding) == true) {
        return branch.$2.evaluate(context);
      }
    }
    return otherwise?.evaluate(context);
  }
}

final class CastExpr extends Expr {
  CastExpr(this.operand, this.type);
  final Expr operand;
  final String type;
  @override
  String? collation(EvalContext context) => operand.collation(context);
  @override
  Iterable<Expr> get children => [operand];
  @override
  void validate(Set<String> columns) => operand.validate(columns);
  @override
  String affinity(EvalContext context) => affinityFor(type);
  @override
  Object? evaluate(EvalContext context) {
    final value = operand.evaluate(context);
    if (value == null) return null;
    final upper = type.toUpperCase();
    final affinity = affinityFor(type);
    if (upper.contains('INT')) {
      if (value is BigInt || value is double) return toSqlInteger(value);
      final text = stringify(value, context.encoding).trimLeft();
      final prefix = RegExp(r'^[+-]?[0-9]+').firstMatch(text)?[0];
      return clampInteger(prefix == null ? BigInt.zero : BigInt.parse(prefix));
    }
    if (affinity == 'text') return stringify(value, context.encoding);
    if (affinity == 'none') {
      return value is Uint8List
          ? Uint8List.fromList(value)
          : Uint8List.fromList(
              encodeSqlText(stringify(value), context.encoding));
    }
    final number =
        numeric(value, prefix: true, encoding: context.encoding) ?? BigInt.zero;
    if (['REAL', 'FLOA', 'DOUB'].any(upper.contains)) {
      return number is BigInt ? number.toDouble() : number;
    }
    if (value is BigInt || value is double) return value;
    if (number is double &&
        number.isFinite &&
        number == number.truncateToDouble() &&
        BigInt.from(number).bitLength <= 51) {
      return BigInt.from(number);
    }
    return number;
  }
}

BigInt clampInteger(BigInt value) => value < -(BigInt.one << 63)
    ? -(BigInt.one << 63)
    : value >= (BigInt.one << 63)
        ? (BigInt.one << 63) - BigInt.one
        : value;

final class PatternExpr extends Expr {
  PatternExpr(this.operand, this.pattern,
      {this.escape, this.glob = false, this.negate = false});
  final Expr operand, pattern;
  final Expr? escape;
  final bool glob, negate;
  @override
  Iterable<Expr> get children =>
      [operand, pattern, if (escape != null) escape!];
  @override
  void validate(Set<String> columns) {
    for (final expr in children) {
      expr.validate(columns);
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    final value = operand.evaluate(context);
    final p = pattern.evaluate(context);
    final e = escape?.evaluate(context);
    if (value == null || p == null || escape != null && e == null) return null;
    // The pinned reference is built without LIKE_DOESNT_MATCH_BLOBS.
    final text =
        stringify(value, context.encoding).split('\u0000').first.runes.toList();
    final pat =
        stringify(p, context.encoding).split('\u0000').first.runes.toList();
    int? esc;
    if (escape != null) {
      final units = stringify(e!, context.encoding).runes.toList();
      if (units.length != 1) {
        throw const SqlException(
            'ESCAPE expression must be a single character');
      }
      esc = units.single;
    }
    if (pat.length > 50000 || (pat.length + 1) * (text.length + 1) > 4000000) {
      throw const SqlException('Pattern complexity limit exceeded');
    }
    var state = List<bool>.filled(text.length + 1, false)..[0] = true;
    bool literal(int a, int b) => glob
        ? a == b
        : (a >= 65 && a <= 90 ? a + 32 : a) ==
            (b >= 65 && b <= 90 ? b + 32 : b);
    for (var i = 0; i < pat.length; i++) {
      final c = pat[i];
      var star = glob ? c == 42 : c == 37;
      var any = glob ? c == 63 : c == 95;
      bool Function(int) accept = (v) => literal(c, v);
      if (esc != null && c == esc) {
        if (++i >= pat.length) return boolean(negate);
        final next = pat[i];
        star = false;
        any = false;
        accept = (v) => literal(next, v);
      } else if (glob && c == 91) {
        var j = i + 1;
        var inverted = false;
        if (j < pat.length && pat[j] == 94) {
          inverted = true;
          j++;
        }
        final ranges = <(int, int)>[];
        if (j < pat.length && pat[j] == 93) {
          ranges.add((93, 93));
          j++;
        }
        while (j < pat.length && pat[j] != 93) {
          final start = pat[j++];
          var end = start;
          if (j + 1 < pat.length && pat[j] == 45 && pat[j + 1] != 93) {
            j++;
            end = pat[j++];
          }
          ranges.add((start, end));
        }
        if (j >= pat.length) return boolean(negate);
        i = j;
        accept = (v) => ranges.any((r) => v >= r.$1 && v <= r.$2) != inverted;
      }
      final next = List<bool>.filled(text.length + 1, false);
      if (star) {
        next[0] = state[0];
        for (var k = 1; k <= text.length; k++) {
          next[k] = state[k] || next[k - 1];
        }
      } else {
        for (var k = 1; k <= text.length; k++) {
          next[k] = state[k - 1] && (any || accept(text[k - 1]));
        }
      }
      state = next;
    }
    return boolean(negate ? !state.last : state.last);
  }
}

final class SubqueryExpr extends Expr {
  SubqueryExpr(this.statement, {this.exists = false});
  final SelectStatement statement;
  final bool exists;
  @override
  Object? evaluate(EvalContext context) {
    final callback = context.subquery;
    if (callback == null) {
      throw const SqlException('Subquery context unavailable');
    }
    final result = callback(statement, context);
    if (exists) return boolean(result.rows.isNotEmpty);
    if (result.columns.length != 1) {
      throw const SqlException('Scalar subquery must return one column');
    }
    return result.rows.isEmpty ? null : result.rows.first.single;
  }
}

final class InSelectExpr extends Expr {
  InSelectExpr(this.operand, this.statement, {this.negate = false});
  final Expr operand;
  final SelectStatement statement;
  final bool negate;
  @override
  Iterable<Expr> get children => [operand];
  @override
  void validate(Set<String> columns) => operand.validate(columns);
  @override
  Object? evaluate(EvalContext context) {
    final result = context.subquery!(statement, context);
    if (result.columns.length != 1) {
      throw const SqlException('IN subquery must return one column');
    }
    final affinity = result.columnAffinities.first;
    if (result.rows.isEmpty) return boolean(negate);
    final left = ValueExpr(operand.evaluate(context), operand.affinity(context),
        operand.collation(context));
    var unknown = false;
    for (final row in result.rows) {
      final equal = BinaryExpr('=', left, ValueExpr(row.single, affinity))
          .evaluate(context);
      if (equal == BigInt.one) return boolean(!negate);
      if (equal == null) unknown = true;
    }
    return unknown ? null : boolean(negate);
  }
}
