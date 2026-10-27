import 'dart:convert';
import 'dart:typed_data';

import 'tokenizer.dart';
import 'values.dart';

/// JSON text larger than the SQL tokenizer cap is rejected. SQLite's own
/// `SQLITE_MAX_LENGTH` default is 1 GB; this engine keeps one limit.
const jsonMaxInput = 1024 * 1024;
const jsonMaxDepth = 1000;
final _jsonMinInt = -(BigInt.one << 63);
final _jsonMaxInt = (BigInt.one << 63) - BigInt.one;

const jsonFunctionArities = <String, (int, int)>{
  'json': (1, 1),
  'jsonb': (1, 1),
  'json_array': (0, 1000),
  'jsonb_array': (0, 1000),
  'json_array_length': (1, 2),
  'json_error_position': (1, 1),
  'json_extract': (0, 1000),
  'jsonb_extract': (0, 1000),
  'json_insert': (0, 1000),
  'jsonb_insert': (0, 1000),
  'json_object': (0, 1000),
  'jsonb_object': (0, 1000),
  'json_patch': (2, 2),
  'jsonb_patch': (2, 2),
  'json_quote': (1, 1),
  'json_remove': (0, 1000),
  'jsonb_remove': (0, 1000),
  'json_replace': (0, 1000),
  'jsonb_replace': (0, 1000),
  'json_set': (0, 1000),
  'jsonb_set': (0, 1000),
  'json_type': (1, 2),
  'json_valid': (1, 2),
  'json_group_array': (1, 1),
  'jsonb_group_array': (1, 1),
  'json_group_object': (2, 2),
  'jsonb_group_object': (2, 2),
};

const _jsonAggregates = {
  'json_group_array',
  'jsonb_group_array',
  'json_group_object',
  'jsonb_group_object',
};

bool isJsonFunction(String name) => jsonFunctionArities.containsKey(name);
bool isJsonAggregate(String name) => _jsonAggregates.contains(name);

sealed class JNode {}

final class JNull extends JNode {}

final class JBool extends JNode {
  JBool(this.value);
  final bool value;
}

final class JNum extends JNode {
  JNum(this.spelling);
  final String spelling;
  bool get real {
    for (final unit in spelling.codeUnits) {
      if (unit == 46 || unit == 101 || unit == 69) return true;
    }
    return false;
  }
}

final class JStr extends JNode {
  JStr(this.decoded, this.raw);
  final String decoded;
  final String raw;
}

final class JArr extends JNode {
  JArr(this.items);
  final List<JNode> items;
}

final class JField {
  JField(this.key, this.value);
  final JStr key;
  final JNode value;
}

final class JObj extends JNode {
  JObj(this.fields);
  final List<JField> fields;
}

final class _JsonError implements Exception {
  const _JsonError([this.index = 0]);
  final int index;
}

Object? evaluateJsonFunction(String name, List<Object?> args, int encoding) {
  try {
    return _dispatchJson(name, args, encoding);
  } on _JsonError {
    throw const SqlException('malformed JSON');
  }
}

Object? _dispatchJson(String name, List<Object?> args, int encoding) {
  final blob = name.startsWith('jsonb');
  switch (name) {
    case 'json':
    case 'jsonb':
      return _publishDocument(args[0], encoding, blob: blob);
    case 'json_valid':
      return _jsonValid(args, encoding);
    case 'json_type':
      return _jsonType(args, encoding);
    case 'json_error_position':
      return _errorPosition(args[0], encoding);
    case 'json_extract':
    case 'jsonb_extract':
      return _extract(args, encoding, blob: blob);
    case 'json_quote':
      return _quote(args[0], encoding);
    case 'json_array':
    case 'jsonb_array':
      return _publishNode(
          JArr([for (final arg in args) _sqlJson(arg, encoding)]), blob);
    case 'json_array_length':
      return _arrayLength(args, encoding);
    case 'json_object':
    case 'jsonb_object':
      return _object(args, encoding, blob);
    case 'json_insert':
    case 'jsonb_insert':
      return _edit(args, encoding, _Edit.insert, blob);
    case 'json_replace':
    case 'jsonb_replace':
      return _edit(args, encoding, _Edit.replace, blob);
    case 'json_set':
    case 'jsonb_set':
      return _edit(args, encoding, _Edit.set, blob);
    case 'json_remove':
    case 'jsonb_remove':
      return _remove(args, encoding, blob);
    case 'json_patch':
    case 'jsonb_patch':
      return _patch(args, encoding, blob);
    default:
      throw SqlException('No such function: $name');
  }
}

Object? finishJsonAggregate(
    String name, List<List<Object?>> rows, int encoding) {
  try {
    return _finishJsonAggregate(name, rows, encoding);
  } on _JsonError {
    throw const SqlException('malformed JSON');
  }
}

Object? _finishJsonAggregate(
    String name, List<List<Object?>> rows, int encoding) {
  final blob = name.startsWith('jsonb');
  if (name.endsWith('group_array')) {
    return _publishNode(
        JArr([for (final row in rows) _sqlJson(row[0], encoding)]), blob);
  }
  final fields = <JField>[];
  for (final row in rows) {
    // SQLite skips a NULL label. An empty string is a real key.
    if (row[0] == null) continue;
    final label = _groupLabel(row[0], encoding);
    fields.add(
        JField(JStr(label, escapeJson(label)), _sqlJson(row[1], encoding)));
  }
  return _publishNode(JObj(fields), blob);
}

Object? jsonArrow(Object? left, Object? right,
    {required bool asSql, required int encoding}) {
  try {
    return _jsonArrow(left, right, asSql: asSql, encoding: encoding);
  } on _JsonError {
    throw const SqlException('malformed JSON');
  }
}

Object? _jsonArrow(Object? left, Object? right,
    {required bool asSql, required int encoding}) {
  if (left == null) return null;
  final document = _readDocument(left, encoding);
  if (right == null) return null;
  final path = _pathText(right, encoding);
  final expanded = _abbreviatedPath(right, path);
  final located = _lookup(document, expanded, _Edit.none, JNull());
  if (located.pathError) _badPath(path);
  if (located.missing || located.node == null) return null;
  return asSql ? _sqlOf(located.node!) : JsonText(_render(located.node!));
}

List<List<Object?>> jsonTableRows(Object? json,
    {Object? root, required bool hasRoot, required bool tree}) {
  try {
    return _jsonTableRows(json, root: root, hasRoot: hasRoot, tree: tree);
  } on _JsonError {
    throw const SqlException('malformed JSON');
  }
}

