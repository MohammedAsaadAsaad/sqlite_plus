import 'dart:convert';

/// Decimal and uint text order from the pinned SQLite shell.
///
/// The shell registers these as UTF-8 collations and has no ICU library.
/// Strings longer than 10,000,000 decimal digits compare equal to every
/// value, matching `decimalCollFunc` when `decimalNewFromText` fails.
const decimalDigitLimit = 10000000;

int compareDecimal(String a, String b) {
  final left = _parseDecimal(utf8.encode(a));
  final right = _parseDecimal(utf8.encode(b));
  if (left == null || right == null) return 0;
  return _compareDecimal(left, right);
}

int compareUint(String a, String b) =>
    _compareUint(utf8.encode(a), utf8.encode(b));

/// Equality key for a UNIQUE index. Not a sort key.
String decimalEqualityKey(String text) {
  final parsed = _parseDecimal(utf8.encode(text));
  if (parsed == null) return '\u0000overflow:$text';
  _stripTrailingFractionZeros(parsed);
  return '${parsed.sign}:${parsed.nFrac}:${parsed.digits.join(',')}';
}

/// Equality key for a UNIQUE index. Not a sort key.
String uintEqualityKey(String text) {
  final bytes = utf8.encode(text);
  final out = <int>[];
  var i = 0;
  while (i < bytes.length) {
    if (_digit(bytes[i])) {
      while (i < bytes.length && bytes[i] == 0x30) {
        i++;
      }
      final start = i;
      while (i < bytes.length && _digit(bytes[i])) {
        i++;
      }
      if (start == i) {
        out.add(0x30);
      } else {
        out.addAll(bytes.sublist(start, i));
      }
    } else {
      out.add(bytes[i]);
      i++;
    }
  }
  return String.fromCharCodes(out);
}

final class _Decimal {
  int sign = 0;
  int nFrac = 0;
  final List<int> digits = [];
  int get nDigit => digits.length;
}

bool _space(int byte) =>
    byte == 32 ||
    byte == 9 ||
    byte == 10 ||
    byte == 11 ||
    byte == 12 ||
    byte == 13;

bool _digit(int byte) => byte >= 0x30 && byte <= 0x39;

_Decimal? _parseDecimal(List<int> bytes) {
  final parsed = _Decimal();
  final n = bytes.length;
  var i = 0;
  var exponent = 0;
  while (i < n && _space(bytes[i])) {
    i++;
  }
  if (i < n && bytes[i] == 0x2d) {
    parsed.sign = 1;
    i++;
  } else if (i < n && bytes[i] == 0x2b) {
    i++;
  }
  while (i < n && bytes[i] == 0x30) {
    i++;
  }
  var fractionMark = 0;
  while (i < n) {
    final c = bytes[i];
    if (_digit(c)) {
      if (parsed.nDigit >= decimalDigitLimit) return null;
      parsed.digits.add(c - 0x30);
    } else if (c == 0x2e) {
      fractionMark = parsed.nDigit + 1;
    } else if (c == 0x65 || c == 0x45) {
      var j = i + 1;
      var negative = false;
      if (j >= n) break;
      if (bytes[j] == 0x2d) {
        negative = true;
        j++;
      } else if (bytes[j] == 0x2b) {
        j++;
      }
      while (j < n && exponent < 1000000) {
        if (_digit(bytes[j])) {
          exponent = exponent * 10 + bytes[j] - 0x30;
        }
        j++;
      }
      if (negative) exponent = -exponent;
      break;
    }
    i++;
  }
  if (fractionMark != 0) {
    parsed.nFrac = parsed.nDigit - (fractionMark - 1);
  }
  if (exponent > 0) {
    if (parsed.nFrac > 0) {
      if (exponent <= parsed.nFrac) {
        parsed.nFrac -= exponent;
        exponent = 0;
      } else {
        exponent -= parsed.nFrac;
        parsed.nFrac = 0;
      }
    }
    if (exponent > 0) {
      if (parsed.nDigit + exponent > decimalDigitLimit) return null;
      for (var extra = 0; extra < exponent; extra++) {
        parsed.digits.add(0);
      }
    }
  } else if (exponent < 0) {
    exponent = -exponent;
    final extraDigits = parsed.nDigit - parsed.nFrac - 1;
    if (extraDigits != 0) {
      if (extraDigits >= exponent) {
        parsed.nFrac += exponent;
        exponent = 0;
      } else {
        exponent -= extraDigits;
        parsed.nFrac = parsed.nDigit - 1;
      }
    }
    if (exponent > 0) {
      if (parsed.nDigit + exponent > decimalDigitLimit) return null;
      parsed.digits.insertAll(0, List.filled(exponent, 0));
      parsed.nFrac += exponent;
    }
  }
  if (parsed.sign != 0) {
    var zero = 0;
    while (zero < parsed.nDigit && parsed.digits[zero] == 0) {
      zero++;
    }
    if (zero >= parsed.nDigit) parsed.sign = 0;
  }
  if (parsed.nDigit > decimalDigitLimit) return null;
  return parsed;
}

void _stripTrailingFractionZeros(_Decimal value) {
  while (value.nFrac > 0 && value.digits.last == 0) {
    value.digits.removeLast();
    value.nFrac--;
  }
}

int _compareDecimal(_Decimal a, _Decimal b) {
  _stripTrailingFractionZeros(a);
  _stripTrailingFractionZeros(b);
  if (a.sign != b.sign) return a.sign != 0 ? -1 : 1;
  if (a.sign != 0) {
    final swapped = a;
    a = b;
    b = swapped;
  }
  final aSignificant = a.nDigit - a.nFrac;
  final bSignificant = b.nDigit - b.nFrac;
  if (aSignificant != bSignificant) return aSignificant - bSignificant;
  final n = a.nDigit < b.nDigit ? a.nDigit : b.nDigit;
  for (var i = 0; i < n; i++) {
    final difference = a.digits[i] - b.digits[i];
    if (difference != 0) return difference;
  }
  return a.nDigit - b.nDigit;
}

int _compareUint(List<int> left, List<int> right) {
  var i = 0, j = 0;
  while (i < left.length && j < right.length) {
    final difference = left[i] - right[j];
    if (_digit(left[i])) {
      if (!_digit(right[j])) return difference;
      while (i < left.length && left[i] == 0x30) {
        i++;
      }
      while (j < right.length && right[j] == 0x30) {
        j++;
      }
      var k = 0;
      while (i + k < left.length &&
          _digit(left[i + k]) &&
          j + k < right.length &&
          _digit(right[j + k])) {
        k++;
      }
      if (i + k < left.length && _digit(left[i + k])) return 1;
      if (j + k < right.length && _digit(right[j + k])) return -1;
      for (var t = 0; t < k; t++) {
        final digit = left[i + t] - right[j + t];
        if (digit != 0) return digit;
      }
      i += k;
      j += k;
    } else if (difference != 0) {
      return difference;
    } else {
      i++;
      j++;
    }
  }
  return (left.length - i) - (right.length - j);
}
