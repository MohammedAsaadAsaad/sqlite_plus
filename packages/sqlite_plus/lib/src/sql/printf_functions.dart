import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'core_functions.dart' show scalarInt64;
import 'tokenizer.dart';
import 'values.dart';

const _outputLimit = 16 * 1024 * 1024;

void _limit(int size) {
  if (size > _outputLimit) {
    throw const SqlException('Function output limit exceeded');
  }
}

/// The SQL FORMAT/PRINTF conversion rules, including SQLite's extra flags and
/// quote conversions. All conversion widths refer to UTF-8, even in UTF-16 DBs.
Object? sqlitePrintf(List<Object?> arguments, int encoding) {
  if (arguments.isEmpty || arguments.first == null) return null;
  final format = stringify(arguments.first!, encoding).split('\u0000').first;
  final output = <int>[];
  var appended = false;
  var used = 1;
  Object? next() => used < arguments.length ? arguments[used++] : null;
  String? text(Object? value) =>
      value == null ? null : stringify(value, encoding).split('\u0000').first;
  BigInt integer(Object? value) => scalarInt64(value, encoding);

  void append(List<int> bytes) {
    appended = true;
    _limit(output.length + bytes.length);
    output.addAll(bytes);
  }

  void appendText(String value) => append(utf8.encode(value));
  void spaces(int size) {
    if (size > 0) {
      _limit(output.length + size);
      output.addAll(List.filled(size, 32));
    }
  }

  int wrap32(BigInt value) => value.toSigned(32).toInt();
  int literalCount(String value) {
    var count = 0;
    for (final digit in value.codeUnits) {
      count = (count * 10 + digit - 48) & 0x7fffffff;
    }
    return count;
  }

  for (var offset = 0; offset < format.length;) {
    if (format.codeUnitAt(offset) != 37) {
      final end = format.indexOf('%', offset);
      appendText(format.substring(offset, end < 0 ? format.length : end));
      if (end < 0) break;
      offset = end;
    }
    offset++;
    if (offset == format.length) {
      appendText('%');
      break;
    }
    var left = false, alternate = false, chars = false, zero = false;
    var thousands = false;
    var prefix = '';
    while (offset < format.length) {
      final flag = format[offset];
      if (flag == '-') {
        left = true;
      } else if (flag == '+' || flag == ' ') {
        prefix = flag;
      } else if (flag == '#') {
        alternate = true;
      } else if (flag == '!') {
        chars = true;
      } else if (flag == '0') {
        zero = true;
      } else if (flag == ',') {
        thousands = true;
      } else {
        break;
      }
      offset++;
    }
    var width = 0;
    if (offset < format.length && format[offset] == '*') {
      width = wrap32(integer(next()));
      if (width < 0) {
        left = true;
        width = width == -2147483648 ? 0 : -width;
      }
      offset++;
    } else {
      final begin = offset;
      while (offset < format.length &&
          format.codeUnitAt(offset) >= 48 &&
          format.codeUnitAt(offset) <= 57) {
        offset++;
      }
      if (offset > begin) width = literalCount(format.substring(begin, offset));
    }
    var precision = -1;
    if (offset < format.length && format[offset] == '.') {
      offset++;
      if (offset < format.length && format[offset] == '*') {
        precision = wrap32(integer(next()));
        if (precision < 0) {
          precision = precision == -2147483648 ? -1 : -precision;
        }
        offset++;
      } else {
        final begin = offset;
        while (offset < format.length &&
            format.codeUnitAt(offset) >= 48 &&
            format.codeUnitAt(offset) <= 57) {
          offset++;
        }
        precision =
            offset == begin ? 0 : literalCount(format.substring(begin, offset));
      }
    }
    // Length modifiers have no effect for SQL values, which are always int64.
    if (offset < format.length && format[offset] == 'l') {
      offset++;
      if (offset < format.length && format[offset] == 'l') offset++;
    }
    if (offset == format.length) break;
    final type = format[offset++];
    if (!'diuoxXprfFeEgGszcqQw%n'.contains(type) || type == 'F') break;
    if (type == 'n') continue; // Does not consume an SQL argument.
    _limit(width);
    List<int> result;
    var characterWidth = chars;
    if ('diuoxXpr'.contains(type)) {
      final raw = integer(next());
      final signed = 'dir'.contains(type);
      var value = signed ? raw.abs() : raw.toUnsigned(64);
      final sign = signed ? (raw.isNegative ? '-' : prefix) : '';
      final radix = type == 'o'
          ? 8
          : 'xXp'.contains(type)
              ? 16
              : 10;
      var digits = value.toRadixString(radix);
      if (type == 'X' || type == 'p') digits = digits.toUpperCase();
      var suffix = '';
      if (type == 'r') {
        final last = (value % BigInt.from(10)).toInt();
        suffix = value ~/ BigInt.from(10) % BigInt.from(10) == BigInt.one
            ? 'th'
            : switch (last) { 1 => 'st', 2 => 'nd', 3 => 'rd', _ => 'th' };
      }
      var count = math.max(precision, zero ? width - sign.length : 0);
      count = math.max(count - suffix.length, digits.length);
      _limit(count + suffix.length + sign.length);
      digits = digits.padLeft(count, '0');
      if (thousands && 'diu'.contains(type)) {
        digits = _groupDigits(digits);
      }
      final radixPrefix = alternate && value != BigInt.zero
          ? switch (type) {
              'x' || 'p' => '0x',
              'X' => '0X',
              'o' => '0',
              _ => ''
            }
          : '';
      result = utf8.encode('$radixPrefix$sign$digits$suffix');
      characterWidth = false;
    } else if ('feEgG'.contains(type)) {
      final number = numeric(next(), prefix: true, encoding: encoding);
      final value =
          number is BigInt ? number.toDouble() : number as double? ?? 0;
      final rendered = _float(
          value, type, precision, alternate, chars, zero, thousands, prefix);
      var renderedWidth = rendered.length;
      var valueText = rendered;
      if (zero && !left && renderedWidth < width) {
        final sign = valueText.startsWith('-') ||
                valueText.startsWith('+') ||
                valueText.startsWith(' ')
            ? valueText[0]
            : '';
        valueText = sign +
            valueText.substring(sign.length).padLeft(width - sign.length, '0');
        renderedWidth = width;
      }
      result = utf8.encode(valueText);
      characterWidth = false;
    } else if (type == '%') {
      result = [37];
      characterWidth = false;
    } else if (type == 'c') {
      final value = text(next()) ?? '\u0000';
      final rune = value.isEmpty ? 0 : value.runes.first;
      final bytes = utf8.encode(String.fromCharCode(rune));
      final count = math.max(1, precision);
      _limit(count * bytes.length);
      result = [for (var i = 0; i < count; i++) ...bytes];
      characterWidth = true;
    } else {
      final value = text(next());
      final source = value ??
          ('qQw'.contains(type)
              ? type == 'Q'
                  ? 'NULL'
                  : '(NULL)'
              : '');
      List<int> bytes = utf8.encode(source);
      if (precision >= 0) {
        if (chars) {
          bytes =
              utf8.encode(String.fromCharCodes(source.runes.take(precision)));
        } else if (precision < bytes.length) {
          bytes = bytes.sublist(0, precision);
        }
      }
      if ('qQw'.contains(type)) {
        final quote = type == 'w' ? 34 : 39;
        final controls = bytes.any((c) => c <= 31);
        final escapes = alternate && type != 'w' && (type == 'q' || controls);
        final quoted = type == 'Q' && value != null;
        final wrapped = quoted && escapes;
        final escaped = <int>[];
        if (quoted) escaped.addAll(utf8.encode(wrapped ? "unistr('" : "'"));
        for (final byte in bytes) {
          if (byte == quote) {
            escaped.addAll([byte, byte]);
          } else if (escapes && byte == 92) {
            escaped.addAll([92, 92]);
          } else if (escapes && byte <= 31) {
            escaped.addAll(
                utf8.encode('\\u${byte.toRadixString(16).padLeft(4, '0')}'));
          } else {
            escaped.add(byte);
          }
          _limit(escaped.length);
        }
        if (quoted) escaped.addAll(utf8.encode(wrapped ? "')" : "'"));
        bytes = escaped;
      }
      result = bytes;
    }
    _limit(output.length + result.length);
    final length = characterWidth
        ? result.where((c) => c & 0xc0 != 0x80).length
        : result.length;
    if (!left) spaces(width - length);
    append(result);
    if (left) spaces(width - length);
  }
  if (!appended) return null;
  try {
    return utf8.decode(output);
  } on FormatException {
    throw const SqlException('Malformed UTF-8 function output');
  }
}