List<List<Object?>> _jsonTableRows(Object? json,
    {Object? root, required bool hasRoot, required bool tree}) {
  if (json == null || hasRoot && root == null) return const [];
  final document = _readDocument(json, 1);
  final path = !hasRoot
      ? '\$'
      : root is String
          ? root
          : root is JsonText
              ? root.text
              : stringify(root!);
  if (!path.startsWith('\$')) _badPath(path);
  final found = _locate(document, path);
  if (found == null) return const [];
  final rows = <List<Object?>>[];
  if (tree || found.node is! JArr && found.node is! JObj) {
    _emit(found.node, found.rowId, found.valueOffset, null, found.fullkey,
        tree ? found.parentPath : found.fullkey, tree ? found.key : null, rows,
        recurse: tree);
  } else {
    _emitChildren(found.node, found.valueOffset, null, found.fullkey, rows,
        recurse: false);
  }
  for (final row in rows) {
    row.add(publishSqlValue(json));
    row.add(hasRoot ? root : null);
  }
  return rows;
}

enum _Edit { none, insert, replace, set, delete }

final class _Hit {
  const _Hit({this.node, this.pathError = false, this.missing = false});
  final JNode? node;
  final bool pathError;
  final bool missing;
}

Object? _publishDocument(Object? value, int encoding, {required bool blob}) {
  if (value == null) return null;
  return _publishNode(_readDocument(value, encoding), blob);
}

Object? _publishNode(JNode node, bool blob) {
  if (blob) return _encode(node);
  final text = _render(node);
  if (text.length > FunctionOutputLimit.json) {
    throw const SqlException('Function output limit exceeded');
  }
  return JsonText(text);
}

abstract final class FunctionOutputLimit {
  static const json = 16 * 1024 * 1024;
}

JNode _readDocument(Object? value, int encoding) {
  if (value is JsonText) return _parse(value.text).node;
  if (value == null) return JNull();
  if (value is Uint8List) {
    if (_mightBeBinary(value)) return _decode(value);
    return _parse(_bytesText(value, encoding)).node;
  }
  if (value is String) return _parse(value).node;
  if (value is BigInt || value is int) {
    return JNum(
        (value is int ? BigInt.from(value) : value as BigInt).toString());
  }
  // json()/jsonb() render SQL reals with SQLite's %!.17g value text.
  if (value is double) {
    if (value.isNaN) return JNull();
    if (!value.isFinite) return JNum(value.isNegative ? '-9e999' : '9e999');
    return JNum(_jsonDocumentReal(value));
  }
  throw const SqlException('malformed JSON');
}

JNode _sqlJson(Object? value, int encoding) {
  if (value is JsonText) return _parse(value.text).node;
  if (value == null) return JNull();
  if (value is Uint8List) {
    if (_mightBeBinary(value)) return _decode(value);
    throw const SqlException('JSON cannot hold BLOB values');
  }
  if (value is String) return JStr(value, escapeJson(value));
  if (value is BigInt || value is int) {
    return JNum(
        (value is int ? BigInt.from(value) : value as BigInt).toString());
  }
  if (value is double) return _numberFromDouble(value);
  throw const SqlException('JSON cannot hold BLOB values');
}

JNode _numberFromDouble(double value) {
  if (value.isNaN) return JNull();
  if (!value.isFinite) return JNum(value.isNegative ? '-9e999' : '9e999');
  return JNum(sqlRealText(value));
}

/// SQL real text used by `json()`/`jsonb()`. SQLite stringifies the value with
/// `%!.17g` (17 significant digits, fixed when the exponent is in `-4..16`).
/// `json_quote`, `json_array`, and `json_object` keep the 15-digit form.
String _jsonDocumentReal(double value) {
  if (value == 0) return '0.0';
  if (value.isNaN) return 'null';
  if (!value.isFinite) return value.isNegative ? '-9e999' : '9e999';
  final exponent =
      int.parse(value.abs().toStringAsExponential(16).split('e')[1]);
  final scientific = exponent < -4 || exponent > 16;
  for (var precision = 1; precision <= 17; precision++) {
    final text = sqlRealText(value, precision);
    final isScientific = text.contains('e') || text.contains('E');
    if (isScientific != scientific) continue;
    if (double.parse(text) != value) continue;
    return text;
  }
  return sqlRealText(value, 17);
}

String _groupLabel(Object? value, int encoding) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is JsonText) return value.text;
  if (value is Uint8List) return _bytesText(value, encoding);
  return stringify(value, encoding);
}

String _bytesText(Uint8List bytes, int encoding) =>
    decodeSqlText(bytes, encoding);

String escapeJson(String text) {
  final buffer = StringBuffer();
  for (final unit in text.codeUnits) {
    switch (unit) {
      case 0x22:
        buffer.write(r'\"');
      case 0x5c:
        buffer.write(r'\\');
      case 0x08:
        buffer.write(r'\b');
      case 0x09:
        buffer.write(r'\t');
      case 0x0a:
        buffer.write(r'\n');
      case 0x0c:
        buffer.write(r'\f');
      case 0x0d:
        buffer.write(r'\r');
      default:
        if (unit < 0x20) {
          buffer
            ..write(r'\u00')
            ..write(unit.toRadixString(16).padLeft(2, '0'));
        } else {
          buffer.writeCharCode(unit);
        }
    }
  }
  return buffer.toString();
}

String _render(JNode node) {
  final buffer = StringBuffer();
  _writeText(node, buffer);
  return buffer.toString();
}

void _writeText(JNode node, StringBuffer buffer) {
  switch (node) {
    case JNull():
      buffer.write('null');
    case JBool(:final value):
      buffer.write(value ? 'true' : 'false');
    case JNum(:final spelling):
      buffer.write(spelling);
    case JStr(:final raw):
      buffer
        ..write('"')
        ..write(raw)
        ..write('"');
    case JArr(:final items):
      buffer.write('[');
      for (var i = 0; i < items.length; i++) {
        if (i > 0) buffer.write(',');
        _writeText(items[i], buffer);
      }
      buffer.write(']');
    case JObj(:final fields):
      buffer.write('{');
      for (var i = 0; i < fields.length; i++) {
        if (i > 0) buffer.write(',');
        buffer
          ..write('"')
          ..write(fields[i].key.raw)
          ..write('":');
        _writeText(fields[i].value, buffer);
      }
      buffer.write('}');
  }
}

Object? _sqlOf(JNode node) {
  switch (node) {
    case JNull():
      return null;
    case JBool(:final value):
      return value ? BigInt.one : BigInt.zero;
    case JNum(:final spelling):
      return _sqlNumber(spelling);
    case JStr(:final decoded):
      return decoded;
    case JArr() || JObj():
      return _render(node);
  }
}

