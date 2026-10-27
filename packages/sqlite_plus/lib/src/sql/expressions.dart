import 'dart:typed_data';

import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

part 'row_assignments.dart';

final class ValueExpr extends Expr {
  ValueExpr(this.value, this.valueAffinity,
      [this.valueCollation, this.valueExplicitCollation]);
  final Object? value;
  final String valueAffinity;
  final String? valueCollation;
  final String? valueExplicitCollation;
  @override
  Object? evaluate(EvalContext context) => value;
  @override
  String affinity(EvalContext context) => valueAffinity;
  @override
  String? collation(EvalContext context) => valueCollation;
  @override
  String? explicitCollation(EvalContext context) => valueExplicitCollation;
}

/// A row is only valid as an operand of the row comparison operators.
final class RowExpr extends Expr {
  RowExpr(this.fields);
  final List<Expr> fields;
  @override
  Iterable<Expr> get children => fields;
  @override
  Object? evaluate(EvalContext context) =>
      throw const SqlException('Row value misused');
  @override
  void validate(Set<String> columns) =>
      throw const SqlException('Row value misused');
}

bool isComparisonOperator(String op) =>
    ['=', '==', '!=', '<>', '<', '>', '<=', '>=', 'IS', 'IS NOT'].contains(op);

int? _rowWidth(Expr expression) {
  if (expression is RowExpr) return expression.fields.length;
  if (expression is SubqueryExpr && !expression.exists) {
    if (expression.statement.preparedColumnCount != null) {
      return expression.statement.preparedColumnCount;
    }
    if (expression.statement.items.any((item) => item.expression == null)) {
      return null;
    }
    return expression.statement.items.length;
  }
  return 1;
}

void _validateRowOperand(Expr expression, Set<String> columns) {
  if (expression is RowExpr) {
    for (final field in expression.fields) {
      field.validate(columns);
    }
  } else if (expression is! SubqueryExpr || expression.exists) {
    expression.validate(columns);
  }
}

void validateComparisonOperands(Expr left, Expr right, Set<String> columns) {
  final width = _rowWidth(left), other = _rowWidth(right);
  if (width != null && other != null && width != other) {
    throw const SqlException('Row value misused');
  }
  _validateRowOperand(left, columns);
  _validateRowOperand(right, columns);
}

List<Expr> _rowFields(Expr expression, EvalContext context) {
  if (expression is RowExpr) return expression.fields;
  if (expression is SubqueryExpr && !expression.exists) {
    final result = expression.result(context);
    return _resultFields(
        result,
        result.rows.isEmpty
            ? List.filled(result.columns.length, null)
            : result.rows.first,
        expression.statement,
        context,
        scalarSubquery: result.columns.length == 1);
  }
  return [expression];
}

List<Expr> _resultFields(SqlRows result, List<Object?> row,
        SelectStatement statement, EvalContext context,
        {bool scalarSubquery = false}) =>
    [
      for (var i = 0; i < result.columns.length; i++)
        ValueExpr(
            row[i],
            result.columnAffinities[i],
            scalarSubquery || result.columnCollations[i].isEmpty
                ? null
                : result.columnCollations[i],
            scalarSubquery || statement.items.length != result.columns.length
                ? null
                : statement.items[i].expression?.explicitCollation(context))
    ];

ValueExpr _snapshotValue(Expr expression, EvalContext context,
        {bool stripAffinity = false}) =>
    ValueExpr(
        expression.evaluate(context),
        stripAffinity ? 'none' : expression.affinity(context),
        expression.collation(context),
        expression.explicitCollation(context));

Expr _snapshotRow(Expr expression, EvalContext context,
    {bool stripAffinity = false}) {
  final fields = _rowFields(expression, context)
      .map((field) =>
          _snapshotValue(field, context, stripAffinity: stripAffinity))
      .toList();
  return fields.length == 1 ? fields.single : RowExpr(fields);
}

Expr _withoutRowCollations(Expr expression, EvalContext context,
    {bool explicitOnly = false}) {
  final fields = _rowFields(expression, context).map((field) {
    final value = field as ValueExpr;
    return ValueExpr(value.value, value.valueAffinity,
        explicitOnly ? value.valueCollation : null);
  }).toList();
  return fields.length == 1 ? fields.single : RowExpr(fields);
}