String _groupDigits(String digits) {
  final output = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i != 0 && (digits.length - i) % 3 == 0) output.write(',');
    output.write(digits[i]);
  }
  return output.toString();
}

String _float(double value, String type, int precision, bool alternate,
    bool chars, bool zero, bool thousands, String signFlag) {
  if (precision < 0) precision = 6;
  _limit(precision);
  if (value.isNaN) return zero ? 'null' : 'NaN';
  if (value.isInfinite && !zero) {
    return '${value.isNegative ? '-' : signFlag}Inf';
  }
  final generic = type == 'g' || type == 'G';
  var exponential = type == 'e' || type == 'E';
  if (generic && precision == 0) precision = 1;
  final rounding = generic
      ? precision
      : exponential
          ? precision + 1
          : -precision;
  final decoded = value.isInfinite
      ? ('9', 1000)
      : _decodeFloat(value.abs(), rounding, chars ? 20 : 16);
  final digits = decoded.$1;
  final point = decoded.$2;
  final exponent = point - 1;
  final trim = generic ? !alternate : chars;
  if (generic) {
    precision--;
    exponential = exponent < -4 || exponent > precision;
    if (!exponential) precision -= exponent;
  }
  _limit(math.max(point, 0) + precision + 10);
  var sign = value < 0 ? '-' : signFlag;
  if (value < 0 &&
      alternate &&
      signFlag.isEmpty &&
      type == 'f' &&
      point <= rounding) {
    sign = '';
  }
  String digitAt(int index) =>
      index >= 0 && index < digits.length ? digits[index] : '0';
  final output = StringBuffer(sign);
  if (exponential) {
    output.write(digits[0]);
  } else if (point <= 0) {
    output.write('0');
  } else {
    var whole = [for (var i = 0; i < point; i++) digitAt(i)].join();
    if (thousands) whole = _groupDigits(whole);
    output.write(whole);
  }
  if (precision > 0 || alternate || chars) output.write('.');
  final begin = exponential ? 1 : point;
  for (var i = 0; i < precision; i++) {
    output.write(digitAt(begin + i));
  }
  var result = output.toString();
  if (trim && result.contains('.')) {
    while (result.endsWith('0')) {
      result = result.substring(0, result.length - 1);
    }
    if (result.endsWith('.')) {
      result = chars ? '${result}0' : result.substring(0, result.length - 1);
    }
  }
  if (exponential) {
    result +=
        '${type == 'E' || type == 'G' ? 'E' : 'e'}${exponent < 0 ? '-' : '+'}${exponent.abs().toString().padLeft(2, '0')}';
  }
  return result;
}