Object _sqlNumber(String spelling) {
  if (!_isRealSpelling(spelling)) {
    final integer = BigInt.tryParse(spelling);
    if (integer != null && integer >= _jsonMinInt && integer <= _jsonMaxInt) {
      return integer;
    }
  }
  return double.parse(spelling);
}

bool _isRealSpelling(String spelling) {
  for (final unit in spelling.codeUnits) {
    if (unit == 46 || unit == 101 || unit == 69) return true;
  }
  return false;
}

final class _Parsed {
  _Parsed(this.node, this.nonstandard);
  final JNode node;
  final bool nonstandard;
}

_Parsed _parse(String text) {
  if (text.length > jsonMaxInput) {
    throw const SqlException('JSON input exceeds 1 MiB limit');
  }
  if (text.contains('\u0000')) throw const _JsonError();
  final parser = _Parser(text);
  try {
    parser.skip();
    if (parser.i >= text.length) throw _JsonError(parser.i);
    final node = parser.value();
    parser.skip();
    if (parser.i != text.length) throw _JsonError(parser.i);
    return _Parsed(node, parser.nonstandard);
  } on _JsonError {
    rethrow;
  }
}

final class _Parser {
  _Parser(this.text);
  final String text;
  var i = 0;
  var depth = 0;
  var nonstandard = false;

  int get _unit => i < text.length ? text.codeUnitAt(i) : -1;

  Never _fail() => throw _JsonError(i);

  void skip() {
    while (i < text.length) {
      final unit = text.codeUnitAt(i);
      if (unit == 0x20 || unit == 0x09 || unit == 0x0a || unit == 0x0d) {
        i++;
        continue;
      }
      if (unit == 0x2f && i + 1 < text.length) {
        final next = text.codeUnitAt(i + 1);
        if (next == 0x2f) {
          nonstandard = true;
          i += 2;
          while (i < text.length && text.codeUnitAt(i) != 0x0a) {
            i++;
          }
          continue;
        }
        if (next == 0x2a) {
          nonstandard = true;
          i += 2;
          while (i + 1 < text.length &&
              !(text.codeUnitAt(i) == 0x2a && text.codeUnitAt(i + 1) == 0x2f)) {
            i++;
          }
          if (i + 1 >= text.length) _fail();
          i += 2;
          continue;
        }
      }
      break;
    }
  }

  JNode value() {
    skip();
    final unit = _unit;
    if (unit < 0) _fail();
    if (unit == 0x6e) return _literal('null', JNull());
    if (unit == 0x74) return _literal('true', JBool(true));
    if (unit == 0x66) return _literal('false', JBool(false));
    if (unit == 0x22 || unit == 0x27) return _string(unit);
    if (unit == 0x5b) return _array();
    if (unit == 0x7b) return _object();
    if (unit == 0x2d ||
        unit == 0x2b ||
        unit == 0x2e ||
        unit >= 0x30 && unit <= 0x39) {
      return _number();
    }
    if (unit == 0x49 || unit == 0x69) return _infinity(false);
    _fail();
  }

  JNode _literal(String word, JNode node) {
    if (!text.startsWith(word, i)) _fail();
    final end = i + word.length;
    if (end < text.length && _identifier(text.codeUnitAt(end))) _fail();
    i = end;
    return node;
  }

  JNode _array() {
    if (++depth > jsonMaxDepth) _fail();
    i++;
    final items = <JNode>[];
    skip();
    if (_unit == 0x5d) {
      i++;
      depth--;
      return JArr(items);
    }
    while (true) {
      items.add(value());
      skip();
      if (_unit == 0x2c) {
        i++;
        skip();
        if (_unit == 0x5d) {
          nonstandard = true;
          i++;
          break;
        }
        continue;
      }
      if (_unit == 0x5d) {
        i++;
        break;
      }
      _fail();
    }
    depth--;
    return JArr(items);
  }

  JNode _object() {
    if (++depth > jsonMaxDepth) _fail();
    i++;
    final fields = <JField>[];
    skip();
    if (_unit == 0x7d) {
      i++;
      depth--;
      return JObj(fields);
    }
    while (true) {
      skip();
      final key = _key();
      skip();
      if (_unit != 0x3a) _fail();
      i++;
      fields.add(JField(key, value()));
      skip();
      if (_unit == 0x2c) {
        i++;
        skip();
        if (_unit == 0x7d) {
          nonstandard = true;
          i++;
          break;
        }
        continue;
      }
      if (_unit == 0x7d) {
        i++;
        break;
      }
      _fail();
    }
    depth--;
    return JObj(fields);
  }

  JStr _key() {
    final unit = _unit;
    if (unit == 0x22 || unit == 0x27) return _string(unit) as JStr;
    nonstandard = true;
    final start = i;
    while (i < text.length) {
      final current = text.codeUnitAt(i);
      if (current <= 0x20 ||
          current == 0x3a ||
          current == 0x2c ||
          current == 0x7b ||
          current == 0x7d ||
          current == 0x5b ||
          current == 0x5d ||
          current == 0x2f) {
        break;
      }
      i++;
    }
    if (i == start) _fail();
    final raw = text.substring(start, i);
    return JStr(raw, escapeJson(raw));
  }

  JNode _string(int quote) {
    if (quote == 0x27) nonstandard = true;
    i++;
    final raw = StringBuffer();
    final decoded = StringBuffer();
    var standard = quote == 0x22;
    while (i < text.length) {
      final unit = text.codeUnitAt(i);
      if (unit == quote) {
        i++;
        final interior =
            standard ? raw.toString() : escapeJson(decoded.toString());
        return JStr(decoded.toString(), interior);
      }
      if (unit == 0x5c) {
        final escape = _escape(raw, decoded);
        if (!escape) standard = false;
        continue;
      }
      if (unit < 0x20) _fail();
      raw.writeCharCode(unit);
      decoded.writeCharCode(unit);
      i++;
    }
    _fail();
  }

