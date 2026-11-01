import 'dart:convert';
import 'dart:typed_data';

/// SQLite FTS5 porter stemmer (`fts5PorterCb` in the 3.53.1 amalgamation).
///
/// Tokens shorter than 3 bytes or longer than 64 bytes are returned unchanged.
String stemPorterToken(String token) {
  final original = utf8.encode(token);
  if (original.length < 3 || original.length > 64) return token;
  final buffer = Uint8List(original.length + 8);
  buffer.setRange(0, original.length, original);
  var n = original.length;
  n = _step1A(buffer, n);
  final step1 = _step1B(buffer, n);
  n = step1.$1;
  if (step1.$2) {
    final grown = _step1B2(buffer, n);
    n = grown.$1;
    if (!grown.$2 && n > 0) {
      final c = buffer[n - 1];
      if (!_isVowel(c, false) &&
          c != 0x6c &&
          c != 0x73 &&
          c != 0x7a &&
          n >= 2 &&
          c == buffer[n - 2]) {
        n--;
      } else if (_mEq1(buffer, n) && _oStar(buffer, n)) {
        buffer[n++] = 0x65;
      }
    }
  }
  if (n > 0 && buffer[n - 1] == 0x79 && _hasVowel(buffer, n - 1)) {
    buffer[n - 1] = 0x69;
  }
  n = _step2(buffer, n);
  n = _step3(buffer, n);
  n = _step4(buffer, n);
  if (n > 0 && buffer[n - 1] == 0x65) {
    if (_mGt1(buffer, n - 1) ||
        (_mEq1(buffer, n - 1) && !_oStar(buffer, n - 1))) {
      n--;
    }
  }
  if (n > 1 &&
      buffer[n - 1] == 0x6c &&
      buffer[n - 2] == 0x6c &&
      _mGt1(buffer, n - 1)) {
    n--;
  }
  return utf8.decode(buffer.sublist(0, n));
}

bool _isVowel(int c, bool yIsVowel) =>
    c == 0x61 ||
    c == 0x65 ||
    c == 0x69 ||
    c == 0x6f ||
    c == 0x75 ||
    (yIsVowel && c == 0x79);

int _gobbleVC(Uint8List z, int n, bool prevCons) {
  var cons = prevCons;
  var i = 0;
  for (; i < n; i++) {
    cons = !_isVowel(z[i], cons);
    if (!cons) break;
  }
  for (i++; i < n; i++) {
    cons = !_isVowel(z[i], cons);
    if (cons) return i + 1;
  }
  return 0;
}

bool _mGt0(Uint8List z, int n) => _gobbleVC(z, n, false) != 0;

bool _mGt1(Uint8List z, int n) {
  final first = _gobbleVC(z, n, false);
  return first != 0 && _gobbleVC(z.sublist(first), n - first, true) != 0;
}

bool _mEq1(Uint8List z, int n) {
  final first = _gobbleVC(z, n, false);
  return first != 0 && _gobbleVC(z.sublist(first), n - first, true) == 0;
}

bool _oStar(Uint8List z, int n) {
  if (n <= 0) return false;
  final last = z[n - 1];
  if (last == 0x77 || last == 0x78 || last == 0x79) return false;
  var mask = 0;
  var cons = false;
  for (var i = 0; i < n; i++) {
    cons = !_isVowel(z[i], cons);
    mask = (mask << 1) + (cons ? 1 : 0);
  }
  return (mask & 0x0007) == 0x0005;
}

bool _mGt1AndSOrT(Uint8List z, int n) {
  if (n <= 0) return false;
  final last = z[n - 1];
  return (last == 0x73 || last == 0x74) && _mGt1(z, n);
}

bool _hasVowel(Uint8List z, int n) {
  for (var i = 0; i < n; i++) {
    if (_isVowel(z[i], i > 0)) return true;
  }
  return false;
}

bool _suffix(Uint8List z, int n, String suffix) {
  final bytes = suffix.codeUnits;
  if (n < bytes.length) return false;
  final start = n - bytes.length;
  for (var i = 0; i < bytes.length; i++) {
    if (z[start + i] != bytes[i]) return false;
  }
  return true;
}

int _put(Uint8List z, int n, String suffix, String output) {
  final start = n - suffix.length;
  final bytes = output.codeUnits;
  for (var i = 0; i < bytes.length; i++) {
    z[start + i] = bytes[i];
  }
  return start + bytes.length;
}

