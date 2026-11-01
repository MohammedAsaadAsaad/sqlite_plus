import 'dart:convert';
import 'dart:typed_data';

import 'database.dart';
import 'expressions.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

const _columns = ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment'];
final _minInt64 = -(BigInt.one << 63);
final _maxInt64 = (BigInt.one << 63) - BigInt.one;
final _minIntegerOpcode = BigInt.from(-2147483647);
final _maxIntegerOpcode = BigInt.from(2147483647);
final _maxUint31 = BigInt.from(2147483647);

/// One ordinary table the bytecode may open.
final class ExplainTable {
  ExplainTable(this.name, this.rootPage, this.columns,
      {this.rowidAlias,
      this.withoutRowid = false,
      this.generated = false,
      this.affinity = false,
      this.indexed = false,
      this.notNull = false,
      this.defaults = const []});

  /// Catalog name. `OP_Insert` stores it in p4.
  final String name;

  /// B-tree root page.
  final int rootPage;

  /// Declared column names, in order.
  final List<String> columns;

  /// Integer primary key that aliases rowid, if any.
  final String? rowidAlias;

  /// `WITHOUT ROWID` tables use a different insert program.
  final bool withoutRowid;

  /// A generated column changes both the scan and the insert program.
  final bool generated;

  /// A declared type puts an affinity string on `OP_MakeRecord`.
  final bool affinity;

  /// A primary key or unique index adds cursors to an insert.
  final bool indexed;

  /// `NOT NULL` adds a constraint opcode to an insert.
  final bool notNull;

  /// True when that column's explicit `DEFAULT` would be coded.
  final List<bool> defaults;
}

/// Schema cookie and table lookup for `EXPLAIN` programs that open a b-tree.
final class ExplainSchema {
  ExplainSchema({required this.cookie, required this.table});

  /// Header schema cookie. `OP_Transaction` stores it in p3.
  final int cookie;

  /// Returns null when [name] is missing, a view, or a virtual table.
  final ExplainTable? Function(String name) table;
}

const _binaryOpcodes = {
  '+': 'Add',
  '-': 'Subtract',
  '*': 'Multiply',
  '/': 'Divide',
  '%': 'Remainder',
  '||': 'Concat',
};

/// Bytecode for a bounded `EXPLAIN` program.
///
/// Covered shapes are a literal projection, arithmetic and concatenation of
/// constants, a constant `WHERE`, one ordinary table scan, and one
/// `INSERT` or `REPLACE` of constants. Anything else returns null. The caller
/// keeps the existing rejection. This is not a VDBE.
QueryResult? compileLiteralExplain(String sql, {ExplainSchema? schema}) {
  try {
    final head = SqlParser(sql);
    if (head.take('INSERT') || head.take('REPLACE')) {
      if (schema == null) return null;
      return _compileInsert(sql, schema);
    }
    final statement = SqlParser(sql).select();
    if (statement.parameterCount != 0 ||
        statement.order.isNotEmpty ||
        statement.limit != null ||
        statement.offset != null ||
        statement.distinct ||
        statement.groupBy.isNotEmpty ||
        statement.having != null ||
        statement.compounds.isNotEmpty ||
        statement.ctes.isNotEmpty ||
        statement.windowDefinitions.isNotEmpty ||
        statement.valuesQuery ||
        statement.items.isEmpty) {
      return null;
    }
    if (_isPlainScan(statement)) {
      return schema == null ? null : _compileScan(statement, schema);
    }
    if (statement.sources.isNotEmpty || statement.table != null) return null;
    return _compileProjection(statement);
  } on SqlException {
    return null;
  } on _Uncompiled {
    return null;
  }
}

final class _Uncompiled implements Exception {
  const _Uncompiled();
}

List<Object?> _row(
        int addr, String opcode, BigInt p1, BigInt p2, BigInt p3, Object? p4,
        {BigInt? p5}) =>
    [BigInt.from(addr), opcode, p1, p2, p3, p4, p5 ?? BigInt.zero, null];