  bool _escape(StringBuffer raw, StringBuffer decoded) {
    if (i + 1 >= text.length) _fail();
    final mark = i;
    final unit = text.codeUnitAt(i + 1);
    i += 2;
    switch (unit) {
      case 0x22:
      case 0x5c:
      case 0x2f:
        raw.write(text.substring(mark, i));
        decoded.writeCharCode(unit);
        return true;
      case 0x62:
        raw.write(text.substring(mark, i));
        decoded.writeCharCode(0x08);
        return true;
      case 0x66:
        raw.write(text.substring(mark, i));
        decoded.writeCharCode(0x0c);
        return true;
      case 0x6e:
        raw.write(text.substring(mark, i));
        decoded.writeCharCode(0x0a);
        return true;
      case 0x72:
        raw.write(text.substring(mark, i));
        decoded.writeCharCode(0x0d);
        return true;
      case 0x74:
        raw.write(text.substring(mark, i));
        decoded.writeCharCode(0x09);
        return true;
      case 0x75:
        final point = _hex(4);
        if (point == null) _fail();
        i += 4;
        raw.write(text.substring(mark, i));
        decoded.writeCharCode(point);
        return true;
      case 0x27:
      case 0x30:
        decoded.writeCharCode(unit == 0x30 ? 0 : 0x27);
        nonstandard = true;
        return false;
      case 0x76:
        decoded.writeCharCode(0x0b);
        nonstandard = true;
        return false;
      case 0x0a:
        nonstandard = true;
        return false;
      case 0x0d:
        if (_unit == 0x0a) i++;
        nonstandard = true;
        return false;
      case 0x78:
        final byte = _hex(2);
        if (byte == null) _fail();
        i += 2;
        decoded.writeCharCode(byte);
        nonstandard = true;
        return false;
      default:
        _fail();
    }
  }

  int? _hex(int count) {
    if (i + count > text.length) return null;
    var value = 0;
    for (var n = 0; n < count; n++) {
      final unit = text.codeUnitAt(i + n);
      final digit = unit >= 48 && unit <= 57
          ? unit - 48
          : unit >= 65 && unit <= 70
              ? unit - 55
              : unit >= 97 && unit <= 102
                  ? unit - 87
                  : -1;
      if (digit < 0) return null;
      value = value * 16 + digit;
    }
    return value;
  }

  JNode _number() {
    final start = i;
    if (_unit == 0x2b) {
      nonstandard = true;
      i++;
    } else if (_unit == 0x2d) {
      i++;
    }
    if (_unit == 0x49 || _unit == 0x69) {
      return _infinity(text.codeUnitAt(start) == 0x2d);
    }
    if (_unit == 0x2e) {
      nonstandard = true;
      return JNum(_finishNumber(start, leadingDot: true));
    }
    if (_unit == 0x30 &&
        i + 1 < text.length &&
        (text.codeUnitAt(i + 1) == 0x78 || text.codeUnitAt(i + 1) == 0x58)) {
      nonstandard = true;
      i += 2;
      final hexStart = i;
      while (i < text.length && _hexDigit(text.codeUnitAt(i))) {
        i++;
      }
      if (i == hexStart) _fail();
      final negative = text.codeUnitAt(start) == 0x2d;
      final magnitude = BigInt.parse(text.substring(hexStart, i), radix: 16);
      return JNum('${negative ? '-' : ''}$magnitude');
    }
    if (_unit < 0x30 || _unit > 0x39) _fail();
    if (_unit == 0x30) {
      i++;
      if (_unit >= 0x30 && _unit <= 0x39) _fail();
    } else {
      while (_unit >= 0x30 && _unit <= 0x39) {
        i++;
      }
    }
    return JNum(_finishNumber(start, leadingDot: false));
  }

  String _finishNumber(int start, {required bool leadingDot}) {
    var dotted = leadingDot;
    if (leadingDot) {
      if (_unit != 0x2e) _fail();
      i++;
      final before = i;
      while (_unit >= 0x30 && _unit <= 0x39) {
        i++;
      }
      if (i == before) _fail();
    } else if (_unit == 0x2e) {
      final next = i + 1 < text.length ? text.codeUnitAt(i + 1) : -1;
      if (next < 0x30 || next > 0x39) {
        nonstandard = true;
        i++;
        dotted = true;
      } else {
        i++;
        dotted = true;
        while (_unit >= 0x30 && _unit <= 0x39) {
          i++;
        }
      }
    }
    if (_unit == 0x65 || _unit == 0x45) {
      i++;
      if (_unit == 0x2b || _unit == 0x2d) i++;
      final digits = i;
      while (_unit >= 0x30 && _unit <= 0x39) {
        i++;
      }
      if (i == digits) _fail();
    }
    var spelling = text.substring(start, i);
    if (spelling.startsWith('+')) {
      spelling = spelling.substring(1);
    }
    if (leadingDot) spelling = '0$spelling';
    if (dotted && !spelling.contains('e') && !spelling.contains('E')) {
      final dot = spelling.indexOf('.');
      if (dot == spelling.length - 1) spelling = '${spelling}0';
    }
    return spelling;
  }

  JNode _infinity(bool negative) {
    final word = i + 8 <= text.length ? text.substring(i, i + 8) : '';
    if (word.toLowerCase() == 'infinity') {
      i += 8;
    } else if (i + 3 <= text.length &&
        text.substring(i, i + 3).toLowerCase() == 'inf') {
      i += 3;
    } else {
      _fail();
    }
    nonstandard = true;
    return JNum(negative ? '-9e999' : '9e999');
  }

  bool _identifier(int unit) =>
      unit >= 48 && unit <= 57 ||
      unit >= 65 && unit <= 90 ||
      unit >= 97 && unit <= 122 ||
      unit == 95;

  bool _hexDigit(int unit) =>
      unit >= 48 && unit <= 57 ||
      unit >= 65 && unit <= 70 ||
      unit >= 97 && unit <= 102;
}

Object? _jsonValid(List<Object?> args, int encoding) {
  var flags = 1;
  if (args.length == 2) {
    final flag = _flag(args[1], encoding);
    if (flag < 1 || flag > 15) {
      throw const SqlException(
          'FLAGS parameter to json_valid() must be between 1 and 15');
    }
    flags = flag;
  }
  final value = args[0];
  if (value == null) return null;
  if (value is Uint8List && _mightBeBinary(value)) {
    if (flags & 0x04 != 0) return BigInt.one;
    if (flags & 0x08 != 0) {
      return _strictJsonb(value) ? BigInt.one : BigInt.zero;
    }
    return BigInt.zero;
  }
  if (flags & 0x03 == 0) return BigInt.zero;
  final text = value is String
      ? value
      : value is JsonText
          ? value.text
          : value is Uint8List
              ? _bytesText(value, encoding)
              : stringify(value, encoding);
  try {
    final parsed = _parse(text);
    if (flags & 0x02 != 0 || !parsed.nonstandard) return BigInt.one;
    return BigInt.zero;
  } on _JsonError {
    return BigInt.zero;
  } on SqlException {
    return BigInt.zero;
  }
}