int _step1A(Uint8List z, int n) {
  if (n < 2 || z[n - 1] != 0x73) return n;
  if (z[n - 2] == 0x65) {
    if ((n > 4 && z[n - 4] == 0x73 && z[n - 3] == 0x73) ||
        (n > 3 && z[n - 3] == 0x69)) {
      return n - 2;
    }
    return n - 1;
  }
  if (z[n - 2] != 0x73) return n - 1;
  return n;
}

(int, bool) _step1B(Uint8List z, int n) {
  if (n < 2) return (n, false);
  switch (z[n - 2]) {
    case 0x65:
      if (n > 3 && _suffix(z, n, 'eed') && _mGt0(z, n - 3)) {
        return (_put(z, n, 'eed', 'ee'), false);
      }
      if (n > 2 && _suffix(z, n, 'ed') && _hasVowel(z, n - 2)) {
        return (n - 2, true);
      }
    case 0x6e:
      if (n > 3 && _suffix(z, n, 'ing') && _hasVowel(z, n - 3)) {
        return (n - 3, true);
      }
  }
  return (n, false);
}

(int, bool) _step1B2(Uint8List z, int n) {
  if (n < 2) return (n, false);
  switch (z[n - 2]) {
    case 0x61:
      if (n > 2 && _suffix(z, n, 'at')) return (_put(z, n, 'at', 'ate'), true);
    case 0x62:
      if (n > 2 && _suffix(z, n, 'bl')) return (_put(z, n, 'bl', 'ble'), true);
    case 0x69:
      if (n > 2 && _suffix(z, n, 'iz')) return (_put(z, n, 'iz', 'ize'), true);
  }
  return (n, false);
}

int _step2(Uint8List z, int n) {
  if (n < 2) return n;
  switch (z[n - 2]) {
    case 0x61:
      if (n > 7 && _suffix(z, n, 'ational') && _mGt0(z, n - 7)) {
        return _put(z, n, 'ational', 'ate');
      }
      if (n > 6 && _suffix(z, n, 'tional') && _mGt0(z, n - 6)) {
        return _put(z, n, 'tional', 'tion');
      }
    case 0x63:
      if (n > 4 && _suffix(z, n, 'enci') && _mGt0(z, n - 4)) {
        return _put(z, n, 'enci', 'ence');
      }
      if (n > 4 && _suffix(z, n, 'anci') && _mGt0(z, n - 4)) {
        return _put(z, n, 'anci', 'ance');
      }
    case 0x65:
      if (n > 4 && _suffix(z, n, 'izer') && _mGt0(z, n - 4)) {
        return _put(z, n, 'izer', 'ize');
      }
    case 0x67:
      if (n > 4 && _suffix(z, n, 'logi') && _mGt0(z, n - 4)) {
        return _put(z, n, 'logi', 'log');
      }
    case 0x6c:
      if (n > 3 && _suffix(z, n, 'bli') && _mGt0(z, n - 3)) {
        return _put(z, n, 'bli', 'ble');
      }
      if (n > 4 && _suffix(z, n, 'alli') && _mGt0(z, n - 4)) {
        return _put(z, n, 'alli', 'al');
      }
      if (n > 5 && _suffix(z, n, 'entli') && _mGt0(z, n - 5)) {
        return _put(z, n, 'entli', 'ent');
      }
      if (n > 3 && _suffix(z, n, 'eli') && _mGt0(z, n - 3)) {
        return _put(z, n, 'eli', 'e');
      }
      if (n > 5 && _suffix(z, n, 'ousli') && _mGt0(z, n - 5)) {
        return _put(z, n, 'ousli', 'ous');
      }
    case 0x6f:
      if (n > 7 && _suffix(z, n, 'ization') && _mGt0(z, n - 7)) {
        return _put(z, n, 'ization', 'ize');
      }
      if (n > 5 && _suffix(z, n, 'ation') && _mGt0(z, n - 5)) {
        return _put(z, n, 'ation', 'ate');
      }
      if (n > 4 && _suffix(z, n, 'ator') && _mGt0(z, n - 4)) {
        return _put(z, n, 'ator', 'ate');
      }
    case 0x73:
      if (n > 5 && _suffix(z, n, 'alism') && _mGt0(z, n - 5)) {
        return _put(z, n, 'alism', 'al');
      }
      if (n > 7 && _suffix(z, n, 'iveness') && _mGt0(z, n - 7)) {
        return _put(z, n, 'iveness', 'ive');
      }
      if (n > 7 && _suffix(z, n, 'fulness') && _mGt0(z, n - 7)) {
        return _put(z, n, 'fulness', 'ful');
      }
      if (n > 7 && _suffix(z, n, 'ousness') && _mGt0(z, n - 7)) {
        return _put(z, n, 'ousness', 'ous');
      }
    case 0x74:
      if (n > 5 && _suffix(z, n, 'aliti') && _mGt0(z, n - 5)) {
        return _put(z, n, 'aliti', 'al');
      }
      if (n > 5 && _suffix(z, n, 'iviti') && _mGt0(z, n - 5)) {
        return _put(z, n, 'iviti', 'ive');
      }
      if (n > 6 && _suffix(z, n, 'biliti') && _mGt0(z, n - 6)) {
        return _put(z, n, 'biliti', 'ble');
      }
  }
  return n;
}

