import 'dart:typed_data';

import 'tokenizer.dart';
import 'values.dart';
import 'functions.dart';
import 'json_functions.dart';
import 'core_functions.dart' show scalarInt64;
import 'expressions.dart';
import 'triggers.dart';
import 'windows.dart';

abstract interface class SqlRows {
  List<String> get columns;
  List<List<Object?>> get rows;
  List<String> get columnAffinities;
  List<String> get columnCollations;
}

typedef RowValues = Map<String, Object?>;

/// Names in this WITH frame which can be reached from a consumer. Unused WITH
/// declarations are neither resolved nor prepared by SQLite.
Set<String> usedCteNames(SelectStatement statement,
    {SelectStatement? consumer}) {
  final used = <String>{};
  final visited = <SelectStatement>{};
  void visit(SelectStatement query, List<SelectStatement> parents) {
    if (!visited.add(query)) return;
    final frames = [...parents, query];
    for (final source in query.leafSources) {
      if (source.query != null) {
        visit(source.query!, frames);
      } else if (source.table != null && source.schema == null) {
        final name = asciiLower(source.table!);
        for (var i = frames.length - 1; i >= 0; i--) {
          final declaration = frames[i].ctes[name];
          if (declaration == null) continue;
          if (identical(frames[i], statement)) used.add(name);
          visit(declaration.$2, frames.sublist(0, i + 1));
          break;
        }
      }
    }
    void expression(Expr expr) {
      if (expr is SubqueryExpr) visit(expr.statement, frames);
      if (expr is InSelectExpr) visit(expr.statement, frames);
      for (final child in expr.children) {
        expression(child);
      }
    }

    for (final expr in <Expr?>[
      ...query.items.map((item) => item.expression),
      query.where,
      ...query.groupBy,
      query.having,
      ...query.order.map((term) => term.expression),
      query.limit,
      query.offset,
      ...query.allSources.map((source) => source.on),
      ...query.allSources.expand((source) => source.pragmaArguments ?? <Expr>[])
    ].whereType<Expr>()) {
      expression(expr);
    }
    for (final part in query.compounds) {
      visit(part.$2, frames);
    }
  }

  visit(consumer ?? statement, consumer == null ? const [] : [statement]);
  return used;
}

/// A prepared expression substituted for an inline relation column. Each SQL
/// reference evaluates the expression again, like SQLite query flattening.
final class SqlValueBinding {
  SqlValueBinding(this.evaluate);
  final Object? Function() evaluate;
}

Object? resolveSqlValue(Object? value) {
  while (value is SqlValueBinding) {
    value = value.evaluate();
  }
  return value;
}

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
      ..inTrigger = inTrigger
      ..columnAliases = columnAliases;
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
  // Prepared expression aliases are evaluated lazily at their reference site.
  Map<String, Expr> columnAliases = {};
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
  Literal(this.value,
      [this.spelling, this.hexadecimal = false, this.integerBoolean = false]);
  final Object? value;
  final String? spelling;
  final bool hexadecimal;
  // SQLite recognizes bare small integer truth constants for AND/OR folding.
  // Signs, COLLATE, digit separators and larger integers retain evaluation.
  final bool integerBoolean;
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