int _flag(Object? value, int encoding) {
  if (value is BigInt) return value.toInt();
  if (value is int) return value;
  if (value is double) return value.isFinite ? value.truncate() : 0;
  if (value is String || value is JsonText || value is Uint8List) {
    final number = numeric(value, prefix: true, encoding: encoding);
    if (number is BigInt) return number.toInt();
    if (number is double && number.isFinite) return number.truncate();
  }
  return 0;
}

Object? _jsonType(List<Object?> args, int encoding) {
  if (args[0] == null) return null;
  final node = _atPath(args, encoding);
  if (node == null) return null;
  return _typeName(node);
}

String _typeName(JNode node) {
  switch (node) {
    case JNull():
      return 'null';
    case JBool(:final value):
      return value ? 'true' : 'false';
    case JNum():
      return node.real ? 'real' : 'integer';
    case JStr():
      return 'text';
    case JArr():
      return 'array';
    case JObj():
      return 'object';
  }
}

Object? _errorPosition(Object? value, int encoding) {
  if (value == null) return null;
  if (value is Uint8List && _mightBeBinary(value)) {
    return _strictJsonb(value) ? BigInt.zero : BigInt.one;
  }
  final text = value is String
      ? value
      : value is JsonText
          ? value.text
          : value is Uint8List
              ? _bytesText(value, encoding)
              : stringify(value, encoding);
  try {
    _parse(text);
    return BigInt.zero;
  } on _JsonError catch (error) {
    return BigInt.from(error.index + 1);
  } on SqlException {
    return BigInt.from(text.length + 1);
  }
}

Object? _extract(List<Object?> args, int encoding, {required bool blob}) {
  if (args.length < 2) return null;
  if (args[0] == null) return null;
  final document = _readDocument(args[0], encoding);
  if (args.length == 2) {
    if (args[1] == null) return null;
    final path = _pathText(args[1], encoding);
    final hit = _lookup(document, path, _Edit.none, JNull());
    if (hit.pathError) _badPath(path);
    if (hit.missing || hit.node == null) return null;
    if (blob && (hit.node is JArr || hit.node is JObj)) {
      return _encode(hit.node!);
    }
    if (blob) return _sqlOf(hit.node!);
    if (hit.node is JArr || hit.node is JObj) {
      return JsonText(_render(hit.node!));
    }
    return _sqlOf(hit.node!);
  }
  final items = <JNode>[];
  for (final arg in args.skip(1)) {
    if (arg == null) return null;
    final path = _pathText(arg, encoding);
    final hit = _lookup(document, path, _Edit.none, JNull());
    if (hit.pathError) _badPath(path);
    items.add(hit.missing || hit.node == null ? JNull() : hit.node!);
  }
  return _publishNode(JArr(items), blob);
}

Object? _quote(Object? value, int encoding) {
  if (value == null) return const JsonText('null');
  return _publishNode(_sqlJson(value, encoding), false);
}

Object? _arrayLength(List<Object?> args, int encoding) {
  if (args[0] == null) return null;
  final node = args.length == 1
      ? _readDocument(args[0], encoding)
      : _atPath(args, encoding);
  if (node == null) return null;
  return node is JArr ? BigInt.from(node.items.length) : BigInt.zero;
}

JNode? _atPath(List<Object?> args, int encoding) {
  final document = _readDocument(args[0], encoding);
  if (args.length == 1 || args[1] == null) {
    return args.length == 1 ? document : null;
  }
  final path = _pathText(args[1], encoding);
  final hit = _lookup(document, path, _Edit.none, JNull());
  if (hit.pathError) _badPath(path);
  if (hit.missing) return null;
  return hit.node;
}

Object? _object(List<Object?> args, int encoding, bool blob) {
  if (args.length.isOdd) {
    throw const SqlException(
        'json_object() requires an even number of arguments');
  }
  final fields = <JField>[];
  for (var i = 0; i < args.length; i += 2) {
    final label = args[i];
    if (label is! String && label is! JsonText) {
      throw const SqlException('json_object() labels must be TEXT');
    }
    final text = label is String ? label : (label as JsonText).text;
    fields.add(
        JField(JStr(text, escapeJson(text)), _sqlJson(args[i + 1], encoding)));
  }
  return _publishNode(JObj(fields), blob);
}

Object? _edit(List<Object?> args, int encoding, _Edit mode, bool blob) {
  if (args.isEmpty) return null;
  if (args.length.isEven) {
    final name = switch (mode) {
      _Edit.set => 'set',
      _Edit.insert => 'insert',
      _ => 'replace',
    };
    throw SqlException('json_$name() needs an odd number of arguments');
  }
  if (args[0] == null) return null;
  var node = _readDocument(args[0], encoding);
  for (var i = 1; i < args.length; i += 2) {
    if (args[i] == null) continue;
    final path = _pathText(args[i], encoding);
    final value = _sqlJson(args[i + 1], encoding);
    final hit = _lookup(node, path, mode, value);
    if (hit.pathError) _badPath(path);
    if (hit.node != null) node = hit.node!;
  }
  return _publishNode(node, blob);
}

Object? _remove(List<Object?> args, int encoding, bool blob) {
  if (args.isEmpty) return null;
  if (args[0] == null) return null;
  var node = _readDocument(args[0], encoding);
  for (final arg in args.skip(1)) {
    if (arg == null) return null;
    final path = _pathText(arg, encoding);
    if (path == '\$') return null;
    final hit = _lookup(node, path, _Edit.delete, JNull());
    if (hit.pathError) _badPath(path);
    if (!hit.missing && hit.node == null) return null;
    if (hit.node != null) node = hit.node!;
  }
  return _publishNode(node, blob);
}

Object? _patch(List<Object?> args, int encoding, bool blob) {
  if (args[0] == null || args[1] == null) return null;
  final target = _readDocument(args[0], encoding);
  final patch = _readDocument(args[1], encoding);
  return _publishNode(_merge(target, patch), blob);
}

JNode _merge(JNode target, JNode patch) {
  if (patch is! JObj) return patch;
  final object = target is JObj ? target : JObj([]);
  for (final field in patch.fields) {
    final index = _fieldIndex(object, field.key.decoded);
    if (field.value is JNull) {
      if (index >= 0) object.fields.removeAt(index);
      continue;
    }
    if (index >= 0) {
      object.fields[index] = JField(object.fields[index].key,
          _merge(object.fields[index].value, field.value));
    } else if (field.value is JObj) {
      object.fields.add(JField(field.key, _merge(JObj([]), field.value)));
    } else {
      object.fields.add(field);
    }
  }
  return object;
}

