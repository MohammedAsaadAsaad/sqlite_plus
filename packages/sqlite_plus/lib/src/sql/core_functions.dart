import 'dart:math' as math;
import 'dart:typed_data';
import 'values.dart';
import 'tokenizer.dart';

const extraFunctionArities = <String, (int, int)>{
  'round': (1, 2),
  'instr': (2, 2),
  'octet_length': (1, 1),
  'concat': (1, 1000),
  'concat_ws': (2, 1000),
  'unhex': (1, 2),
  'sign': (1, 1),
  'acos': (1, 1),
  'acosh': (1, 1),
  'asin': (1, 1),
  'asinh': (1, 1),
  'atan': (1, 1),
  'atan2': (2, 2),
  'atanh': (1, 1),
  'ceil': (1, 1),
  'ceiling': (1, 1),
  'cos': (1, 1),
  'cosh': (1, 1),
  'degrees': (1, 1),
  'exp': (1, 1),
  'floor': (1, 1),
  'ln': (1, 1),
  'log': (1, 2),
  'log10': (1, 1),
  'log2': (1, 1),
  'mod': (2, 2),
  'pi': (0, 0),
  'pow': (2, 2),
  'power': (2, 2),
  'radians': (1, 1),
  'sin': (1, 1),
  'sinh': (1, 1),
  'sqrt': (1, 1),
  'tan': (1, 1),
  'tanh': (1, 1),
  'trunc': (1, 1),
};