final class _Op {
  _Op(this.name, this.p1, this.p2, this.p3, this.p4, {this.p5 = 0});
  final String name;
  final BigInt p1;
  final BigInt p2;
  final BigInt p3;
  final Object? p4;
  final int p5;
}

final class _Queued {
  _Queued(this.expr, this.reg, this.reusable);
  final Expr expr;
  final int reg;
  final bool reusable;
}

/// Register numbers follow SQLite's constant factoring.
///
/// A constant operand of a loop opcode is queued and later coded once, after
/// `OP_Halt`. Identical reusable constants share a register. A constant that
/// is itself a result column is coded in the main program. Nested constants
/// inside a queued expression use temporary registers, freed left then right.
final class _Coder {
  final main = <_Op>[];
  final once = <_Op>[];
  final _temps = <int>[];
  final _queue = <_Queued>[];
  var nMem = 0;
  var factor = true;
  var _intoOnce = false;
  int? haltJump;

  List<_Op> get _out => _intoOnce ? once : main;

  int reserveResults(int count) {
    final start = nMem + 1;
    nMem += count;
    return start;
  }

  void jumpToHalt(String name, {int p1 = 0, int p3 = 0}) {
    main.insert(
        0, _Op(name, BigInt.from(p1), BigInt.zero, BigInt.from(p3), null));
    haltJump = 0;
  }

  int _tempReg() => _temps.isEmpty ? ++nMem : _temps.removeLast();

  void _release(int reg) {
    if (reg != 0) _temps.add(reg);
  }

  int queueConst(Expr expr) {
    for (final item in _queue) {
      if (item.reusable && _sameExpr(item.expr, expr)) return item.reg;
    }
    final reg = ++nMem;
    _queue.add(_Queued(expr, reg, true));
    return reg;
  }

  void queueTargeted(Expr expr, int reg) {
    _queue.add(_Queued(expr, reg, false));
  }

  void emitLiteral(Expr expr, int dest) {
    final op = _literalOpcode(expr, dest)!;
    _out.add(_Op(op[0] as String, op[1] as BigInt, op[2] as BigInt,
        op[3] as BigInt, op[4]));
  }

  (int, int) codeTemp(Expr expr) {
    if (factor && _isConstant(expr)) return (queueConst(expr), 0);
    final reg = _tempReg();
    codeTarget(expr, reg);
    return (reg, reg);
  }

  void codeTarget(Expr expr, int dest) {
    if (_literalOpcode(expr, dest) != null) {
      emitLiteral(expr, dest);
      return;
    }
    if (expr is UnaryExpr && expr.op == '+') {
      codeTarget(expr.operand, dest);
      return;
    }
    if (expr is UnaryExpr && expr.op == '-') {
      final (left, freeLeft) = codeTemp(_zero);
      final (right, freeRight) = codeTemp(expr.operand);
      _out.add(_Op('Subtract', BigInt.from(right), BigInt.from(left),
          BigInt.from(dest), null));
      _release(freeLeft);
      _release(freeRight);
      return;
    }
    final opcode = expr is BinaryExpr ? _binaryOpcodes[expr.op] : null;
    if (opcode == null || expr is! BinaryExpr) throw const _Uncompiled();
    final (left, freeLeft) = codeTemp(expr.left);
    final (right, freeRight) = codeTemp(expr.right);
    _out.add(_Op(opcode, BigInt.from(right), BigInt.from(left),
        BigInt.from(dest), null));
    _release(freeLeft);
    _release(freeRight);
  }

  void flush() {
    factor = false;
    _intoOnce = true;
    for (final item in _queue) {
      codeTarget(item.expr, item.reg);
    }
  }
}

final _zero = Literal(BigInt.zero, '0');
final _null = Literal(null);

enum _WhereKind { none, provenTrue, provenFalse, test, unsupported }