String _pathText(Object? value, int encoding) {
  if (value is String) return value;
  if (value is JsonText) return value.text;
  if (value is Uint8List) return _bytesText(value, encoding);
  return stringify(value!, encoding);
}

String _abbreviatedPath(Object? value, String path) {
  // An integer path is an array index. Text that merely looks numeric is a label.
  if (value is int || value is BigInt) {
    return path.startsWith('-') ? '\$[#$path]' : '\$[$path]';
  }
  if (path.startsWith('\$')) return path;
  if (_allLabel(path)) return '\$.$path';
  if (path.startsWith('[') && path.endsWith(']') && path.length >= 3) {
    return '\$$path';
  }
  return '\$."$path"';
}

bool _allLabel(String text) => text.codeUnits.every((unit) =>
    unit >= 48 && unit <= 57 ||
    unit >= 65 && unit <= 90 ||
    unit >= 97 && unit <= 122 ||
    unit == 95);

Never _badPath(String path) =>
    throw SqlException("bad JSON path: '${path.replaceAll("'", "''")}'");

_Hit _lookup(JNode root, String path, _Edit edit, JNode inserted) {
  if (!path.startsWith('\$')) return const _Hit(pathError: true);
  final rest = path.substring(1);
  if (rest.isEmpty) {
    switch (edit) {
      case _Edit.none:
        return _Hit(node: root);
      case _Edit.delete:
        return const _Hit();
      case _Edit.insert:
        return _Hit(node: root);
      case _Edit.replace:
      case _Edit.set:
        return _Hit(node: inserted);
    }
  }
  final walked = _walk(root, rest, edit, inserted);
  if (walked.pathError) return const _Hit(pathError: true);
  if (walked.missing) return const _Hit(missing: true);
  return _Hit(node: walked.replaced ?? root);
}

final class _Walk {
  const _Walk(
      {this.replaced,
      this.pathError = false,
      this.missing = false,
      this.removed = false});
  final JNode? replaced;
  final bool pathError;
  final bool missing;
  final bool removed;
}

_Walk _walk(JNode node, String path, _Edit edit, JNode inserted) {
  if (path.isEmpty) {
    switch (edit) {
      case _Edit.delete:
        return const _Walk(removed: true);
      case _Edit.insert:
        return const _Walk();
      case _Edit.none:
        return _Walk(replaced: node);
      case _Edit.replace:
      case _Edit.set:
        return _Walk(replaced: inserted);
    }
  }
  if (path.startsWith('.')) {
    final key = _takeKey(path);
    if (key.error) return const _Walk(pathError: true);
    if (node is! JObj) return const _Walk(missing: true);
    final index = _fieldIndex(node, key.decoded);
    if (index >= 0) {
      final child = _walk(node.fields[index].value, key.rest, edit, inserted);
      if (child.pathError || child.missing) return child;
      if (edit == _Edit.none) return child;
      if (child.removed) {
        node.fields.removeAt(index);
        return const _Walk();
      }
      if (child.replaced != null) {
        node.fields[index] = JField(node.fields[index].key, child.replaced!);
      }
      return const _Walk();
    }
    if (edit == _Edit.insert || edit == _Edit.set) {
      final created = _substructure(key.rest, inserted);
      if (created.pathError) return created;
      node.fields.add(JField(
          JStr(key.decoded, escapeJson(key.decoded)), created.replaced!));
      return const _Walk();
    }
    return const _Walk(missing: true);
  }
  if (path.startsWith('[')) {
    if (node is! JArr) return const _Walk(missing: true);
    final index = _takeIndex(path, node.items.length);
    if (index.error) return const _Walk(pathError: true);
    if (index.missing || index.value > node.items.length) {
      return const _Walk(missing: true);
    }
    if (index.value == node.items.length) {
      if (edit == _Edit.insert || edit == _Edit.set) {
        final created = _substructure(index.rest, inserted);
        if (created.pathError) return created;
        node.items.add(created.replaced!);
        return const _Walk();
      }
      return const _Walk(missing: true);
    }
    final child = _walk(node.items[index.value], index.rest, edit, inserted);
    if (child.pathError || child.missing) return child;
    if (edit == _Edit.none) return child;
    if (child.removed) {
      node.items.removeAt(index.value);
      return const _Walk();
    }
    if (child.replaced != null) node.items[index.value] = child.replaced!;
    return const _Walk();
  }
  return const _Walk(pathError: true);
}

_Walk _substructure(String rest, JNode inserted) {
  if (rest.isEmpty) return _Walk(replaced: inserted);
  if (rest.startsWith('.')) {
    final object = JObj([]);
    final walked = _walk(object, rest, _Edit.set, inserted);
    if (walked.pathError) return walked;
    return _Walk(replaced: object);
  }
  if (rest.startsWith('[')) {
    final array = JArr([]);
    final walked = _walk(array, rest, _Edit.set, inserted);
    if (walked.pathError) return walked;
    return _Walk(replaced: array);
  }
  return const _Walk(pathError: true);
}

int _fieldIndex(JObj object, String decoded) {
  for (var i = 0; i < object.fields.length; i++) {
    if (object.fields[i].key.decoded == decoded) return i;
  }
  return -1;
}

final class _PathKey {
  const _PathKey(this.decoded, this.rest, {this.error = false});
  final String decoded;
  final String rest;
  final bool error;
}

_PathKey _takeKey(String path) {
  if (path.length < 2) return const _PathKey('', '', error: true);
  if (path.codeUnitAt(1) == 0x22) {
    final end = path.indexOf('"', 2);
    if (end < 0) return const _PathKey('', '', error: true);
    return _PathKey(_unescape(path.substring(2, end)), path.substring(end + 1));
  }
  var end = 1;
  while (end < path.length) {
    final unit = path.codeUnitAt(end);
    if (unit == 0x2e || unit == 0x5b) break;
    end++;
  }
  if (end == 1) return const _PathKey('', '', error: true);
  return _PathKey(path.substring(1, end), path.substring(end));
}

String _unescape(String raw) {
  if (!raw.contains('\\')) return raw;
  final buffer = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final unit = raw.codeUnitAt(i);
    if (unit != 0x5c || i + 1 >= raw.length) {
      buffer.writeCharCode(unit);
      continue;
    }
    final next = raw.codeUnitAt(++i);
    switch (next) {
      case 0x22:
      case 0x5c:
      case 0x2f:
        buffer.writeCharCode(next);
      case 0x62:
        buffer.writeCharCode(0x08);
      case 0x66:
        buffer.writeCharCode(0x0c);
      case 0x6e:
        buffer.writeCharCode(0x0a);
      case 0x72:
        buffer.writeCharCode(0x0d);
      case 0x74:
        buffer.writeCharCode(0x09);
      case 0x75:
        if (i + 4 >= raw.length) return raw;
        final point = int.tryParse(raw.substring(i + 1, i + 5), radix: 16);
        if (point == null) return raw;
        buffer.writeCharCode(point);
        i += 4;
      default:
        buffer.writeCharCode(next);
    }
  }
  return buffer.toString();
}

