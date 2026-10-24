import 'dart:convert';
import 'dart:typed_data';

import 'tokenizer.dart';

String asciiLower(String value) => String.fromCharCodes(
    value.codeUnits.map((c) => c >= 65 && c <= 90 ? c + 32 : c));
final _minInt = -(BigInt.one << 63);
final _maxInt = (BigInt.one << 63) - BigInt.one;
Object narrowInteger(BigInt value) =>
    value < _minInt || value > _maxInt ? value.toDouble() : value;
Object? sqlValue(Object? value) {
  if (value is Uint8List) return Uint8List.fromList(value);
  if (value is BigInt && (value < _minInt || value > _maxInt)) {
    throw const SqlException('Integer binding outside signed 64-bit range');
  }
  if (value == null ||
      value is BigInt ||
      value is String ||
      value is Uint8List) {
    return value;
  }
  if (value is int) return BigInt.from(value);
  if (value is double) return value.isNaN ? null : value;
  throw const SqlException('Unsupported bound value');
}

Object? numeric(Object? value, {bool prefix = false, int encoding = 1}) {
  if (value is BigInt || value is double) return value;
  if (value is Uint8List) value = decodeSqlText(value, encoding);
  if (value is! String) return null;
  final text = value.trim();
  final match = RegExp(prefix
          ? r'^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?'
          : r'^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$')
      .firstMatch(text);
  if (match == null) return null;
  final literal = match[0]!;
  if (!literal.contains(RegExp('[.eE]'))) {
    final integer = BigInt.parse(literal);
    return narrowInteger(integer);
  }
  return double.tryParse(literal);
}

bool? truth(Object? value, [int encoding = 1]) {
  if (value == null) return null;
  final number = numeric(value, prefix: true, encoding: encoding);
  return number is BigInt
      ? number != BigInt.zero
      : number is double && number != 0;
}

BigInt boolean(bool value) => value ? BigInt.one : BigInt.zero;
String stringify(Object value, [int encoding = 1]) {
  if (value is Uint8List) return decodeSqlText(value, encoding);
  if (value is double) return sqlRealText(value);
  return value.toString();
}

String sqlRealText(double value, [int precision = 15]) {
  if (value == 0) return '0.0';
  if (!value.isFinite) return value.isNegative ? '-Inf' : 'Inf';
  final parts = value.toStringAsExponential(precision - 1).split('e');
  final exponent = int.parse(parts[1]);
  String trim(String s) {
    if (!s.contains('.')) return '$s.0';
    while (s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    return s.endsWith('.') ? '${s}0' : s;
  }

  if (exponent >= -4 && exponent < precision) {
    return trim(value.toStringAsFixed(precision - 1 - exponent));
  }
  return '${trim(parts[0])}e${exponent < 0 ? '-' : '+'}${exponent.abs().toString().padLeft(2, '0')}';
}

int compareValues(Object? a, Object? b, [int encoding = 1]) {
  if (a == null) return b == null ? 0 : -1;
  if (b == null) return 1;
  int rank(Object value) => value is BigInt || value is double
      ? 0
      : value is String
          ? 1
          : 2;
  final order = rank(a).compareTo(rank(b));
  if (order != 0) return order;
  if (a is BigInt && b is BigInt) return a.compareTo(b);
  int mixed(BigInt integer, double real) {
    if (!real.isFinite) return real.isNegative ? 1 : -1;
    final truncated = BigInt.from(real);
    final result = integer.compareTo(truncated);
    if (result != 0) return result;
    return real == real.truncateToDouble()
        ? 0
        : real > 0
            ? -1
            : 1;
  }

  if (a is BigInt && b is double) return mixed(a, b);
  if (a is double && b is BigInt) return -mixed(b, a);
  if (a is double && b is double) return a == b ? 0 : a.compareTo(b);
  final List<int> aa =
      a is String ? encodeSqlText(a, encoding) : a as Uint8List;
  final List<int> bb =
      b is String ? encodeSqlText(b, encoding) : b as Uint8List;
  for (var i = 0; i < aa.length && i < bb.length; i++) {
    if (aa[i] != bb[i]) return aa[i].compareTo(bb[i]);
  }
  return aa.length.compareTo(bb.length);
}

String affinityFor(String declared) {
  final type = declared.toUpperCase();
  if (type.contains('INT')) return 'numeric';
  if (['CHAR', 'CLOB', 'TEXT'].any(type.contains)) return 'text';
  if (type.isEmpty || type.contains('BLOB')) return 'none';
  return 'numeric';
}

Object? applyAffinity(Object? value, String affinity) {
  if (affinity == 'numeric' && value is String) return numeric(value) ?? value;
  if (affinity == 'text' && (value is BigInt || value is double)) {
    return stringify(value!);
  }
  return value;
}

String decodeSqlText(Uint8List bytes, int encoding) {
  if (encoding == 1) return utf8.decode(bytes, allowMalformed: true);
  final data = ByteData.sublistView(bytes);
  return String.fromCharCodes([
    for (var i = 0; i + 1 < bytes.length; i += 2)
      data.getUint16(i, encoding == 2 ? Endian.little : Endian.big)
  ]);
}

List<int> encodeSqlText(String text, int encoding) {
  if (encoding == 1) return utf8.encode(text);
  final bytes = Uint8List(text.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < text.length; i++) {
    data.setUint16(
        i * 2, text.codeUnitAt(i), encoding == 2 ? Endian.little : Endian.big);
  }
  return bytes;
}

BigInt toSqlInteger(Object number) {
  if (number is BigInt) return number;
  final real = number as double;
  if (real >= _maxInt.toDouble()) return _maxInt;
  if (real <= _minInt.toDouble()) return _minInt;
  return BigInt.from(real);
}
