import 'dart:math' as math;
import 'dart:typed_data';
import 'values.dart';
import 'tokenizer.dart';

const extraFunctionArities = <String, (int, int)>{
  'random': (0, 0),
  'randomblob': (1, 1),
  'unistr': (1, 1),
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

// sqlite3_value_int64() parses text as an integer prefix. Parsing a numeric
// prefix first would incorrectly turn '2e2' into 200 and '.5' into a real.
BigInt scalarInt64(Object? value, int encoding) {
  if (value is BigInt) return value;
  if (value is double) return toSqlInteger(value);
  if (value == null) return BigInt.zero;
  final match = RegExp(r'^[\t\n\v\f\r ]*([+-]?[0-9]+)')
      .firstMatch(stringify(value, encoding));
  if (match == null) return BigInt.zero;
  final minimum = -(BigInt.one << 63);
  final maximum = (BigInt.one << 63) - BigInt.one;
  final literal = match[1]!;
  final negative = literal.startsWith('-');
  final digits = literal.replaceFirst(RegExp(r'^[+-]?0*'), '');
  if (digits.isEmpty) return BigInt.zero;
  if (digits.length > 19) return negative ? minimum : maximum;
  final magnitude = BigInt.parse(digits);
  final integer = negative ? -magnitude : magnitude;
  return integer < minimum
      ? minimum
      : integer > maximum
          ? maximum
          : integer;
}

final _random = math.Random.secure();

Uint8List _randomBytes(int count) {
  final bytes = Uint8List(count);
  final words = ByteData.sublistView(bytes);
  var i = 0;
  for (; i + 4 <= count; i += 4) {
    words.setUint32(i, _random.nextInt(0x100000000));
  }
  for (; i < count; i++) {
    bytes[i] = _random.nextInt(256);
  }
  return bytes;
}

String _unistr(String input) {
  final output = StringBuffer();
  for (var i = 0; i < input.length; i++) {
    if (output.length > 16 * 1024 * 1024) {
      throw const SqlException('Function output limit exceeded');
    }
    final unit = input.codeUnitAt(i);
    if (unit != 92) {
      output.writeCharCode(unit);
      continue;
    }
    if (++i >= input.length) {
      throw const SqlException('invalid Unicode escape');
    }
    final prefix = input.codeUnitAt(i);
    if (prefix == 92) {
      output.writeCharCode(92);
      continue;
    }
    final digits = prefix == 85
        ? 8
        : prefix == 43
            ? 6
            : 4;
    if ([85, 117, 43].contains(prefix)) i++;
    if (i + digits > input.length) {
      throw const SqlException('invalid Unicode escape');
    }
    final hex = input.substring(i, i + digits);
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
      throw const SqlException('invalid Unicode escape');
    }
    final codepoint = int.parse(hex, radix: 16);
    // Native SQLite can produce malformed UTF-8 here. Like the record decoder,
    // the Pure Dart engine rejects malformed Unicode rather than retaining it.
    if (codepoint > 0x10ffff || codepoint >= 0xd800 && codepoint <= 0xdfff) {
      throw const SqlException('Malformed Unicode escape');
    }
    output.writeCharCode(codepoint);
    i += digits - 1;
  }
  if (output.length > 16 * 1024 * 1024) {
    throw const SqlException('Function output limit exceeded');
  }
  return output.toString();
}

Object? extraFunction(String key, List<Object?> args, int encoding) {
  String text(Object? value) => value == null ? '' : stringify(value, encoding);
  void limit(int length) {
    if (length > 16 * 1024 * 1024) {
      throw const SqlException('Function output limit exceeded');
    }
  }

  if (key == 'random') {
    final bytes = _randomBytes(8);
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    // SQLite intentionally excludes -9223372036854775808 so ABS(random()) is
    // always representable. Preserve its sign/magnitude mapping of 64 bits.
    final magnitude = value & ((BigInt.one << 63) - BigInt.one);
    return bytes.first >= 128 ? -magnitude : magnitude;
  }
  if (key == 'randomblob') {
    final requested = scalarInt64(args.single, encoding);
    if (requested > BigInt.from(16 * 1024 * 1024)) {
      throw const SqlException('randomblob limit exceeded');
    }
    return _randomBytes(requested < BigInt.one ? 1 : requested.toInt());
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
  if (key == 'unistr') return _unistr(text(args.single));
  if (key == 'round') {
    final raw =
        numeric(args.first, prefix: true, encoding: encoding) ?? BigInt.zero;
    final x = raw is BigInt ? raw.toDouble() : raw as double;
    final count =
        args.length == 1 ? BigInt.zero : scalarInt64(args[1], encoding);
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