int _step3(Uint8List z, int n) {
  if (n < 2) return n;
  switch (z[n - 2]) {
    case 0x61:
      if (n > 4 && _suffix(z, n, 'ical') && _mGt0(z, n - 4)) {
        return _put(z, n, 'ical', 'ic');
      }
    case 0x73:
      if (n > 4 && _suffix(z, n, 'ness') && _mGt0(z, n - 4)) return n - 4;
    case 0x74:
      if (n > 5 && _suffix(z, n, 'icate') && _mGt0(z, n - 5)) {
        return _put(z, n, 'icate', 'ic');
      }
      if (n > 5 && _suffix(z, n, 'iciti') && _mGt0(z, n - 5)) {
        return _put(z, n, 'iciti', 'ic');
      }
    case 0x75:
      if (n > 3 && _suffix(z, n, 'ful') && _mGt0(z, n - 3)) return n - 3;
    case 0x76:
      if (n > 5 && _suffix(z, n, 'ative') && _mGt0(z, n - 5)) return n - 5;
    case 0x7a:
      if (n > 5 && _suffix(z, n, 'alize') && _mGt0(z, n - 5)) {
        return _put(z, n, 'alize', 'al');
      }
  }
  return n;
}

int _step4(Uint8List z, int n) {
  if (n < 2) return n;
  switch (z[n - 2]) {
    case 0x61:
      if (n > 2 && _suffix(z, n, 'al') && _mGt1(z, n - 2)) return n - 2;
    case 0x63:
      if (n > 4 && _suffix(z, n, 'ance') && _mGt1(z, n - 4)) return n - 4;
      if (n > 4 && _suffix(z, n, 'ence') && _mGt1(z, n - 4)) return n - 4;
    case 0x65:
      if (n > 2 && _suffix(z, n, 'er') && _mGt1(z, n - 2)) return n - 2;
    case 0x69:
      if (n > 2 && _suffix(z, n, 'ic') && _mGt1(z, n - 2)) return n - 2;
    case 0x6c:
      if (n > 4 && _suffix(z, n, 'able') && _mGt1(z, n - 4)) return n - 4;
      if (n > 4 && _suffix(z, n, 'ible') && _mGt1(z, n - 4)) return n - 4;
    case 0x6e:
      if (n > 3 && _suffix(z, n, 'ant') && _mGt1(z, n - 3)) return n - 3;
      if (n > 5 && _suffix(z, n, 'ement') && _mGt1(z, n - 5)) return n - 5;
      if (n > 4 && _suffix(z, n, 'ment') && _mGt1(z, n - 4)) return n - 4;
      if (n > 3 && _suffix(z, n, 'ent') && _mGt1(z, n - 3)) return n - 3;
    case 0x6f:
      if (n > 3 && _suffix(z, n, 'ion') && _mGt1AndSOrT(z, n - 3)) return n - 3;
      if (n > 2 && _suffix(z, n, 'ou') && _mGt1(z, n - 2)) return n - 2;
    case 0x73:
      if (n > 3 && _suffix(z, n, 'ism') && _mGt1(z, n - 3)) return n - 3;
    case 0x74:
      if (n > 3 && _suffix(z, n, 'ate') && _mGt1(z, n - 3)) return n - 3;
      if (n > 3 && _suffix(z, n, 'iti') && _mGt1(z, n - 3)) return n - 3;
    case 0x75:
      if (n > 3 && _suffix(z, n, 'ous') && _mGt1(z, n - 3)) return n - 3;
    case 0x76:
      if (n > 3 && _suffix(z, n, 'ive') && _mGt1(z, n - 3)) return n - 3;
    case 0x7a:
      if (n > 3 && _suffix(z, n, 'ize') && _mGt1(z, n - 3)) return n - 3;
  }
  return n;
}