/// Integer arithmetic mirrors SQLite 3.53's binary-to-decimal decode. Keeping
/// the intermediate 64-bit mantissa avoids platform-dependent libc rendering.
(String, int) _decodeFloat(double value, int rounding, int maxRound) {
  if (value == 0) return ('0', 1);
  final bits = ByteData(8)..setFloat64(0, value);
  final raw =
      (BigInt.from(bits.getUint32(0)) << 32) | BigInt.from(bits.getUint32(4));
  var exponent = ((raw >> 52) & BigInt.from(2047)).toInt();
  var mantissa = raw & ((BigInt.one << 52) - BigInt.one);
  if (exponent == 0) {
    final shift = 64 - mantissa.bitLength;
    mantissa <<= shift;
    exponent = -1074 - shift;
  } else {
    mantissa = (mantissa << 11) | (BigInt.one << 63);
    exponent -= 1086;
  }
  final count = rounding <= 0 || rounding >= 18 ? 18 : rounding + 1;
  final power = count - 1 - ((exponent + 63) * 78913 >> 18);
  final binaryPower = power * 108853 >> 15;
  final ten = BigInt.from(10).pow(power.abs());
  final scaleShift = 63 - binaryPower;
  final scale = power >= 0
      ? scaleShift >= 0
          ? ten << scaleShift
          : ten >> -scaleShift
      : scaleShift >= 0
          ? (BigInt.one << scaleShift) ~/ ten
          : BigInt.one ~/ (ten << -scaleShift);
  var high = mantissa * scale >> 64;
  BigInt decimal;
  if (count == 18) {
    high >>= -(exponent + binaryPower + 2);
    decimal = (high + ((high << 1) & BigInt.two)) >> 1;
  } else {
    decimal = high >> -(exponent + binaryPower + 1);
  }
  var digits = decimal.toString();
  var point = digits.length - power;
  if (rounding <= 0) {
    rounding = point - rounding;
    if (rounding == 0 && digits.codeUnitAt(0) >= 53) {
      rounding = 1;
      digits = '0$digits';
      point++;
    }
  }
  if (rounding > 0 && (rounding < digits.length || digits.length > maxRound)) {
    rounding = math.min(rounding, maxRound);
    // SQLite's 17-digit ! mode shortens long runs if they round-trip exactly.
    if (rounding == 17 && digits.length > 17) {
      var shorten = -1;
      if (digits[15] == '9' && digits[14] == '9') {
        var index = 14;
        while (index > 0 && digits[index - 1] == '9') {
          index--;
        }
        final candidate = index == 0
            ? BigInt.one
            : BigInt.parse(digits.substring(0, index)) + BigInt.one;
        if (double.parse('${candidate}e${point - index}') == value) {
          shorten = index + 1;
        }
      } else if (point >= digits.length || digits.substring(13, 16) == '000') {
        var index = 13;
        while (index > 1 && digits[index - 1] == '0') {
          index--;
        }
        if (double.parse('${digits.substring(0, index)}e${point - index}') ==
            value) {
          shorten = index + 1;
        }
      }
      if (shorten > 0) rounding = shorten;
    }
    if (rounding < digits.length) {
      final roundUp = digits.codeUnitAt(rounding) >= 53;
      var rounded = BigInt.parse(digits.substring(0, rounding));
      if (roundUp) rounded += BigInt.one;
      final newDigits = rounded.toString().padLeft(rounding, '0');
      point += newDigits.length - rounding;
      digits = newDigits;
    }
  }
  while (digits.length > 1 && digits.endsWith('0')) {
    digits = digits.substring(0, digits.length - 1);
  }
  return (digits, point);
}