_WhereKind _whereKind(Expr? where) {
  if (where == null) return _WhereKind.none;
  if (where is UnaryExpr && where.op == 'NOT') {
    return switch (_whereKind(where.operand)) {
      _WhereKind.provenTrue => _WhereKind.provenFalse,
      _WhereKind.provenFalse => _WhereKind.provenTrue,
      _ => _WhereKind.unsupported,
    };
  }
  if (where is BoolNameExpr) {
    return where.expected ? _WhereKind.provenTrue : _WhereKind.provenFalse;
  }
  if (where is Literal && where.value is BigInt) {
    return where.value == BigInt.zero
        ? _WhereKind.provenFalse
        : _WhereKind.provenTrue;
  }
  if (_isConstant(where)) return _WhereKind.test;
  return _WhereKind.unsupported;
}

bool _isConstant(Expr expr) {
  if (expr is Literal || expr is BoolNameExpr) return true;
  if (expr is UnaryExpr && (expr.op == '+' || expr.op == '-')) {
    return _isConstant(expr.operand);
  }
  if (expr is BinaryExpr && _binaryOpcodes.containsKey(expr.op)) {
    return _isConstant(expr.left) && _isConstant(expr.right);
  }
  return false;
}

bool _sameExpr(Expr left, Expr right) {
  if (left is Literal && right is Literal) {
    final a = left.value;
    final b = right.value;
    if (a is Uint8List && b is Uint8List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return a == b && a.runtimeType == b.runtimeType;
  }
  if (left is BoolNameExpr && right is BoolNameExpr) {
    return left.expected == right.expected;
  }
  if (left is UnaryExpr && right is UnaryExpr) {
    return left.op == right.op && _sameExpr(left.operand, right.operand);
  }
  if (left is BinaryExpr && right is BinaryExpr) {
    return left.op == right.op &&
        _sameExpr(left.left, right.left) &&
        _sameExpr(left.right, right.right);
  }
  return false;
}

void _prepareWhere(_Coder coder, Expr? where) {
  final kind = _whereKind(where);
  if (kind == _WhereKind.unsupported) throw const _Uncompiled();
  if (kind == _WhereKind.test) {
    coder.jumpToHalt('IfNot', p1: coder.queueConst(where!), p3: 1);
  } else if (kind == _WhereKind.provenFalse) {
    coder.jumpToHalt('Goto');
  }
}

QueryResult? _compileProjection(SelectStatement statement) {
  if (_whereKind(statement.where) == _WhereKind.unsupported) return null;
  final coder = _Coder();
  _prepareWhere(coder, statement.where);
  final start = coder.reserveResults(statement.items.length);
  for (var i = 0; i < statement.items.length; i++) {
    final expression = statement.items[i].expression;
    if (expression == null) return null;
    coder.codeTarget(expression, start + i);
  }
  coder.main.add(_Op('ResultRow', BigInt.from(start),
      BigInt.from(statement.items.length), BigInt.zero, null));
  coder.flush();
  return _finish(coder);
}

bool _isPlainScan(SelectStatement statement) {
  if (statement.sources.length != 1) return false;
  final source = statement.sources.single;
  final schema = source.schema;
  return source.table != null &&
      source.query == null &&
      source.group.isEmpty &&
      source.using.isEmpty &&
      !source.natural &&
      (schema == null || asciiLower(schema) == 'main') &&
      source.on == null &&
      !source.notIndexed &&
      source.indexedBy == null;
}

bool _names(String? left, String right) =>
    left != null && asciiLower(left) == asciiLower(right);

QueryResult? _compileScan(SelectStatement statement, ExplainSchema schema) {
  if (_whereKind(statement.where) == _WhereKind.unsupported) return null;
  final source = statement.sources.single;
  final table = schema.table(source.table!);
  if (table == null ||
      table.rootPage <= 0 ||
      table.withoutRowid ||
      table.rowidAlias != null ||
      table.generated) {
    return null;
  }
  final indexes = <int>[];
  if (statement.items.length == 1 &&
      statement.items.single.expression == null) {
    final label = statement.items.single.label;
    if (label != '*') {
      final qualifier =
          label.endsWith('.*') ? label.substring(0, label.length - 2) : null;
      if (qualifier == null ||
          (!_names(qualifier, table.name) &&
              !_names(qualifier, source.alias ?? ''))) {
        return null;
      }
    }
    indexes.addAll(List.generate(table.columns.length, (index) => index));
  } else {
    for (final item in statement.items) {
      final expression = item.expression;
      if (expression is! ColumnExpr || expression is BoolNameExpr) return null;
      final qualifier = expression.qualifier;
      if (qualifier != null &&
          !_names(qualifier, table.name) &&
          !_names(qualifier, source.alias ?? '')) {
        return null;
      }
      final column = qualifier == null
          ? expression.name
          : expression.name.substring(expression.name.lastIndexOf('.') + 1);
      final index = table.columns
          .indexWhere((name) => asciiLower(name) == asciiLower(column));
      if (index < 0) return null;
      indexes.add(index);
    }
  }
  if (indexes.isEmpty) return null;
  final width = indexes.reduce((a, b) => a > b ? a : b) + 1;
  final coder = _Coder();
  _prepareWhere(coder, statement.where);
  final start = coder.reserveResults(indexes.length);
  coder.main.add(_Op('OpenRead', BigInt.zero, BigInt.from(table.rootPage),
      BigInt.zero, '$width'));
  final rewind = coder.main.length;
  coder.main.add(_Op('Rewind', BigInt.zero, BigInt.zero, BigInt.zero, null));
  for (var i = 0; i < indexes.length; i++) {
    coder.main.add(_Op('Column', BigInt.zero, BigInt.from(indexes[i]),
        BigInt.from(start + i), null));
  }
  coder.main.add(_Op('ResultRow', BigInt.from(start),
      BigInt.from(indexes.length), BigInt.zero, null));
  final next = coder.main.length;
  coder.main
      .add(_Op('Next', BigInt.zero, BigInt.zero, BigInt.zero, null, p5: 1));
  final halt = coder.main.length + 1;
  coder.main[rewind] =
      _Op('Rewind', BigInt.zero, BigInt.from(halt), BigInt.zero, null);
  coder.main[next] = _Op(
      'Next', BigInt.zero, BigInt.from(rewind + 2), BigInt.zero, null,
      p5: 1);
  coder.once.add(_Op(
      'Transaction', BigInt.zero, BigInt.zero, BigInt.from(schema.cookie), '0',
      p5: 1));
  coder.flush();
  return _finish(coder);
}

QueryResult? _compileInsert(String sql, ExplainSchema schema) {
  final parser = SqlParser(sql);
  final replace = parser.take('REPLACE');
  if (!replace && !parser.take('INSERT')) return null;
  if (!replace && parser.take('OR')) return null;
  if (!parser.take('INTO')) return null;
  var name = parser.identifier();
  if (parser.take('.')) {
    if (asciiLower(name) != 'main') return null;
    name = parser.identifier();
  }
  if (parser.take('AS')) return null;
  final table = schema.table(name);
  if (table == null ||
      table.rootPage <= 0 ||
      table.withoutRowid ||
      table.rowidAlias != null ||
      table.generated ||
      table.affinity ||
      table.indexed ||
      table.notNull) {
    return null;
  }
  final listed = <String>[];
  if (parser.take('(')) {
    do {
      listed.add(parser.identifier());
    } while (parser.take(','));
    parser.require(')');
  }
  final defaults = parser.take('DEFAULT');
  final values = <Expr>[];
  if (defaults) {
    parser.require('VALUES');
  } else {
    parser.require('VALUES');
    parser.require('(');
    do {
      values.add(parser.expression());
    } while (parser.take(','));
    parser.require(')');
    if (parser.take(',')) return null;
  }
  if (parser.take('RETURNING') || parser.take('ON')) return null;
  parser.finish();
  final assigned = <int, Expr>{};
  if (defaults) {
    if (listed.isNotEmpty) return null;
  } else if (listed.isEmpty) {
    if (values.length != table.columns.length) return null;
    for (var i = 0; i < values.length; i++) {
      if (!_isConstant(values[i])) return null;
      assigned[i] = values[i];
    }
  } else {
    if (values.length != listed.length) return null;
    final seen = <int>{};
    for (var i = 0; i < listed.length; i++) {
      if (!_isConstant(values[i])) return null;
      final index = table.columns
          .indexWhere((column) => asciiLower(column) == asciiLower(listed[i]));
      if (index < 0 || !seen.add(index)) return null;
      assigned[index] = values[i];
    }
  }
  final width = table.columns.length;
  final coder = _Coder();
  coder.nMem = width + 1;
  final record = ++coder.nMem;
  coder.main.add(_Op('OpenWrite', BigInt.zero, BigInt.from(table.rootPage),
      BigInt.zero, '$width'));
  for (var i = 0; i < width; i++) {
    final value = assigned[i];
    if (value == null) {
      if (i < table.defaults.length && table.defaults[i]) return null;
      coder.queueTargeted(_null, i + 2);
    } else {
      coder.codeTarget(value, i + 2);
    }
  }
  coder.main.add(_Op('NewRowid', BigInt.zero, BigInt.one, BigInt.zero, null));
  coder.main.add(_Op(
      'MakeRecord', BigInt.two, BigInt.from(width), BigInt.from(record), null));
  coder.main.add(_Op(
      'Insert', BigInt.zero, BigInt.from(record), BigInt.one, table.name,
      p5: 57));
  coder.once.add(_Op(
      'Transaction', BigInt.zero, BigInt.one, BigInt.from(schema.cookie), '0',
      p5: 1));
  coder.flush();
  return _finish(coder);
}

QueryResult _finish(_Coder coder) {
  coder.main.add(_Op('Halt', BigInt.zero, BigInt.zero, BigInt.zero, null));
  final halt = coder.main.length;
  final jumpAt = coder.haltJump;
  if (jumpAt != null) {
    final jump = coder.main[jumpAt];
    coder.main[jumpAt] = _Op(
        jump.name, jump.p1, BigInt.from(halt), jump.p3, jump.p4,
        p5: jump.p5);
  }
  final ops = <_Op>[
    _Op('Init', BigInt.zero, BigInt.from(halt + 1), BigInt.zero, null),
    ...coder.main,
    ...coder.once,
    _Op('Goto', BigInt.zero, BigInt.one, BigInt.zero, null),
  ];
  return QueryResult(_columns, [
    for (var i = 0; i < ops.length; i++)
      _row(i, ops[i].name, ops[i].p1, ops[i].p2, ops[i].p3, ops[i].p4,
          p5: BigInt.from(ops[i].p5)),
  ]);
}

/// One opcode, or null when this expression is not a single literal opcode.
///
/// [opcode, p1, p2, p3, p4]. The register is [p2].
List<Object?>? _literalOpcode(Expr expression, int register) {
  final folded = _fold(expression);
  if (folded == null) return null;
  final value = folded.value;
  final dest = BigInt.from(register);
  if (value == null) {
    return ['Null', BigInt.zero, dest, BigInt.zero, null];
  }
  if (value is BigInt) {
    if (value < _minInt64 || value > _maxInt64) return null;
    if (folded.wideHex ||
        value < _minIntegerOpcode ||
        value > _maxIntegerOpcode) {
      return ['Int64', BigInt.zero, dest, BigInt.zero, value.toString()];
    }
    return ['Integer', value, dest, BigInt.zero, null];
  }
  if (value is double) {
    return ['Real', BigInt.zero, dest, BigInt.zero, sqliteRealText(value)];
  }
  if (value is String) {
    return ['String8', BigInt.zero, dest, BigInt.zero, value];
  }
  if (value is Uint8List) {
    return [
      'Blob',
      BigInt.from(value.length),
      dest,
      BigInt.zero,
      _blobText(value)
    ];
  }
  return null;
}

final class _Folded {
  _Folded(this.value, {this.wideHex = false});
  final Object? value;

  /// A hex literal whose unsigned magnitude does not fit in signed 32 bits.
  /// `0xffffffffffffffff` is the signed value -1 and still uses `Int64`.
  final bool wideHex;
}

_Folded? _fold(Expr expression) {
  var minuses = 0;
  var current = expression;
  while (current is UnaryExpr && (current.op == '+' || current.op == '-')) {
    if (current.op == '-') minuses++;
    current = current.operand;
  }
  if (minuses > 1) return null;
  if (current is BoolNameExpr) {
    if (minuses != 0) return null;
    return _Folded(current.expected ? BigInt.one : BigInt.zero);
  }
  if (current is! Literal) return null;
  final value = current.value;
  if (minuses == 0) {
    if (value is BigInt) {
      return _Folded(value,
          wideHex: current.hexadecimal && _unsigned(value) > _maxUint31);
    }
    if (value == null ||
        value is double ||
        value is String ||
        value is Uint8List) {
      return _Folded(value);
    }
    return null;
  }
  if (value is BigInt) {
    final negated = -value;
    if (negated < _minInt64 || negated > _maxInt64) {
      return _Folded(negated.toDouble());
    }
    return _Folded(negated);
  }
  if (value is double) return _Folded(-value);
  return null;
}

BigInt _unsigned(BigInt signed) =>
    signed >= BigInt.zero ? signed : signed + (BigInt.one << 64);

/// SQLite prints `OP_Blob` p4 as a C string, so a NUL ends the text.
String _blobText(Uint8List bytes) {
  final end = bytes.indexOf(0);
  final prefix = end < 0 ? bytes : Uint8List.sublistView(bytes, 0, end);
  try {
    return utf8.decode(prefix);
  } on FormatException {
    return String.fromCharCodes(prefix);
  }
}

/// Explain text for `OP_Real`, matching SQLite's `%.16g` shape.
///
/// Sixteen significant digits come from [double.toStringAsPrecision]. Trailing
/// zeros are removed. The exponent form is used when the exponent is below -4
/// or above 15, with a sign and at least two digits. `-0` is `0`.
String sqliteRealText(double value) {
  if (value.isNaN) return 'NaN';
  if (value == double.infinity) return 'Inf';
  if (value == double.negativeInfinity) return '-Inf';
  if (value == 0) return '0';
  final negative = value.isNegative;
  final parsed = _significand(value.abs());
  var digits = parsed.$1;
  final exponent = parsed.$2;
  while (digits.length > 1 && digits.endsWith('0')) {
    digits = digits.substring(0, digits.length - 1);
  }
  final body = exponent < -4 || exponent > 15
      ? _scientific(digits, exponent)
      : _fixed(digits, exponent);
  return negative ? '-$body' : body;
}

(String, int) _significand(double absolute) {
  final raw = absolute.toStringAsPrecision(16);
  final mark = raw.indexOf('e');
  if (mark >= 0) {
    return (
      raw.substring(0, mark).replaceAll('.', ''),
      int.parse(raw.substring(mark + 1))
    );
  }
  final dot = raw.indexOf('.');
  if (dot < 0) return (raw, raw.length - 1);
  final whole = raw.substring(0, dot);
  final fraction = raw.substring(dot + 1);
  if (whole == '0') {
    var zeros = 0;
    while (zeros < fraction.length && fraction[zeros] == '0') {
      zeros++;
    }
    final rest = fraction.substring(zeros);
    final digits = rest.length >= 16 ? rest.substring(0, 16) : rest;
    return (digits.isEmpty ? '0' : digits, -(zeros + 1));
  }
  final combined = whole + fraction;
  final digits = combined.length >= 16 ? combined.substring(0, 16) : combined;
  return (digits, whole.length - 1);
}

String _scientific(String digits, int exponent) {
  final tail = digits.substring(1);
  final mantissa = tail.isEmpty ? digits[0] : '${digits[0]}.$tail';
  final sign = exponent < 0 ? '-' : '+';
  final width = exponent.abs().toString().padLeft(2, '0');
  return '${mantissa}e$sign$width';
}

String _fixed(String digits, int exponent) {
  if (exponent >= 0) {
    final before = exponent + 1;
    if (digits.length <= before) {
      return digits + ('0' * (before - digits.length));
    }
    final head = digits.substring(0, before);
    final tail = digits.substring(before);
    return '$head.$tail';
  }
  return '0.${'0' * (-exponent - 1)}$digits';
}