Object? _inRowEquality(Expr left, Expr right, EvalContext context) {
  final equal = BinaryExpr('=', left, right).evaluate(context);
  if (equal == BigInt.one || left is! RowExpr) return equal;
  // SQLite's lookup and subsequent unknown-result scan can use different
  // collations when only the RHS carries an explicit COLLATE clause.
  final fallback = BinaryExpr(
          '=', left, _withoutRowCollations(right, context, explicitOnly: true))
      .evaluate(context);
  return fallback == BigInt.zero ? BigInt.zero : null;
}

Object? compareRowExpressions(
    String op, Expr left, Expr right, EvalContext context) {
  final a = _rowFields(left, context), b = _rowFields(right, context);
  if (a.length != b.length) {
    throw const SqlException('Row value misused');
  }
  final equality = ['=', '==', '!=', '<>', 'IS', 'IS NOT'].contains(op);
  final identity = op == 'IS' || op == 'IS NOT';
  var unknown = false;
  for (var i = 0; i < a.length; i++) {
    final lhs = _snapshotValue(a[i], context);
    final rhs = _snapshotValue(b[i], context);
    final equal = BinaryExpr(identity ? 'IS' : '=', lhs, rhs).evaluate(context);
    if (equality) {
      if (equal == BigInt.zero) {
        return boolean(['!=', '<>', 'IS NOT'].contains(op));
      }
      if (equal == null) unknown = true;
    } else {
      if (equal == null) return null;
      if (equal == BigInt.zero) {
        return BinaryExpr(op, lhs, rhs).evaluate(context);
      }
    }
  }
  if (unknown) return null;
  return boolean(equality
      ? !['!=', '<>', 'IS NOT'].contains(op)
      : op == '<=' || op == '>=');
}

/// TRUE/FALSE are fallback names: a visible column or result alias wins.
/// Preparation remembers the expression's original scope so expanding an alias
/// cannot recursively capture another alias in the same SELECT list.
final class BoolNameExpr extends ColumnExpr {
  BoolNameExpr(super.name, {super.offset})
      : expected = asciiLower(name) == 'true',
        super(columnOffset: offset);
  final bool expected;
  bool? resolvedLiteral;
  bool literalIn(EvalContext context) =>
      resolvedLiteral ??
      !(context.row.containsKey(key) ||
          context.affinities.containsKey(key) ||
          context.columnAliases.containsKey(key));
  @override
  void validate(Set<String> columns) {
    if (columns.contains(key)) {
      resolvedLiteral = false;
      return;
    }
    if (columns.any((column) => column.endsWith('.$key'))) {
      throw SqlException('Ambiguous column: $name');
    }
    resolvedLiteral = true;
  }

  @override
  Set<String> get unaggregatedColumns => resolvedLiteral == true ? {} : {key};
  @override
  Object? evaluate(EvalContext context) =>
      literalIn(context) ? boolean(expected) : super.evaluate(context);
  @override
  String affinity(EvalContext context) =>
      literalIn(context) ? 'none' : super.affinity(context);
  @override
  String? collation(EvalContext context) =>
      literalIn(context) ? null : super.collation(context);
  @override
  String? explicitCollation(EvalContext context) =>
      literalIn(context) ? null : super.explicitCollation(context);
}