class ColumnExpr extends Expr {
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
    if (context.row.containsKey(key)) return resolveSqlValue(context.row[key]);
    final alias = context.columnAliases[key];
    if (alias != null) return alias.evaluate(context);
    throw SqlException('No such column: $name');
  }

  @override
  String affinity(EvalContext context) =>
      context.affinities[key] ??
      context.columnAliases[key]?.affinity(context) ??
      'none';
  @override
  String? collation(EvalContext context) => context.collations.containsKey(key)
      ? context.collations[key]?.isEmpty == true
          ? null
          : context.collations[key]
      : context.row.containsKey(key) || context.affinities.containsKey(key)
          ? null
          : context.columnAliases[key]?.collation(context);
  @override
  String? explicitCollation(EvalContext context) =>
      context.row.containsKey(key) || context.affinities.containsKey(key)
          ? null
          : context.columnAliases[key]?.explicitCollation(context);
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
    expression is BoolNameExpr ||
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
    if (op == '~') return ~scalarInt64(value, context.encoding);
    final n = arithmeticNumeric(value, context.encoding) ?? BigInt.zero;
    if (op == '-') return n is BigInt ? narrowInteger(-n) : -(n as double);
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
    if (isComparisonOperator(op)) {
      validateComparisonOperands(left, right, columns);
    } else {
      left.validate(columns);
      right.validate(columns);
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    if (op == 'OR' &&
        [left, right].any((expression) =>
            expression is Literal &&
            expression.integerBoolean &&
            expression.value != BigInt.zero)) {
      return BigInt.one;
    }
    if (isComparisonOperator(op) &&
        (left is RowExpr ||
            right is RowExpr ||
            left is SubqueryExpr && !(left as SubqueryExpr).exists ||
            right is SubqueryExpr && !(right as SubqueryExpr).exists)) {
      return compareRowExpressions(op, left, right, context);
    }
    if (op == 'IS' || op == 'IS NOT') {
      var booleanName = right;
      while (booleanName is CollateExpr) {
        booleanName = booleanName.operand;
      }
      if (booleanName is BoolNameExpr && booleanName.literalIn(context)) {
        final result = truth(left.evaluate(context), context.encoding) ==
            booleanName.expected;
        return boolean(op == 'IS NOT' ? !result : result);
      }
    }
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
      if (la == 'numeric' || ra == 'numeric') {
        a = applyAffinity(a, 'numeric');
        b = applyAffinity(b, 'numeric');
      } else if (la == 'text' && ra == 'none' || ra == 'text' && la == 'none') {
        a = applyAffinity(a, 'text');
        b = applyAffinity(b, 'text');
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
    if (op == '->' || op == '->>') {
      return jsonArrow(a, b, asSql: op == '->>', encoding: context.encoding);
    }
    if (a == null || b == null) return null;
    if (op == '||') {
      return stringify(a, context.encoding) + stringify(b, context.encoding);
    }
    if (['&', '|', '<<', '>>'].contains(op)) {
      final aa = scalarInt64(a, context.encoding);
      final bb = scalarInt64(b, context.encoding);
      if (op == '&') return (aa & bb).toSigned(64);
      if (op == '|') return (aa | bb).toSigned(64);
      final shift = bb.abs() > BigInt.from(64) ? 64 : bb.abs().toInt();
      final leftShift = (op == '<<') == (bb >= BigInt.zero);
      return leftShift
          ? (aa << shift).toSigned(64)
          : (aa.toSigned(64) >> shift);
    }
    // Remainder keeps the operand's integer-prefix conversion even when its
    // numeric classification is REAL (for example, the TEXT value '1e2').
    final remainder = op == '%'
        ? (scalarInt64(a, context.encoding), scalarInt64(b, context.encoding))
        : null;
    a = arithmeticNumeric(a, context.encoding) ?? BigInt.zero;
    b = arithmeticNumeric(b, context.encoding) ?? BigInt.zero;
    if (remainder != null) {
      if (remainder.$2 == BigInt.zero) return null;
      final result = remainder.$1.remainder(remainder.$2);
      return a is BigInt && b is BigInt ? result : result.toDouble();
    }
    if (op == '/' && compareValues(b, BigInt.zero) == 0) {
      return null;
    }
    if (a is BigInt && b is BigInt) {
      return switch (op) {
        '+' => narrowInteger(a + b),
        '-' => narrowInteger(a - b),
        '*' => narrowInteger(a * b),
        '/' => narrowInteger(a ~/ b),
        _ => throw SqlException('Unsupported operator $op'),
      };
    }
    final aa = a is BigInt ? a.toDouble() : a as double;
    final bb = b is BigInt ? b.toDouble() : b as double;
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
  final Map<String, bool> cteMaterialization = {};
  final List<QuerySource> sources = [];

  /// Leaf sources retain SQL scopes; groups remain joined units in execution.
  Iterable<QuerySource> get leafSources => sources.expand((s) => s.leafSources);
  Iterable<QuerySource> get allSources => sources.expand((s) => s.allSources);
  List<QuerySource> get normalizedSources {
    if (sources.isEmpty ||
        sources.first.group.isEmpty ||
        sources.first.alias != null) {
      return sources;
    }
    final first = sources.first;
    final inner =
        SelectStatement([], null, null, [], null, null, false, parameterCount)
          ..sources.addAll(first.group);
    return [...inner.normalizedSources, ...sources.skip(1)];
  }

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

  /// Resolved without evaluating expressions during statement preparation.
  int? preparedColumnCount;
  bool tableInShorthand = false;
  bool subqueryFirstRowOnly = false;
  bool subqueryExists = false;
}

/// Fixed descriptors for the supported metadata PRAGMA table sources. This is
/// deliberately not a general virtual-table or table-function registry.
const pragmaTableColumns = <String, List<String>>{
  'pragma_table_info': ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk'],
  'pragma_table_xinfo': [
    'cid',
    'name',
    'type',
    'notnull',
    'dflt_value',
    'pk',
    'hidden'
  ],
  'pragma_index_list': ['seq', 'name', 'unique', 'origin', 'partial'],
  'pragma_index_info': ['seqno', 'cid', 'name'],
  'pragma_index_xinfo': ['seqno', 'cid', 'name', 'desc', 'coll', 'key'],
  'pragma_foreign_key_list': [
    'id',
    'seq',
    'table',
    'from',
    'to',
    'on_update',
    'on_delete',
    'match'
  ],
  'pragma_database_list': ['seq', 'name', 'file'],
  'pragma_collation_list': ['seq', 'name'],
  'pragma_function_list': ['name', 'builtin', 'type', 'enc', 'narg', 'flags'],
  'pragma_pragma_list': ['name'],
};

bool pragmaTableHasArgument(String name) => !const {
      'pragma_database_list',
      'pragma_collation_list',
      'pragma_function_list',
      'pragma_pragma_list'
    }.contains(asciiLower(name));

final class QuerySource {
  QuerySource(
      {this.table,
      this.tableOffset,
      this.schema,
      this.indexedBy,
      this.notIndexed = false,
      this.rowIdentity,
      this.query,
      this.pragmaArguments,
      this.group = const [],
      this.alias,
      this.join = 'CROSS',
      this.on,
      this.using = const [],
      this.natural = false});
  final String? table, alias, schema, indexedBy;
  final bool notIndexed;

  /// Internal materialized-DML identity; never a user-visible source field.
  final String? rowIdentity;
  final int? tableOffset;
  final SelectStatement? query;

  /// Arguments of a supported read-only PRAGMA table source. Null also permits
  /// ordinary physical tables whose name starts with pragma_.
  final List<Expr>? pragmaArguments;
  final List<QuerySource> group;
  Iterable<QuerySource> get allSources sync* {
    yield this;
    for (final child in group) {
      yield* child.allSources;
    }
  }

  Iterable<QuerySource> get leafSources sync* {
    if (group.isEmpty) {
      yield this;
    } else {
      for (final source in group) {
        yield* source.leafSources;
      }
    }
  }

  final String join;
  final Expr? on;
  final List<String> using;
  final bool natural;
}

/// Strict parser for the M3 single-table SELECT grammar. Unsupported syntax fails.
final class SqlParser {
  SqlParser(String sql,
      {this.deferFunctionResolution = false,
      this.deferFunctionValidation = false})
      : source = sql,
        tokens = SqlTokenizer.tokenize(sql);
  SqlParser.tokens(this.tokens,
      {this.deferFunctionResolution = false,
      this.deferFunctionValidation = false})
      : source = null;
  final String? source;
  bool deferFunctionResolution;
  bool deferFunctionValidation;
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

  /// SQLite stores CREATE object SQL without the leading schema qualifier.
  static String canonicalSchemaCreation(String sql) {
    final parser = SqlParser(sql);
    if (!parser.take('CREATE')) return sql;
    parser.take('UNIQUE');
    if (!['TABLE', 'VIEW', 'INDEX', 'TRIGGER']
        .contains(parser.current.keyword)) {
      return sql;
    }
    parser.position++;
    if (parser.take('IF')) {
      parser.require('NOT');
      parser.require('EXISTS');
    }
    final start = parser.current.offset;
    parser.identifier();
    if (!parser.take('.')) return sql;
    final end = parser.current.offset;
    parser.position =
        parser.tokens.indexWhere((token) => token.offset == start);
    parser.qualifiedIdentifier();
    return sql.substring(0, start) + sql.substring(end);
  }

  /// The engine has one persistent schema. Explicit qualifiers never resolve
  /// through a CTE or silently select an attached database.
  String qualifiedIdentifier({bool allowQualified = true}) {
    final first = identifier();
    if (!take('.')) return first;
    if (!allowQualified) {
      throw const SqlException('Qualified target prohibited in trigger body');
    }
    if (!activeSchemaNames().contains(asciiLower(first))) {
      throw SqlException('Unknown database: $first');
    }
    return identifier();
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
    final materialization = <String, bool>{};
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
          materialization[name] = false;
        } else if (take('MATERIALIZED')) {
          materialization[name] = true;
        }
        require('(');
        final savedResolution = deferFunctionResolution;
        late SelectStatement query;
        deferFunctionResolution = true;
        try {
          query = select(nested: true);
        } finally {
          deferFunctionResolution = savedResolution;
        }
        require(')');
        ctes[name] = (columns, query);
      } while (take(','));
    }
    if (take('VALUES')) {
      return _values(ctes, nested: nested, component: component)
        ..cteMaterialization.addAll(materialization);
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
          : expr is ColumnExpr && expr is! BoolNameExpr
              ? expr.name
              : display;
      items.add(expr is ColumnExpr && expr.name.endsWith('.*')
          ? SelectItem(null, expr.name, qualifierOffset: expr.offset)
          : SelectItem(expr, label, explicitAlias: explicitAlias));
    } while (take(','));
    final sources = take('FROM') ? _joinedSources() : <QuerySource>[];
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
      ..cteMaterialization.addAll(materialization)
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
    final explicitExclusion = take('EXCLUDE');
    if (explicitExclusion) {
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
      ..explicitExclusion = explicitExclusion
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
        'DESC',
        'INDEXED',
        'NOT'
      }.contains(current.keyword);

  /// Parse a joined source list at the current token offset.
  List<QuerySource> joinedSources() => _joinedSources();

  List<QuerySource> _joinedSources() {
    final sources = [_source('CROSS', false)];
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
    return sources;
  }

  int _sourceDepth = 0;
  QuerySource _source(String join, bool natural) {
    String? table, schema, indexedBy;
    var notIndexed = false;
    int? tableOffset;
    SelectStatement? query;
    List<Expr>? pragmaArguments;
    var group = <QuerySource>[];
    if (take('(')) {
      if (++_sourceDepth > 128) {
        throw const SqlException('Source nesting limit exceeded');
      }
      try {
        if (['SELECT', 'WITH', 'VALUES'].contains(current.keyword)) {
          query = select(nested: true);
        } else {
          group = _joinedSources();
        }
        require(')');
      } finally {
        _sourceDepth--;
      }
    } else {
      tableOffset = current.offset;
      table = identifier();
      if (take('.')) {
        schema = asciiLower(table);
        if (!activeSchemaNames().contains(schema)) {
          throw SqlException('Unknown database: $table');
        }
        tableOffset = current.offset;
        table = identifier();
      }
      if (take('(')) {
        final knownPragma = pragmaTableColumns.containsKey(asciiLower(table));
        pragmaArguments = [];
        if (!take(')')) {
          do {
            pragmaArguments.add(expression());
          } while (take(','));
          require(')');
        }
        final maximum = knownPragma
            ? pragmaTableHasArgument(table)
                ? 2
                : 0
            : 16;
        if (pragmaArguments.length > maximum) {
          throw SqlException('Too many arguments on $table()');
        }
      }
    }
    final alias = take('AS') || _implicitAlias() ? _alias() : null;
    if (query == null && group.isEmpty && pragmaArguments == null) {
      if (take('INDEXED')) {
        require('BY');
        indexedBy = identifier();
      } else if (take('NOT')) {
        require('INDEXED');
        notIndexed = true;
      }
    }
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
    if (group.length == 1) {
      final child = group.single;
      return QuerySource(
          table: child.table,
          tableOffset: child.tableOffset,
          schema: child.schema,
          indexedBy: child.indexedBy,
          notIndexed: child.notIndexed,
          query: child.query,
          pragmaArguments: child.pragmaArguments,
          group: child.group,
          alias: alias ?? child.alias,
          join: join,
          on: on ?? child.on,
          using: using.isEmpty ? child.using : using,
          natural: natural || child.natural);
    }
    return QuerySource(
        table: table,
        tableOffset: tableOffset,
        schema: schema,
        indexedBy: indexedBy,
        notIndexed: notIndexed,
        query: query,
        pragmaArguments: pragmaArguments,
        group: group,
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
          RegExp(r'^0*9223372036854775808$')
              .hasMatch(current.text.replaceAll('_', ''))) {
        position++;
        left = Literal(-(BigInt.one << 63));
      } else {
        final operand = expression(15);
        Expr constant = operand;
        while (constant is UnaryExpr && constant.op == '+') {
          constant = constant.operand;
        }
        if (constant is Literal &&
            constant.hexadecimal &&
            constant.value == -(BigInt.one << 63)) {
          throw const SqlException('Hex integer too large after negation');
        }
        left = UnaryExpr('-', operand);
      }
    } else if (take('~')) {
      left = UnaryExpr('~', expression(15));
    } else if (take('EXISTS')) {
      require('(');
      left = SubqueryExpr(select(nested: true), exists: true);
      require(')');
    } else if (take('(')) {
      if (['SELECT', 'WITH', 'VALUES'].contains(current.keyword)) {
        left = SubqueryExpr(select(nested: true));
      } else {
        left = expression();
        if (take(',')) {
          final fields = <Expr>[left];
          do {
            fields.add(expression());
          } while (take(','));
          left = RowExpr(fields);
        }
      }
      require(')');
    } else {
      final token = current;
      position++;
      if (token.kind == SqlTokenKind.number) {
        final text = token.text.replaceAll('_', '');
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
        left = Literal(
            value,
            value is double ? asciiLower(text) : null,
            asciiLower(text).startsWith('0x'),
            !token.text.contains('_') &&
                value is BigInt &&
                value >= BigInt.zero &&
                value <= BigInt.from(0x7fffffff));
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
        left = BoolNameExpr(token.text, offset: token.offset);
      } else if (['CURRENT_DATE', 'CURRENT_TIME', 'CURRENT_TIMESTAMP']
          .contains(token.keyword)) {
        left = FunctionExpr(asciiLower(token.text), [],
            deferResolution: deferFunctionResolution,
            deferValidation: deferFunctionValidation);
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
            left = FunctionExpr(token.text, args,
                distinct: distinct,
                star: star,
                deferResolution: deferFunctionResolution,
                deferValidation: deferFunctionValidation)
              ..order.addAll(argumentOrder);
            if (take('FILTER')) {
              final function = left as FunctionExpr;
              if (!deferFunctionResolution && !function.isAggregate) {
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
          var referenceOffset = token.offset;
          if (take('.')) {
            columnOffset = current.offset;
            qualifier = token.text;
            final second = take('*') ? '*' : identifier();
            name += '.$second';
            if (take('.')) {
              final database = asciiLower(token.text);
              if (!activeSchemaNames().contains(database) || second == '*') {
                throw SqlException('Unknown database: ${token.text}');
              }
              referenceOffset = columnOffset;
              qualifier = '$database.$second';
              columnOffset = current.offset;
              name = '$database.$second.${identifier()}';
            }
          }
          left = ColumnExpr(name,
              offset: referenceOffset,
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
      '->': 12,
      '->>': 12,
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
              current.keyword == 'REGEXP' ||
              current.keyword == 'MATCH' ||
              current.keyword == 'NOT' &&
                  ['IN', 'BETWEEN', 'LIKE', 'GLOB', 'REGEXP', 'MATCH']
                      .contains(tokens[position + 1].keyword))) {
        final negate = take('NOT');
        final op = current.keyword;
        position++;
        if (op == 'IN') {
          if (!take('(')) {
            var tableOffset = current.offset;
            var name = identifier();
            String? schema;
            if (take('.')) {
              schema = asciiLower(name);
              if (!activeSchemaNames().contains(schema)) {
                throw SqlException('Unknown database: $name');
              }
              tableOffset = current.offset;
              name = identifier();
            }
            final query = SelectStatement([SelectItem(null, '*')], name, null,
                [], null, null, false, parameterCount)
              ..tableInShorthand = true
              ..sources.add(QuerySource(
                  table: name, schema: schema, tableOffset: tableOffset));
            left = InSelectExpr(left, query, negate: negate);
            continue;
          }
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
          // SQLite lowers pattern operators to their SQL function. The pattern
          // is the first argument, including when a connection replaces LIKE
          // or GLOB or supplies REGEXP/MATCH itself.
          final function = FunctionExpr(
              asciiLower(op), [pattern, left, if (escape != null) escape],
              deferResolution: deferFunctionResolution,
              deferValidation: deferFunctionValidation);
          left = negate ? UnaryExpr('NOT', function) : function;
        }
        continue;
      }
      if (minimum <= 4 &&
          (current.keyword == 'ISNULL' ||
              current.keyword == 'NOTNULL' ||
              current.keyword == 'NOT' &&
                  tokens[position + 1].keyword == 'NULL')) {
        final negate = current.keyword != 'ISNULL';
        position += current.keyword == 'NOT' ? 2 : 1;
        left = BinaryExpr(negate ? 'IS NOT' : 'IS', left, Literal(null));
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
      final right = expression(level + 1);
      bool constant(Expr expression, bool expected) =>
          expression is Literal &&
          expression.integerBoolean &&
          (expression.value != BigInt.zero) == expected;
      left = op == 'AND' &&
              !left.containsAggregate &&
              !right.containsAggregate &&
              !left.containsWindow &&
              !right.containsWindow &&
              (constant(left, false) || constant(right, false))
          ? Literal(BigInt.zero, null, false, true)
          : BinaryExpr(op, left, right);
    }
    return left;
  }
}
