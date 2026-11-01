import 'dart:convert';
import 'dart:typed_data';

import 'database.dart';
import 'expressions.dart';
import 'parser.dart';
import 'tokenizer.dart';

const _columns = ['addr', 'opcode', 'p1', 'p2', 'p3', 'p4', 'p5', 'comment'];
final _minInt64 = -(BigInt.one << 63);
final _maxInt64 = (BigInt.one << 63) - BigInt.one;
final _minIntegerOpcode = BigInt.from(-2147483647);
final _maxIntegerOpcode = BigInt.from(2147483647);
final _maxUint31 = BigInt.from(2147483647);

/// Bytecode for a SELECT whose every result column is one literal opcode.
///
/// Anything else, including arithmetic, `WHERE`, a table, and DML, returns
/// null. The caller keeps the existing rejection. This is not a VDBE.
QueryResult? compileLiteralExplain(String sql) {
  final SelectStatement statement;
  try {
    statement = SqlParser(sql).select();
  } on SqlException {
    return null;
  }
  if (statement.parameterCount != 0 ||
      statement.sources.isNotEmpty ||
      statement.table != null ||
      statement.where != null ||
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
  final ops = <List<Object?>>[];
  for (var i = 0; i < statement.items.length; i++) {
    final expression = statement.items[i].expression;
    if (expression == null) return null;
    final op = _literalOpcode(expression, i + 1);
    if (op == null) return null;
    ops.add(op);
  }
  final halt = ops.length + 2;
  final goto = halt + 1;
  final rows = <List<Object?>>[
    _row(0, 'Init', BigInt.zero, BigInt.from(goto), BigInt.zero, null),
    for (var i = 0; i < ops.length; i++)
      _row(i + 1, ops[i][0] as String, ops[i][1] as BigInt, ops[i][2] as BigInt,
          ops[i][3] as BigInt, ops[i][4]),
    _row(ops.length + 1, 'ResultRow', BigInt.one, BigInt.from(ops.length),
        BigInt.zero, null),
    _row(halt, 'Halt', BigInt.zero, BigInt.zero, BigInt.zero, null),
    _row(goto, 'Goto', BigInt.zero, BigInt.one, BigInt.zero, null),
  ];
  return QueryResult(_columns, rows);
}

List<Object?> _row(
        int addr, String opcode, BigInt p1, BigInt p2, BigInt p3, Object? p4) =>
    [BigInt.from(addr), opcode, p1, p2, p3, p4, BigInt.zero, null];

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