final class _PathIndex {
  const _PathIndex(this.value, this.rest,
      {this.error = false, this.missing = false});
  final int value;
  final String rest;
  final bool error;
  final bool missing;
}

_PathIndex _takeIndex(String path, int length) {
  var i = 1;
  if (i < path.length && path.codeUnitAt(i) == 0x23) {
    var index = length;
    i++;
    if (i < path.length && path.codeUnitAt(i) == 0x2d) {
      i++;
      if (i >= path.length || !_digit(path.codeUnitAt(i))) {
        return const _PathIndex(0, '', error: true);
      }
      var delta = 0;
      while (i < path.length && _digit(path.codeUnitAt(i))) {
        delta = delta * 10 + path.codeUnitAt(i) - 48;
        if (delta > length) return const _PathIndex(0, '', missing: true);
        i++;
      }
      if (delta > index) return const _PathIndex(0, '', missing: true);
      index -= delta;
    }
    if (i >= path.length || path.codeUnitAt(i) != 0x5d) {
      return const _PathIndex(0, '', error: true);
    }
    return _PathIndex(index, path.substring(i + 1));
  }
  if (i >= path.length || !_digit(path.codeUnitAt(i))) {
    return const _PathIndex(0, '', error: true);
  }
  var index = 0;
  var beyond = false;
  while (i < path.length && _digit(path.codeUnitAt(i))) {
    if (!beyond) {
      index = index * 10 + path.codeUnitAt(i) - 48;
      if (index > length) beyond = true;
    }
    i++;
  }
  if (i >= path.length || path.codeUnitAt(i) != 0x5d) {
    return const _PathIndex(0, '', error: true);
  }
  return _PathIndex(beyond ? length + 1 : index, path.substring(i + 1));
}

bool _digit(int unit) => unit >= 48 && unit <= 57;

int _headerSize(int payload) {
  if (payload <= 11) return 1;
  if (payload <= 255) return 2;
  if (payload <= 65535) return 3;
  return 5;
}

int _payloadSize(JNode node) {
  switch (node) {
    case JNull() || JBool():
      return 0;
    case JNum(:final spelling):
      return utf8.encode(spelling).length;
    case JStr(:final raw):
      return utf8.encode(raw).length;
    case JArr(:final items):
      var size = 0;
      for (final item in items) {
        size += _totalSize(item);
      }
      return size;
    case JObj(:final fields):
      var size = 0;
      for (final field in fields) {
        size += _totalSize(field.key) + _totalSize(field.value);
      }
      return size;
  }
}

int _totalSize(JNode node) =>
    _headerSize(_payloadSize(node)) + _payloadSize(node);

int _typeOf(JNode node) {
  switch (node) {
    case JNull():
      return 0;
    case JBool(:final value):
      return value ? 1 : 2;
    case JNum():
      return node.real ? 5 : 3;
    case JStr(:final raw):
      return raw.contains('\\') ? 8 : 7;
    case JArr():
      return 11;
    case JObj():
      return 12;
  }
}

Uint8List _encode(JNode node) {
  final builder = BytesBuilder(copy: false);
  _writeBlob(node, builder);
  return builder.toBytes();
}

void _writeBlob(JNode node, BytesBuilder builder) {
  final payload = _payloadBytes(node);
  final size = payload.length;
  final type = _typeOf(node);
  if (size <= 11) {
    builder.addByte((size << 4) | type);
  } else if (size <= 255) {
    builder
      ..addByte(0xc0 | type)
      ..addByte(size);
  } else if (size <= 65535) {
    builder
      ..addByte(0xd0 | type)
      ..addByte((size >> 8) & 0xff)
      ..addByte(size & 0xff);
  } else {
    builder
      ..addByte(0xe0 | type)
      ..addByte((size >> 24) & 0xff)
      ..addByte((size >> 16) & 0xff)
      ..addByte((size >> 8) & 0xff)
      ..addByte(size & 0xff);
  }
  builder.add(payload);
}

Uint8List _payloadBytes(JNode node) {
  switch (node) {
    case JNull() || JBool():
      return Uint8List(0);
    case JNum(:final spelling):
      return Uint8List.fromList(utf8.encode(spelling));
    case JStr(:final raw):
      return Uint8List.fromList(utf8.encode(raw));
    case JArr(:final items):
      final builder = BytesBuilder(copy: false);
      for (final item in items) {
        _writeBlob(item, builder);
      }
      return builder.toBytes();
    case JObj(:final fields):
      final builder = BytesBuilder(copy: false);
      for (final field in fields) {
        _writeBlob(field.key, builder);
        _writeBlob(field.value, builder);
      }
      return builder.toBytes();
  }
}

bool _mightBeBinary(Uint8List bytes) {
  if (bytes.isEmpty) return false;
  final type = bytes[0] & 0x0f;
  if (type > 12) return false;
  final header = _readHeader(bytes, 0);
  if (header == null) return false;
  if (header.$1 + header.$2 != bytes.length) return false;
  if (type <= 2 && header.$2 != 0) return false;
  return true;
}

bool _strictJsonb(Uint8List bytes) {
  try {
    final end = _Jb(bytes).element(0);
    return end == bytes.length;
  } on _JsonError {
    return false;
  }
}

/// Header length and payload length.
(int, int)? _readHeader(Uint8List bytes, int offset) {
  if (offset >= bytes.length) return null;
  final head = bytes[offset];
  final sizeClass = head & 0xf0;
  if (sizeClass <= 0xb0) return (1, sizeClass >> 4);
  if (sizeClass == 0xc0) {
    if (offset + 1 >= bytes.length) return null;
    return (2, bytes[offset + 1]);
  }
  if (sizeClass == 0xd0) {
    if (offset + 2 >= bytes.length) return null;
    return (3, (bytes[offset + 1] << 8) | bytes[offset + 2]);
  }
  if (sizeClass == 0xe0) {
    if (offset + 4 >= bytes.length) return null;
    return (
      5,
      (bytes[offset + 1] << 24) |
          (bytes[offset + 2] << 16) |
          (bytes[offset + 3] << 8) |
          bytes[offset + 4]
    );
  }
  return null;
}