Object? extraFunction(String key, List<Object?> args, int encoding) {
  String text(Object? value) => value == null ? '' : stringify(value, encoding);
  void limit(int length) {
    if (length > 16 * 1024 * 1024) {
      throw const SqlException('Function output limit exceeded');
    }
  }

  if (key == 'concat' || key == 'concat_ws') {
    if (key == 'concat_ws' && args.first == null) return null;
    final separator = key == 'concat_ws' ? text(args.first) : '';
    final pieces = (key == 'concat_ws' ? args.skip(1) : args)
        .where((v) => v != null)
        .map(text)
        .toList();
    limit(pieces.fold<int>(0, (sum, s) => sum + s.length) +
        math.max(0, pieces.length - 1) * separator.length);
    return pieces.join(separator);
  }
  if (args.any((v) => v == null)) return null;
  if (key == 'round') {
    final raw =
        numeric(args.first, prefix: true, encoding: encoding) ?? BigInt.zero;
    final x = raw is BigInt ? raw.toDouble() : raw as double;
    final count = args.length == 1
        ? BigInt.zero
        : toSqlInteger(
            numeric(args[1], prefix: true, encoding: encoding) ?? BigInt.zero);
    final precision = count < BigInt.zero
        ? 0
        : count > BigInt.from(30)
            ? 30
            : count.toInt();
    if (!x.isFinite || x.abs() > 4503599627370496) return x;
    if (precision == 0) {
      return x < 0
          ? -(-x + 0.5).truncateToDouble()
          : (x + 0.5).truncateToDouble();
    }
    final bytes = ByteData(8)..setFloat64(0, x.abs());
    final bits = (BigInt.from(bytes.getUint32(0)) << 32) |
        BigInt.from(bytes.getUint32(4));
    final exponent = ((bits >> 52) & BigInt.from(2047)).toInt();
    final mantissa = (bits & ((BigInt.one << 52) - BigInt.one)) +
        (exponent == 0 ? BigInt.zero : BigInt.one << 52);
    final shift = exponent == 0 ? -1074 : exponent - 1075;
    var numerator = mantissa * BigInt.from(10).pow(precision);
    var denominator = BigInt.one;
    if (shift >= 0) {
      numerator <<= shift;
    } else {
      denominator <<= -shift;
    }
    final rounded =
        (numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two);
    final digits = rounded.toString().padLeft(precision + 1, '0');
    return double.parse(
        '${x < 0 ? '-' : ''}${digits.substring(0, digits.length - precision)}.${digits.substring(digits.length - precision)}');
  }
  if (key == 'octet_length') {
    final value = args.single;
    return BigInt.from(value is Uint8List
        ? value.length
        : encodeSqlText(text(value), encoding).length);
  }
  if (key == 'unhex') {
    final ignore = args.length == 2 ? text(args[1]).runes.toSet() : <int>{};
    final hex = <int>[];
    for (final c in text(args[0]).runes) {
      if (c >= 48 && c <= 57) {
        hex.add(c - 48);
      } else if (c >= 65 && c <= 70) {
        hex.add(c - 55);
      } else if (c >= 97 && c <= 102) {
        hex.add(c - 87);
      } else if (!ignore.contains(c)) {
        return null;
      }
    }
    if (hex.length.isOdd) return null;
    limit(hex.length ~/ 2);
    return Uint8List.fromList(
        [for (var i = 0; i < hex.length; i += 2) hex[i] * 16 + hex[i + 1]]);
  }
  if (key == 'instr') {
    final a = args[0], b = args[1];
    final left =
        a is Uint8List && b is Uint8List ? a.toList() : text(a).runes.toList();
    final right =
        a is Uint8List && b is Uint8List ? b.toList() : text(b).runes.toList();
    outer:
    for (var i = 0; i <= left.length - right.length; i++) {
      for (var j = 0; j < right.length; j++) {
        if (left[i + j] != right[j]) continue outer;
      }
      return BigInt.from(i + 1);
    }
    return BigInt.zero;
  }
  if (key == 'pi') return math.pi;
  // SQLite's math and SIGN functions require complete numeric input and reject
  // blobs; unlike arithmetic coercion they do not accept a numeric prefix.
  if (args.any((v) => v is Uint8List)) return null;
  final numbers = args.map((v) => numeric(v, encoding: encoding)).toList();
  if (numbers.any((v) => v == null)) return null;
  final value = numbers.first!;
  final x = value is BigInt ? value.toDouble() : value as double;
  if (key == 'sign') {
    return BigInt.from(x == 0
        ? 0
        : x < 0
            ? -1
            : 1);
  }
  if (['ceil', 'ceiling', 'floor', 'trunc'].contains(key)) {
    if (value is BigInt) return value;
    if (!x.isFinite) return x;
    return key == 'floor'
        ? x.floorToDouble()
        : key == 'trunc'
            ? x.truncateToDouble()
            : x.ceilToDouble();
  }
  final y = numbers.length == 2
      ? (numbers[1] is BigInt
          ? (numbers[1] as BigInt).toDouble()
          : numbers[1] as double)
      : 0.0;
  final result = switch (key) {
    'acos' => math.acos(x),
    'asin' => math.asin(x),
    'atan' => math.atan(x),
    'atan2' => math.atan2(x, y),
    'acosh' => x < 1 ? double.nan : math.log(x + math.sqrt(x * x - 1)),
    'asinh' => x < 0
        ? -math.log(-x + math.sqrt(x * x + 1))
        : math.log(x + math.sqrt(x * x + 1)),
    'atanh' => x.abs() >= 1 ? double.nan : math.log((1 + x) / (1 - x)) / 2,
    'cos' => math.cos(x),
    'sin' => math.sin(x),
    'tan' => math.tan(x),
    'cosh' => (math.exp(x) + math.exp(-x)) / 2,
    'sinh' => (math.exp(x) - math.exp(-x)) / 2,
    'tanh' => x > 20
        ? 1.0
        : x < -20
            ? -1.0
            : (math.exp(2 * x) - 1) / (math.exp(2 * x) + 1),
    'degrees' => x * 180 / math.pi,
    'radians' => x * math.pi / 180,
    'exp' => math.exp(x),
    'ln' => x <= 0 ? double.nan : math.log(x),
    'log10' => x <= 0 ? double.nan : math.log(x) / math.ln10,
    'log2' => x <= 0 ? double.nan : math.log(x) / math.ln2,
    'log' => numbers.length == 1
        ? (x <= 0 ? double.nan : math.log(x) / math.ln10)
        : (x <= 0 || x == 1 || y <= 0 ? double.nan : math.log(y) / math.log(x)),
    'mod' => y == 0 ? double.nan : x.remainder(y),
    'pow' || 'power' => math.pow(x, y).toDouble(),
    'sqrt' => math.sqrt(x),
    _ => throw SqlException('Unsupported function $key'),
  };
  return result.isNaN ? null : result;
}