final class CollateExpr extends Expr {
  CollateExpr(this.operand, String name) : name = asciiLower(name) {
    if (!knownCollation(this.name)) {
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
  Iterable<Expr> get children =>
      values.isEmpty ? const [] : [operand, ...values];
  @override
  void validate(Set<String> columns) {
    if (values.isEmpty) return;
    _validateRowOperand(operand, columns);
    for (final expr in values) {
      validateComparisonOperands(operand, expr, columns);
      if (values.length > 1 && expr is SubqueryExpr && _rowWidth(expr) != 1) {
        throw const SqlException('IN list row width mismatch');
      }
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    if (values.isEmpty) return boolean(negate);
    // SQLite materializes a row-valued list before searching it.
    final rowOperand = _rowWidth(operand) != 1;
    var candidates = rowOperand
        ? values
            .map((expr) =>
                _snapshotRow(expr, context, stripAffinity: values.length > 1))
            .toList()
        : values;
    if (rowOperand && values.length > 1) {
      candidates = candidates
          .map((expr) => _withoutRowCollations(expr, context))
          .toList();
    }
    final left = _snapshotRow(operand, context);
    var unknown = false;
    for (final expr in candidates) {
      final equal = left is RowExpr
          ? _inRowEquality(left, expr, context)
          : BinaryExpr('=', left, UnaryExpr('+', expr)).evaluate(context);
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
    validateComparisonOperands(operand, low, columns);
    validateComparisonOperands(operand, high, columns);
  }

  @override
  Object? evaluate(EvalContext context) {
    final value = _snapshotRow(operand, context);
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
    if (base != null) _validateRowOperand(base!, columns);
    for (final branch in branches) {
      if (base == null) {
        branch.$1.validate(columns);
      } else {
        validateComparisonOperands(base!, branch.$1, columns);
      }
      branch.$2.validate(columns);
    }
    otherwise?.validate(columns);
  }

  @override
  Object? evaluate(EvalContext context) {
    final left = base == null ? null : _snapshotRow(base!, context);
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
  String affinity(EvalContext context) =>
      affinityFor(type) == 'none' ? 'blob' : affinityFor(type);
  @override
  Object? evaluate(EvalContext context) {
    final value = operand.evaluate(context);
    if (value == null) return null;
    final upper = type.toUpperCase();
    final affinity = affinityFor(type);
    if (upper.contains('INT')) {
      if (value is BigInt || value is double) return toSqlInteger(value);
      final text = trimSqlWhitespace(stringify(value, context.encoding),
          trailing: false);
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

final class _PreparedSubqueryRows implements SqlRows {
  _PreparedSubqueryRows(this.source, this.columnAffinities);
  final SqlRows source;
  @override
  final List<String> columnAffinities;
  @override
  List<String> get columns => source.columns;
  @override
  List<List<Object?>> get rows => source.rows;
  @override
  List<String> get columnCollations => source.columnCollations;
}

final class SubqueryExpr extends Expr {
  SubqueryExpr(this.statement, {this.exists = false});
  final SelectStatement statement;
  final bool exists;
  List<String>? preparedColumnAffinities;
  List<String>? preparedColumnDeclaredTypes;

  @override
  String affinity(EvalContext context) =>
      !exists && preparedColumnAffinities?.length == 1
          ? preparedColumnAffinities!.single
          : 'none';
  @override
  void validate(Set<String> columns) {
    final width = _rowWidth(this);
    if (!exists && width != null && width != 1) {
      throw const SqlException('Scalar subquery must return one column');
    }
  }

  SqlRows result(EvalContext context) {
    final callback = context.subquery;
    if (callback == null) {
      throw const SqlException('Subquery context unavailable');
    }
    statement.subqueryFirstRowOnly = true;
    statement.subqueryExists = exists;
    final result = callback(statement, context);
    final affinities = preparedColumnAffinities;
    return affinities != null && affinities.length == result.columns.length
        ? _PreparedSubqueryRows(result, affinities)
        : result;
  }

  @override
  Object? evaluate(EvalContext context) {
    final result = this.result(context);
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
  void validate(Set<String> columns) =>
      validateComparisonOperands(operand, SubqueryExpr(statement), columns);
  @override
  Object? evaluate(EvalContext context) {
    final result = context.subquery!(statement, context);
    final left = _snapshotRow(operand, context);
    if ((_rowWidth(left) ?? 1) != result.columns.length) {
      throw const SqlException('IN subquery row width mismatch');
    }
    if (result.rows.isEmpty) return boolean(negate);
    var unknown = false;
    for (final row in result.rows) {
      final fields = _resultFields(result, row, statement, context);
      final right = fields.length == 1 ? fields.single : RowExpr(fields);
      final equal = _inRowEquality(left, right, context);
      if (equal == BigInt.one) return boolean(!negate);
      if (equal == null) unknown = true;
    }
    return unknown ? null : boolean(negate);
  }
}
