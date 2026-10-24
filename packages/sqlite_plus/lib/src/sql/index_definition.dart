import 'dart:convert';
import 'dart:typed_data';
import 'catalog.dart';
import 'expressions.dart';
import 'functions.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'schema_expressions.dart';

Expr indexOperand(Expr expression) =>
    expression is CollateExpr ? indexOperand(expression.operand) : expression;

/// Structural matching intentionally preserves operand order and literal types.
/// An unsupported expression never matches another unsupported expression.
String? expressionSignature(Expr expression) {
  Object? shape(Expr e) {
    if (e is ColumnExpr) return ['column', e.key];
    if (e is Literal) {
      final v = e.value;
      return [
        'literal',
        v == null
            ? 'null'
            : v is BigInt
                ? 'integer'
                : v is double
                    ? 'real'
                    : v is Uint8List
                        ? 'blob'
                        : 'text',
        v is Uint8List ? base64Encode(v) : v?.toString(),
        e.spelling
      ];
    }
    if (e is UnaryExpr) return ['unary', e.op, shape(e.operand)];
    if (e is BinaryExpr) return ['binary', e.op, shape(e.left), shape(e.right)];
    if (e is CollateExpr) return ['collate', e.name, shape(e.operand)];
    if (e is FunctionExpr) {
      return [
        'function',
        e.key,
        e.distinct,
        e.star,
        e.arguments.map(shape).toList(),
        e.filter == null ? 'absent' : shape(e.filter!),
        [
          for (final term in e.order)
            [shape(term.expression), term.descending, term.nullsFirst]
        ]
      ];
    }
    if (e is CastExpr) return ['cast', e.type.toUpperCase(), shape(e.operand)];
    if (e is CaseExpr) {
      return [
        'case',
        e.base == null ? 'absent' : shape(e.base!),
        [
          for (final branch in e.branches) [shape(branch.$1), shape(branch.$2)]
        ],
        e.otherwise == null ? 'absent' : shape(e.otherwise!)
      ];
    }
    if (e is InExpr) {
      return ['in', e.negate, shape(e.operand), e.values.map(shape).toList()];
    }
    if (e is BetweenExpr) {
      return [
        'between',
        e.negate,
        shape(e.operand),
        shape(e.low),
        shape(e.high)
      ];
    }
    if (e is PatternExpr) {
      return [
        'pattern',
        e.glob,
        e.negate,
        shape(e.operand),
        shape(e.pattern),
        e.escape == null ? 'absent' : shape(e.escape!)
      ];
    }
    if (e is TruthExpr) {
      return ['truth', e.expected, e.negate, shape(e.operand)];
    }
    return null;
  }

  bool supported(Expr e) => shape(e) != null && e.children.every(supported);
  return supported(expression) ? jsonEncode(shape(expression)) : null;
}

bool sameExpression(Expr a, Expr b) {
  final signature = expressionSignature(a);
  return signature != null && signature == expressionSignature(b);
}

final class IndexTerm {
  IndexTerm(this.expression, this.columnName, this.collation, this.descending);
  final Expr expression;
  final String? columnName;
  final String collation;
  final bool descending;
}

final class IndexDefinition {
  IndexDefinition(
      this.name, this.table, this.unique, this.terms, this.predicate);
  final String name, table;
  final bool unique;
  final List<IndexTerm> terms;
  final Expr? predicate;
  Set<String> get referencedColumns => [
        for (final term in terms) term.expression,
        ...[if (predicate != null) predicate!]
      ].expand((e) => e.unaggregatedColumns).toSet();
  static IndexDefinition parse(String sql, CatalogTable table) {
    final p = SqlParser(sql);
    p.require('CREATE');
    final unique = p.take('UNIQUE');
    p.require('INDEX');
    if (p.take('IF')) {
      p.require('NOT');
      p.require('EXISTS');
    }
    final name = p.identifier();
    p.require('ON');
    final target = p.identifier();
    if (asciiLower(target) != asciiLower(table.name)) {
      throw const SqlException('Index table mismatch');
    }
    final context = EvalContext(
        {}, {for (final c in table.columns) asciiLower(c.name): c.affinity}, [])
      ..collations = {
        for (final c in table.columns) asciiLower(c.name): c.collation
      };
    void validate(Expr expression) => validateSchemaExpression(
        expression, table.columns.map((c) => asciiLower(c.name)).toSet());

    p.require('(');
    final terms = <IndexTerm>[];
    do {
      final expression = p.expression();
      validate(expression);
      final operand = indexOperand(expression);
      String? column;
      if (operand is ColumnExpr) {
        column = table.columns
            .firstWhere((c) => asciiLower(c.name) == operand.key)
            .name;
      }
      final collation = expression.collation(context) ?? 'binary';
      final descending = p.take('DESC');
      if (!descending) p.take('ASC');
      terms.add(IndexTerm(expression, column, collation, descending));
    } while (p.take(','));
    p.require(')');
    final predicate = p.take('WHERE') ? p.expression() : null;
    if (predicate != null) validate(predicate);
    p.finish();
    if (p.parameterCount != 0) {
      throw const SqlException('Parameters prohibited in index');
    }
    return IndexDefinition(name, target, unique, terms, predicate);
  }
}

/// Conservative implication: conjuncts, matching OR terms and null-rejecting
/// comparisons. An unproved predicate retains the complete-table path.
bool impliesIndexPredicate(Expr? query, Expr? predicate) {
  if (predicate == null) return true;
  if (query == null) return false;
  final conjuncts = <Expr>[];
  void collect(Expr e) {
    if (e is BinaryExpr && e.op == 'AND') {
      collect(e.left);
      collect(e.right);
    } else {
      conjuncts.add(e);
    }
  }

  collect(query);
  bool implies(Expr needed) {
    if (conjuncts.any((term) => sameExpression(term, needed))) return true;
    if (needed is BinaryExpr && needed.op == 'AND') {
      return implies(needed.left) && implies(needed.right);
    }
    if (needed is BinaryExpr && needed.op == 'OR') {
      return implies(needed.left) || implies(needed.right);
    }
    if (needed is BinaryExpr &&
        needed.op == 'IS NOT' &&
        needed.right is Literal &&
        (needed.right as Literal).value == null) {
      return conjuncts.any((term) =>
          term is BinaryExpr &&
          ['=', '==', '!=', '<>', '<', '<=', '>', '>='].contains(term.op) &&
          (sameExpression(term.left, needed.left) ||
              sameExpression(term.right, needed.left)));
    }
    return needed is Literal && truth(needed.value) == true;
  }

  return implies(predicate);
}