JNode _decode(Uint8List bytes) {
  final reader = _Jb(bytes);
  final end = reader.element(0);
  if (end != bytes.length) throw const SqlException('malformed JSON');
  return reader.node;
}

final class _Jb {
  _Jb(this.bytes);
  final Uint8List bytes;
  JNode node = JNull();

  int element(int offset) {
    final header = _readHeader(bytes, offset);
    if (header == null) throw const _JsonError();
    final type = bytes[offset] & 0x0f;
    final start = offset + header.$1;
    final end = start + header.$2;
    if (end > bytes.length) throw const _JsonError();
    final payload = Uint8List.sublistView(bytes, start, end);
    switch (type) {
      case 0:
        if (header.$2 != 0) throw const _JsonError();
        node = JNull();
      case 1:
      case 2:
        if (header.$2 != 0) throw const _JsonError();
        node = JBool(type == 1);
      case 3:
      case 4:
      case 5:
      case 6:
        node = JNum(utf8.decode(payload, allowMalformed: true));
      case 7:
      case 10:
        final text = utf8.decode(payload, allowMalformed: true);
        node = JStr(text, text);
      case 8:
      case 9:
        final raw = utf8.decode(payload, allowMalformed: true);
        node = JStr(_unescape(raw), raw);
      case 11:
        final items = <JNode>[];
        var cursor = start;
        while (cursor < end) {
          cursor = element(cursor);
          items.add(node);
        }
        if (cursor != end) throw const _JsonError();
        node = JArr(items);
      case 12:
        final fields = <JField>[];
        var cursor = start;
        while (cursor < end) {
          cursor = element(cursor);
          if (node is! JStr) throw const _JsonError();
          final key = node as JStr;
          cursor = element(cursor);
          fields.add(JField(key, node));
        }
        if (cursor != end) throw const _JsonError();
        node = JObj(fields);
      default:
        throw const _JsonError();
    }
    return end;
  }
}

final class _Spot {
  _Spot(this.node, this.rowId, this.valueOffset, this.fullkey, this.parentPath,
      this.key);
  final JNode node;
  final int rowId;
  final int valueOffset;
  final String fullkey;
  final String parentPath;
  final Object? key;
}

_Spot? _locate(JNode root, String path) {
  if (path == '\$') return _Spot(root, 0, 0, '\$', '\$', null);
  var node = root;
  var valueOffset = 0;
  var rowId = 0;
  var fullkey = '\$';
  var parentPath = '\$';
  Object? key;
  var rest = path.substring(1);
  while (rest.isNotEmpty) {
    if (rest.startsWith('.')) {
      final parsed = _takeKey(rest);
      if (parsed.error) _badPath(path);
      if (node is! JObj) return null;
      final index = _fieldIndex(node, parsed.decoded);
      if (index < 0) return null;
      var offset = valueOffset + _headerSize(_payloadSize(node));
      for (var i = 0; i < index; i++) {
        offset +=
            _totalSize(node.fields[i].key) + _totalSize(node.fields[i].value);
      }
      final field = node.fields[index];
      parentPath = fullkey;
      fullkey = '$fullkey${_pathKey(field.key.raw)}';
      rowId = offset;
      valueOffset = offset + _totalSize(field.key);
      key = field.key.decoded;
      node = field.value;
      rest = parsed.rest;
      continue;
    }
    if (rest.startsWith('[')) {
      if (node is! JArr) return null;
      final parsed = _takeIndex(rest, node.items.length);
      if (parsed.error) _badPath(path);
      if (parsed.missing || parsed.value >= node.items.length) return null;
      var offset = valueOffset + _headerSize(_payloadSize(node));
      for (var i = 0; i < parsed.value; i++) {
        offset += _totalSize(node.items[i]);
      }
      parentPath = fullkey;
      key = BigInt.from(parsed.value);
      fullkey = '$fullkey[${parsed.value}]';
      rowId = offset;
      valueOffset = offset;
      node = node.items[parsed.value];
      rest = parsed.rest;
      continue;
    }
    _badPath(path);
  }
  return _Spot(node, rowId, valueOffset, fullkey, parentPath, key);
}

String _pathKey(String raw) {
  if (raw.isNotEmpty) {
    final first = raw.codeUnitAt(0);
    final letter = first >= 65 && first <= 90 || first >= 97 && first <= 122;
    if (letter &&
        raw.codeUnits.every((unit) =>
            unit >= 48 && unit <= 57 ||
            unit >= 65 && unit <= 90 ||
            unit >= 97 && unit <= 122)) {
      return '.$raw';
    }
  }
  return '."$raw"';
}

void _emit(JNode node, int rowId, int valueOffset, int? parent, String fullkey,
    String path, Object? key, List<List<Object?>> rows,
    {required bool recurse}) {
  rows.add([
    key,
    _cell(node),
    _typeName(node),
    node is JArr || node is JObj ? null : _cell(node),
    BigInt.from(rowId),
    parent == null ? null : BigInt.from(parent),
    fullkey,
    path,
  ]);
  if (recurse) {
    _emitChildren(node, valueOffset, rowId, fullkey, rows, recurse: true);
  }
}

void _emitChildren(JNode node, int valueOffset, int? parent, String fullkey,
    List<List<Object?>> rows,
    {required bool recurse}) {
  if (node is JArr) {
    var offset = valueOffset + _headerSize(_payloadSize(node));
    for (var i = 0; i < node.items.length; i++) {
      final child = node.items[i];
      if (recurse) {
        _emit(child, offset, offset, parent, '$fullkey[$i]', fullkey,
            BigInt.from(i), rows,
            recurse: true);
      } else {
        _emit(child, offset, offset, null, '$fullkey[$i]', fullkey,
            BigInt.from(i), rows,
            recurse: false);
      }
      offset += _totalSize(child);
    }
  } else if (node is JObj) {
    var offset = valueOffset + _headerSize(_payloadSize(node));
    for (final field in node.fields) {
      final valueAt = offset + _totalSize(field.key);
      final childKey = '$fullkey${_pathKey(field.key.raw)}';
      if (recurse) {
        _emit(field.value, offset, valueAt, parent, childKey, fullkey,
            field.key.decoded, rows,
            recurse: true);
      } else {
        _emit(field.value, offset, valueAt, null, childKey, fullkey,
            field.key.decoded, rows,
            recurse: false);
      }
      offset = valueAt + _totalSize(field.value);
    }
  }
}

Object? _cell(JNode node) {
  final value = _sqlOf(node);
  return value is JsonText ? value.text : value;
}
