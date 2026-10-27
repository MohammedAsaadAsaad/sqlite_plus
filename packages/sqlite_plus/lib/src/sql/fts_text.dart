import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'tokenizer.dart';
import 'unicode61_data.dart';
import 'values.dart';

/// A token and its byte span in the original UTF-8 text.
final class FtsToken {
  const FtsToken(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

/// unicode61 folds and classifies characters. It is not an Arabic stemmer:
/// Arabic letters stay a single token, the same way the pinned unicode61 does.
abstract class FtsTokenizer {
  String get name;
  List<FtsToken> tokenize(String text);
}

const _maxTokenBytes = 32768;

final class AsciiTokenizer extends FtsTokenizer {
  AsciiTokenizer({List<int>? tokenChars, List<int>? separators}) {
    _token.setAll(0, _asciiToken);
    for (final code in tokenChars ?? const <int>[]) {
      if (code < 128) _token[code] = 1;
    }
    for (final code in separators ?? const <int>[]) {
      if (code < 128) _token[code] = 0;
    }
  }

  @override
  String get name => 'ascii';
  final List<int> _token = List<int>.filled(128, 0);

  static const _asciiToken = <int>[
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, //
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, //
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, //
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0
  ];

  bool _isToken(int unit) => unit >= 128 || _token[unit] == 1;

  @override
  List<FtsToken> tokenize(String text) {
    final bytes = utf8Bytes(text);
    final tokens = <FtsToken>[];
    var index = 0;
    while (index < bytes.length) {
      while (index < bytes.length && !_isToken(bytes[index])) {
        index++;
      }
      if (index == bytes.length) break;
      final start = index;
      var end = index + 1;
      while (end < bytes.length && _isToken(bytes[end])) {
        end++;
      }
      tokens.add(FtsToken(_fold(bytes, start, end), start, end));
      index = end + 1;
    }
    return tokens;
  }

  String _fold(List<int> bytes, int start, int end) {
    final folded = Uint8List(math.min(end - start, _maxTokenBytes));
    final limit = start + folded.length;
    for (var i = start; i < limit; i++) {
      final unit = bytes[i];
      folded[i - start] = unit >= 65 && unit <= 90 ? unit + 32 : unit;
    }
    return String.fromCharCodes(folded);
  }
}

final class Unicode61Tokenizer extends FtsTokenizer {
  Unicode61Tokenizer({
    this.removeDiacritics = 1,
    String categories = 'L* N* Co',
    String tokenChars = '',
    String separators = '',
  }) {
    if (_setCategories(categories)) {
      throw const SqlException('error in tokenizer constructor');
    }
    for (var code = 0; code < 128; code++) {
      _ascii[code] = _categories[fts5UnicodeCategory(code)] == 1 ? 1 : 0;
    }
    _exceptions('tokenchars', tokenChars, true);
    _exceptions('separators', separators, false);
  }

  @override
  String get name => 'unicode61';
  final int removeDiacritics;
  final List<int> _categories = List<int>.filled(32, 0);
  final List<int> _ascii = List<int>.filled(128, 0);
  final List<int> _exception = <int>[];

  bool _setCategories(String text) {
    var index = 0;
    while (index < text.length) {
      while (index < text.length &&
          (text.codeUnitAt(index) == 32 || text.codeUnitAt(index) == 9)) {
        index++;
      }
      if (index >= text.length) break;
      final start = index;
      while (index < text.length &&
          text.codeUnitAt(index) != 32 &&
          text.codeUnitAt(index) != 9) {
        index++;
      }
      if (_parseCategory(text.substring(start, index))) return true;
    }
    return false;
  }

  bool _parseCategory(String token) {
    if (token.length < 2) return true;
    _categories[0] = 1;
    const groups = <String, List<int>>{
      'Cc': [1],
      'Cf': [2],
      'Cn': [3],
      'Cs': [4],
      'Co': [31],
      'C*': [1, 2, 3, 4, 31],
      'Ll': [5],
      'Lm': [6],
      'Lo': [7],
      'Lt': [8],
      'Lu': [9],
      'LC': [30],
      'L*': [5, 6, 7, 8, 9, 30],
      'Mc': [10],
      'Me': [11],
      'Mn': [12],
      'M*': [10, 11, 12],
      'Nd': [13],
      'Nl': [14],
      'No': [15],
      'N*': [13, 14, 15],
      'Pc': [16],
      'Pd': [17],
      'Pe': [18],
      'Pf': [19],
      'Pi': [20],
      'Po': [21],
      'Ps': [22],
      'P*': [16, 17, 18, 19, 20, 21, 22],
      'Sc': [23],
      'Sk': [24],
      'Sm': [25],
      'So': [26],
      'S*': [23, 24, 25, 26],
      'Zl': [27],
      'Zp': [28],
      'Zs': [29],
      'Z*': [27, 28, 29],
    };
    final ids = groups[token.substring(0, 2)];
    if (ids == null) return true;
    for (final id in ids) {
      _categories[id] = 1;
    }
    return false;
  }

  void _exceptions(String label, String text, bool token) {
    if (label.isEmpty) return;
    final codes = _codepoints(utf8Bytes(text));
    for (final code in codes) {
      final point = code.$1;
      if (point < 128) {
        _ascii[point] = token ? 1 : 0;
        continue;
      }
      final isToken = _categories[fts5UnicodeCategory(point)] == 1;
      if ((isToken ? 1 : 0) != (token ? 1 : 0) && !fts5IsDiacritic(point)) {
        final index = _exception.indexWhere((item) => item > point);
        if (index < 0) {
          _exception.add(point);
        } else {
          _exception.insert(index, point);
        }
      }
    }
  }

  bool _isToken(int code) {
    if (code < 128) return _ascii[code] == 1;
    final category = _categories[fts5UnicodeCategory(code)] == 1;
    return category ^ _isException(code);
  }

  bool _isException(int code) {
    var lo = 0, hi = _exception.length - 1;
    while (hi >= lo) {
      final test = (hi + lo) >> 1;
      final found = _exception[test];
      if (found == code) return true;
      if (code > found) {
        lo = test + 1;
      } else {
        hi = test - 1;
      }
    }
    return false;
  }

  @override
  List<FtsToken> tokenize(String text) {
    final bytes = utf8Bytes(text);
    final tokens = <FtsToken>[];
    var index = 0;
    while (index < bytes.length) {
      while (index < bytes.length) {
        final code = _peek(bytes, index);
        if (code == null) {
          index = bytes.length;
          break;
        }
        if (_isToken(code.$1)) break;
        index += code.$2;
      }
      if (index >= bytes.length) break;
      final start = index;
      final folded = BytesBuilder(copy: false);
      while (index < bytes.length) {
        final code = _peek(bytes, index);
        if (code == null) break;
        final value = code.$1;
        final width = code.$2;
        if (value < 128) {
          if (_ascii[value] == 0) break;
          final unit = value >= 65 && value <= 90 ? value + 32 : value;
          if (folded.length < _maxTokenBytes) folded.addByte(unit);
          index += width;
        } else if (_isToken(value) || fts5IsDiacritic(value)) {
          final mapped = fts5UnicodeFold(value, removeDiacritics);
          if (mapped != 0 && folded.length < _maxTokenBytes) {
            _writeUtf8(folded, mapped);
          }
          index += width;
        } else {
          break;
        }
      }
      tokens.add(
          FtsToken(String.fromCharCodes(folded.takeBytes()), start, index));
    }
    return tokens;
  }
}

List<int> utf8Bytes(String text) => text.codeUnits.every((unit) => unit < 128)
    ? text.codeUnits
    : _encodeUtf8(text);

List<int> _encodeUtf8(String text) {
  final out = <int>[];
  for (final rune in text.runes) {
    if (rune < 0x80) {
      out.add(rune);
    } else if (rune < 0x800) {
      out.add(0xC0 | (rune >> 6));
      out.add(0x80 | (rune & 0x3F));
    } else if (rune < 0x10000) {
      out.add(0xE0 | (rune >> 12));
      out.add(0x80 | ((rune >> 6) & 0x3F));
      out.add(0x80 | (rune & 0x3F));
    } else {
      out.add(0xF0 | (rune >> 18));
      out.add(0x80 | ((rune >> 12) & 0x3F));
      out.add(0x80 | ((rune >> 6) & 0x3F));
      out.add(0x80 | (rune & 0x3F));
    }
  }
  return out;
}

void _writeUtf8(BytesBuilder out, int code) {
  if (code < 0x80) {
    if (out.length < _maxTokenBytes) out.addByte(code);
  } else if (code < 0x800) {
    if (out.length + 2 <= _maxTokenBytes) {
      out.addByte(0xC0 | (code >> 6));
      out.addByte(0x80 | (code & 0x3F));
    }
  } else if (code < 0x10000) {
    if (out.length + 3 <= _maxTokenBytes) {
      out.addByte(0xE0 | (code >> 12));
      out.addByte(0x80 | ((code >> 6) & 0x3F));
      out.addByte(0x80 | (code & 0x3F));
    }
  } else if (out.length + 4 <= _maxTokenBytes) {
    out.addByte(0xF0 | (code >> 18));
    out.addByte(0x80 | ((code >> 12) & 0x3F));
    out.addByte(0x80 | ((code >> 6) & 0x3F));
    out.addByte(0x80 | (code & 0x3F));
  }
}

(int, int)? _peek(List<int> bytes, int index) {
  if (index >= bytes.length) return null;
  final first = bytes[index];
  if (first < 0x80) return (first, 1);
  int width;
  int code;
  if (first < 0xE0) {
    width = 2;
    code = first & 0x1F;
  } else if (first < 0xF0) {
    width = 3;
    code = first & 0x0F;
  } else if (first < 0xF8) {
    width = 4;
    code = first & 0x07;
  } else {
    return (0xFFFD, 1);
  }
  if (index + width > bytes.length) return (0xFFFD, bytes.length - index);
  for (var extra = 1; extra < width; extra++) {
    final unit = bytes[index + extra];
    if ((unit & 0xC0) != 0x80) return (0xFFFD, extra);
    code = (code << 6) | (unit & 0x3F);
  }
  if (code < 0x80 ||
      (code & 0xFFFFF800) == 0xD800 ||
      (code & 0xFFFFFFFE) == 0xFFFE) {
    return (0xFFFD, width);
  }
  return (code, width);
}

List<(int, int)> _codepoints(List<int> bytes) {
  final out = <(int, int)>[];
  var index = 0;
  while (index < bytes.length) {
    final code = _peek(bytes, index);
    if (code == null) break;
    out.add(code);
    index += code.$2;
  }
  return out;
}

int fts5UnicodeCategory(int code) {
  if (code < 0 || code >= (1 << 20)) return 0;
  final block = code >> 16;
  if (block + 1 >= fts5UnicodeBlock.length) return 0;
  var lo = fts5UnicodeBlock[block];
  var hi = fts5UnicodeBlock[block + 1] - 1;
  if (hi < lo) return 0;
  var found = -1;
  while (hi >= lo) {
    final test = (hi + lo) >> 1;
    if (code >= fts5UnicodeMap[test]) {
      found = test;
      lo = test + 1;
    } else {
      hi = test - 1;
    }
  }
  if (found < 0) return 0;
  if (code >= fts5UnicodeMap[found] + (fts5UnicodeData[found] >> 5)) return 0;
  final category = fts5UnicodeData[found] & 0x1F;
  if (category != 30) return category;
  return ((code - fts5UnicodeMap[found]) & 1) != 0 ? 5 : 9;
}

int fts5UnicodeFold(int code, int removeDiacritics) {
  var folded = code;
  if (code < 128) {
    if (code >= 65 && code <= 90) folded = code + 32;
  } else if (code < 65536) {
    var lo = 0, hi = fts5FoldCode.length - 1, found = -1;
    while (hi >= lo) {
      final test = (hi + lo) >> 1;
      if (code >= fts5FoldCode[test]) {
        found = test;
        lo = test + 1;
      } else {
        hi = test - 1;
      }
    }
    if (found >= 0 &&
        code < fts5FoldCode[found] + fts5FoldRange[found] &&
        (0x01 & fts5FoldFlags[found] & (fts5FoldCode[found] ^ code)) == 0) {
      folded = (code + fts5FoldOffset[fts5FoldFlags[found] >> 1]) & 0xFFFF;
    }
    if (removeDiacritics != 0) {
      folded = _removeDiacritic(folded, removeDiacritics == 2);
    }
  } else if (code >= 66560 && code < 66600) {
    folded = code + 40;
  }
  return folded;
}

int _removeDiacritic(int code, bool complex) {
  final key = (code << 3) | 7;
  var lo = 0, hi = fts5DiacriticKey.length - 1, found = 0;
  while (hi >= lo) {
    final test = (hi + lo) >> 1;
    if (key >= fts5DiacriticKey[test]) {
      found = test;
      lo = test + 1;
    } else {
      hi = test - 1;
    }
  }
  final mapped = fts5DiacriticChar[found];
  if (!complex && (mapped & 0x80) != 0) return code;
  final rule = fts5DiacriticKey[found];
  if (code > (rule >> 3) + (rule & 7)) return code;
  return mapped & 0x7F;
}

bool fts5IsDiacritic(int code) {
  if (code < 768 || code > 817) return false;
  if (code < 800) return ((0x08029FDF >> (code - 768)) & 1) != 0;
  return ((0x000361F8 >> (code - 800)) & 1) != 0;
}

/// First [chars] Unicode scalars of [token], or empty when the token is shorter.
String ftsPrefixChars(String token, int chars) {
  if (chars <= 0) return '';
  final bytes = utf8Bytes(token);
  var index = 0, count = 0;
  while (index < bytes.length && count < chars) {
    final code = _peek(bytes, index);
    if (code == null) return '';
    index += code.$2;
    count++;
  }
  if (count < chars || index > bytes.length) return '';
  final end = _utf8CharCountToStringIndex(token, chars);
  if (end < 0) return '';
  return token.substring(0, end);
}

int _utf8CharCountToStringIndex(String token, int chars) {
  var count = 0, index = 0;
  final iterator = token.runes.iterator;
  while (count < chars && iterator.moveNext()) {
    count++;
    index += iterator.current > 0xFFFF ? 2 : 1;
  }
  return count < chars ? -1 : index;
}

FtsTokenizer ftsTokenizer(String name, List<String> pairs) {
  final key = asciiLower(name);
  if (key != 'ascii' && key != 'unicode61' && key != 'simple') {
    throw SqlException('no such tokenizer: $name');
  }
  if (pairs.length.isOdd) {
    throw const SqlException('error in tokenizer constructor');
  }
  final values = <String, String>{};
  for (var i = 0; i < pairs.length; i += 2) {
    values[asciiLower(pairs[i])] = pairs[i + 1];
  }
  if (key == 'ascii' || key == 'simple') {
    for (final option in values.keys) {
      if (option != 'tokenchars' && option != 'separators') {
        throw const SqlException('error in tokenizer constructor');
      }
    }
    return AsciiTokenizer(
        tokenChars: utf8Bytes(values['tokenchars'] ?? ''),
        separators: utf8Bytes(values['separators'] ?? ''));
  }
  var remove = 1;
  final removeText = values['remove_diacritics'];
  if (removeText != null) {
    if (removeText != '0' && removeText != '1' && removeText != '2') {
      throw const SqlException('error in tokenizer constructor');
    }
    remove = int.parse(removeText);
  }
  for (final option in values.keys) {
    if (!['remove_diacritics', 'tokenchars', 'separators', 'categories']
        .contains(option)) {
      throw const SqlException('error in tokenizer constructor');
    }
  }
  return Unicode61Tokenizer(
      removeDiacritics: remove,
      categories: values['categories'] ?? 'L* N* Co',
      tokenChars: values['tokenchars'] ?? '',
      separators: values['separators'] ?? '');
}

List<String> ftsOptionWords(String text) {
  final words = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }
    if (char == ' ' || char == '\t') {
      if (buffer.isNotEmpty) {
        words.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.write(char);
  }
  if (quote != null) throw const SqlException('error in tokenizer constructor');
  if (buffer.isNotEmpty) words.add(buffer.toString());
  return words;
}

final class Fts5Column {
  const Fts5Column(this.name, {this.unindexed = false});
  final String name;
  final bool unindexed;
}

/// Parsed `CREATE VIRTUAL TABLE ... USING fts5(...)` arguments.
final class Fts5Spec {
  Fts5Spec({
    required this.table,
    required this.columns,
    required this.tokenizer,
    required this.prefix,
    required this.contentMode,
    required this.contentTable,
    required this.contentRowid,
    required this.contentlessDelete,
    required this.columnSize,
  });
  final String table;
  final List<Fts5Column> columns;
  final FtsTokenizer tokenizer;
  final List<int> prefix;
  final String contentMode;
  final String? contentTable;
  final String contentRowid;
  final bool contentlessDelete;
  final bool columnSize;

  bool get contentless => contentMode == 'none';
  bool get external => contentMode == 'external';
  List<String> get visibleNames => [for (final column in columns) column.name];

  static Fts5Spec parse(String table, List<String> arguments) {
    final columns = <Fts5Column>[];
    final seen = <String>{};
    FtsTokenizer? tokenizer;
    final prefix = <int>[];
    var contentMode = 'normal';
    String? contentTable;
    var contentRowid = 'rowid';
    var contentlessDelete = false;
    var columnSize = true;
    var sawContentlessDelete = false;
    for (final raw in arguments) {
      final argument = raw.trim();
      final option = _option(argument);
      if (option != null) {
        final key = asciiLower(option.$1);
        final value = option.$2;
        switch (key) {
          case 'tokenize':
            final words = ftsOptionWords(value);
            if (words.isEmpty) {
              throw const SqlException('error in tokenizer constructor');
            }
            tokenizer = ftsTokenizer(words.first, words.sublist(1));
          case 'prefix':
            final lengths = value
                .split(RegExp(r'\s+'))
                .where((part) => part.isNotEmpty)
                .toList();
            if (lengths.isEmpty || lengths.length > 31) {
              throw const SqlException('prefix length out of range (max 999)');
            }
            for (final length in lengths) {
              final parsed = int.tryParse(length);
              if (parsed == null || parsed < 1 || parsed > 999) {
                throw const SqlException(
                    'prefix length out of range (max 999)');
              }
              prefix.add(parsed);
            }
          case 'content':
            if (value.isEmpty) {
              contentMode = 'none';
            } else {
              contentMode = 'external';
              contentTable = value;
            }
          case 'content_rowid':
            if (value.isEmpty) {
              throw const SqlException('malformed content_rowid=... directive');
            }
            contentRowid = value;
          case 'contentless_delete':
            if (value != '0' && value != '1') {
              throw const SqlException(
                  'malformed contentless_delete=... directive');
            }
            contentlessDelete = value == '1';
            sawContentlessDelete = true;
          case 'columnsize':
            if (value != '0' && value != '1') {
              throw const SqlException('malformed columnsize=... directive');
            }
            columnSize = value == '1';
          default:
            throw SqlException('fts5 option is not implemented: $key');
        }
        continue;
      }
      final parts = argument.split(RegExp(r'\s+'));
      if (parts.isEmpty || parts.first.isEmpty) {
        throw SqlException('vtable constructor failed: $table');
      }
      var unindexed = false;
      if (parts.length == 2 && asciiLower(parts[1]) == 'unindexed') {
        unindexed = true;
      } else if (parts.length != 1) {
        throw SqlException('unrecognized option: "${parts.last}"');
      }
      final name = _unquote(parts.first);
      final lower = asciiLower(name);
      if (lower == 'rank' ||
          lower == asciiLower(table) ||
          !seen.add(lower) ||
          name.isEmpty) {
        if (lower == 'rank') {
          throw const SqlException('reserved fts5 column name: rank');
        }
        throw SqlException('vtable constructor failed: $table');
      }
      columns.add(Fts5Column(name, unindexed: unindexed));
    }
    if (columns.isEmpty) {
      throw SqlException('vtable constructor failed: $table');
    }
    if (sawContentlessDelete && contentlessDelete && contentMode != 'none') {
      throw const SqlException(
          'contentless_delete=1 requires a contentless table');
    }
    if (contentlessDelete && !columnSize) {
      throw const SqlException(
          'contentless_delete=1 is incompatible with columnsize=0');
    }
    return Fts5Spec(
        table: table,
        columns: columns,
        tokenizer: tokenizer ?? Unicode61Tokenizer(),
        prefix: prefix,
        contentMode: contentMode,
        contentTable: contentTable,
        contentRowid: contentRowid,
        contentlessDelete: contentlessDelete,
        columnSize: columnSize);
  }
}

(String, String)? _option(String argument) {
  final index = argument.indexOf('=');
  if (index <= 0) return null;
  return (
    _unquote(argument.substring(0, index).trim()),
    _unquote(argument.substring(index + 1).trim())
  );
}

String _unquote(String text) {
  if (text.length >= 2) {
    final quote = text[0];
    if ((quote == "'" || quote == '"') && text.endsWith(quote)) {
      return text
          .substring(1, text.length - 1)
          .replaceAll('$quote$quote', quote);
    }
  }
  return text;
}

final class FtsDocument {
  FtsDocument(this.rowId, this.texts, this.tokens, this.unindexed);
  final BigInt rowId;
  final List<String?> texts;
  final List<List<FtsToken>> tokens;
  final List<bool> unindexed;
  int get tokenCount {
    var count = 0;
    for (var column = 0; column < tokens.length; column++) {
      if (!unindexed[column]) count += tokens[column].length;
    }
    return count;
  }
}

final class FtsInst {
  const FtsInst(this.phrase, this.column, this.offset, this.size);
  final int phrase;
  final int column;
  final int offset;
  final int size;
}

sealed class FtsExpr {
  bool matches(FtsDocument document, int? column);
  void collect(FtsDocument document, int? column, List<FtsInst> into);
  List<FtsLeaf> get leaves;
}

final class FtsLeaf extends FtsExpr {
  FtsLeaf(this.id, this.tokens, {this.prefix = false, this.column});
  final int id;
  final List<String> tokens;
  final bool prefix;
  final int? column;

  @override
  List<FtsLeaf> get leaves => [this];

  int? _column(int? outer) {
    if (column != null && outer != null && column != outer) return -1;
    return column ?? outer;
  }

  @override
  bool matches(FtsDocument document, int? column) =>
      _hits(document, column).isNotEmpty;

  @override
  void collect(FtsDocument document, int? column, List<FtsInst> into) {
    into.addAll(_hits(document, column));
  }

  List<FtsInst> _hits(FtsDocument document, int? outer) {
    final selected = _column(outer);
    if (selected == -1 || tokens.isEmpty) return const [];
    final columns = selected == null
        ? [for (var i = 0; i < document.tokens.length; i++) i]
        : [selected];
    final hits = <FtsInst>[];
    for (final index in columns) {
      if (index < 0 ||
          index >= document.tokens.length ||
          document.unindexed[index]) {
        continue;
      }
      final source = document.tokens[index];
      for (var start = 0; start + tokens.length <= source.length; start++) {
        if (_at(source, start)) {
          hits.add(FtsInst(id, index, start, tokens.length));
        }
      }
    }
    return hits;
  }

  bool _at(List<FtsToken> source, int start) {
    for (var i = 0; i < tokens.length; i++) {
      final text = source[start + i].text;
      final wanted = tokens[i];
      final last = i == tokens.length - 1;
      if (last && prefix) {
        if (!text.startsWith(wanted)) return false;
      } else if (text != wanted) {
        return false;
      }
    }
    return true;
  }
}

final class FtsNot extends FtsExpr {
  FtsNot(this.inner);
  final FtsExpr inner;
  @override
  List<FtsLeaf> get leaves => inner.leaves;
  @override
  bool matches(FtsDocument document, int? column) =>
      !inner.matches(document, column);
  @override
  void collect(FtsDocument document, int? column, List<FtsInst> into) {}
}

final class FtsAnd extends FtsExpr {
  FtsAnd(this.left, this.right);
  final FtsExpr left;
  final FtsExpr right;
  @override
  List<FtsLeaf> get leaves => [...left.leaves, ...right.leaves];
  @override
  bool matches(FtsDocument document, int? column) =>
      left.matches(document, column) && right.matches(document, column);
  @override
  void collect(FtsDocument document, int? column, List<FtsInst> into) {
    if (!matches(document, column)) return;
    left.collect(document, column, into);
    right.collect(document, column, into);
  }
}

final class FtsOr extends FtsExpr {
  FtsOr(this.left, this.right);
  final FtsExpr left;
  final FtsExpr right;
  @override
  List<FtsLeaf> get leaves => [...left.leaves, ...right.leaves];
  @override
  bool matches(FtsDocument document, int? column) =>
      left.matches(document, column) || right.matches(document, column);
  @override
  void collect(FtsDocument document, int? column, List<FtsInst> into) {
    if (left.matches(document, column)) left.collect(document, column, into);
    if (right.matches(document, column)) right.collect(document, column, into);
  }
}

final class FtsNear extends FtsExpr {
  FtsNear(this.parts, this.distance, {this.column});
  final List<FtsExpr> parts;
  final int distance;
  final int? column;
  @override
  List<FtsLeaf> get leaves => [for (final part in parts) ...part.leaves];

  int? _column(int? outer) {
    if (column != null && outer != null && column != outer) return -1;
    return column ?? outer;
  }

  @override
  bool matches(FtsDocument document, int? column) {
    final selected = _column(column);
    if (selected == -1) return false;
    final groups = [
      for (final part in parts) _instances(part, document, selected)
    ];
    if (groups.any((group) => group.isEmpty)) return false;
    return _close(groups);
  }

  @override
  void collect(FtsDocument document, int? column, List<FtsInst> into) {
    if (!matches(document, column)) return;
    for (final part in parts) {
      part.collect(document, _column(column), into);
    }
  }

  List<FtsInst> _instances(FtsExpr part, FtsDocument document, int? column) {
    final into = <FtsInst>[];
    part.collect(document, column, into);
    return into;
  }

  bool _close(List<List<FtsInst>> groups) {
    bool walk(int index, FtsInst? previous) {
      if (index == groups.length) return true;
      for (final inst in groups[index]) {
        if (previous != null) {
          if (previous.column != inst.column) continue;
          if (_gap(previous, inst) > distance) continue;
        }
        if (walk(index + 1, inst)) return true;
      }
      return false;
    }

    return walk(0, null);
  }
}

int _gap(FtsInst a, FtsInst b) {
  if (a.offset <= b.offset) {
    return b.offset - (a.offset + a.size - 1) - 1;
  }
  return a.offset - (b.offset + b.size - 1) - 1;
}

final class FtsQuery {
  FtsQuery(this.expression, this.text);
  final FtsExpr expression;
  final String text;
  bool matches(FtsDocument document, {int? column}) =>
      expression.matches(document, column);
  List<FtsInst> instances(FtsDocument document, {int? column}) {
    final into = <FtsInst>[];
    if (expression.matches(document, column)) {
      expression.collect(document, column, into);
    }
    return into;
  }

  List<FtsLeaf> get phrases => expression.leaves;
}

FtsQuery parseFtsQuery(
    String text, FtsTokenizer tokenizer, List<String> columns) {
  final parser = _QueryParser(text, tokenizer, columns);
  final expression = parser.parseOr();
  if (!parser._done) {
    throw SqlException('fts5: syntax error near "${parser._peekText()}"');
  }
  return FtsQuery(expression, text);
}

final class _QueryParser {
  _QueryParser(this.text, this.tokenizer, this.columns) {
    _scan();
  }
  final String text;
  final FtsTokenizer tokenizer;
  final List<String> columns;
  final List<_Tok> _tokens = [];
  var _index = 0;
  var _phrase = 0;

  bool get _done => _index >= _tokens.length;
  _Tok? get _current => _done ? null : _tokens[_index];
  String _peekText() => _done ? '' : _tokens[_index].text;

  FtsExpr parseOr() {
    var left = parseAnd();
    while (_take('or')) {
      left = FtsOr(left, parseAnd());
    }
    return left;
  }

  FtsExpr parseAnd() {
    var left = parseUnary();
    while (!_done && !_is(['or', 'rparen'])) {
      if (_take('and')) {
        left = FtsAnd(left, parseUnary());
      } else if (_current!.kind == 'word' ||
          _current!.kind == 'phrase' ||
          _current!.kind == 'not' ||
          _current!.kind == 'minus' ||
          _current!.kind == 'lparen' ||
          _current!.kind == 'near') {
        left = FtsAnd(left, parseUnary());
      } else {
        break;
      }
    }
    return left;
  }

  FtsExpr parseUnary() {
    if (_take('not') || _take('minus')) return FtsNot(parseUnary());
    return parseColumn();
  }

  FtsExpr parseColumn() {
    if (_current?.kind == 'word' &&
        _index + 1 < _tokens.length &&
        _tokens[_index + 1].kind == 'colon') {
      final name = _tokens[_index].text;
      final column = _column(name);
      _index += 2;
      return _pin(parsePrimary(), column);
    }
    return parsePrimary();
  }

  FtsExpr parsePrimary() {
    final token = _current;
    if (token == null) throw const SqlException('fts5: syntax error');
    if (_take('lparen')) {
      final inner = parseOr();
      if (!_take('rparen')) throw const SqlException('fts5: syntax error');
      return inner;
    }
    if (token.kind == 'near') {
      _index++;
      return _near();
    }
    if (token.kind == 'phrase' || token.kind == 'word') {
      _index++;
      final tokens = token.kind == 'phrase'
          ? token.tokens
          : tokenizer.tokenize(token.text).map((item) => item.text).toList();
      if (tokens.isEmpty) throw const SqlException('fts5: syntax error');
      return FtsLeaf(_phrase++, tokens, prefix: token.prefix);
    }
    throw SqlException('fts5: syntax error near "${token.text}"');
  }

  FtsExpr _near() {
    if (!_take('lparen')) throw const SqlException('fts5: syntax error');
    final parts = <FtsExpr>[];
    var distance = 10;
    while (!_done && _current!.kind != 'rparen') {
      if (_current!.kind == 'comma') {
        _index++;
        final number = _current;
        if (number == null || int.tryParse(number.text) == null) {
          throw const SqlException('fts5: syntax error');
        }
        distance = int.parse(number.text);
        _index++;
        break;
      }
      parts.add(parseUnary());
    }
    if (!_take('rparen') || parts.length < 2) {
      throw const SqlException('fts5: syntax error');
    }
    return FtsNear(parts, distance);
  }

  int _column(String name) {
    final index =
        columns.indexWhere((column) => asciiLower(column) == asciiLower(name));
    if (index < 0) throw SqlException('no such column: $name');
    return index;
  }

  FtsExpr _pin(FtsExpr expression, int column) {
    if (expression is FtsLeaf) {
      return FtsLeaf(expression.id, expression.tokens,
          prefix: expression.prefix, column: column);
    }
    if (expression is FtsNear) {
      return FtsNear(expression.parts, expression.distance, column: column);
    }
    if (expression is FtsNot) return FtsNot(_pin(expression.inner, column));
    if (expression is FtsAnd) {
      return FtsAnd(
          _pin(expression.left, column), _pin(expression.right, column));
    }
    if (expression is FtsOr) {
      return FtsOr(
          _pin(expression.left, column), _pin(expression.right, column));
    }
    return expression;
  }

  bool _is(List<String> kinds) => !_done && kinds.contains(_current!.kind);
  bool _take(String kind) {
    if (_current?.kind == kind) {
      _index++;
      return true;
    }
    return false;
  }

  void _scan() {
    final bytes = utf8Bytes(text);
    var index = 0;
    while (index < bytes.length) {
      final unit = bytes[index];
      if (unit == 32 || unit == 9 || unit == 10 || unit == 13) {
        index++;
        continue;
      }
      if (unit == 94 ||
          unit == 43 ||
          unit == 123 ||
          unit == 125 ||
          unit == 39) {
        throw SqlException(
            'fts5: syntax error near "${String.fromCharCode(unit)}"');
      }
      if (unit == 40) {
        _tokens.add(_Tok('lparen', '('));
        index++;
        continue;
      }
      if (unit == 41) {
        _tokens.add(_Tok('rparen', ')'));
        index++;
        continue;
      }
      if (unit == 42) {
        if (_tokens.isEmpty ||
            (_tokens.last.kind != 'word' && _tokens.last.kind != 'phrase')) {
          throw const SqlException('fts5: syntax error near "*"');
        }
        _tokens.last.prefix = true;
        index++;
        continue;
      }
      if (unit == 58) {
        _tokens.add(_Tok('colon', ':'));
        index++;
        continue;
      }
      if (unit == 44) {
        _tokens.add(_Tok('comma', ','));
        index++;
        continue;
      }
      if (unit == 45) {
        _tokens.add(_Tok('minus', '-'));
        index++;
        continue;
      }
      if (unit == 34) {
        final end = bytes.indexOf(34, index + 1);
        if (end < 0) throw const SqlException('fts5: syntax error');
        final slice = utf8.decode(bytes.sublist(index + 1, end));
        final tokens =
            tokenizer.tokenize(slice).map((token) => token.text).toList();
        _tokens.add(_Tok('phrase', slice, tokens: tokens));
        index = end + 1;
        continue;
      }
      final start = index;
      while (index < bytes.length && !_reserved(bytes[index])) {
        index++;
      }
      final word = utf8.decode(bytes.sublist(start, index));
      final lower = asciiLower(word);
      if (lower == 'and' ||
          lower == 'or' ||
          lower == 'not' ||
          lower == 'near') {
        _tokens.add(_Tok(lower, word));
      } else {
        _tokens.add(_Tok('word', word));
      }
    }
    if (_tokens.isEmpty) throw const SqlException('fts5: syntax error');
  }

  bool _reserved(int unit) =>
      unit == 32 ||
      unit == 9 ||
      unit == 10 ||
      unit == 13 ||
      unit == 40 ||
      unit == 41 ||
      unit == 42 ||
      unit == 58 ||
      unit == 44 ||
      unit == 34 ||
      unit == 45 ||
      unit == 94 ||
      unit == 43 ||
      unit == 123 ||
      unit == 125 ||
      unit == 39;
}

final class _Tok {
  _Tok(this.kind, this.text, {this.tokens = const []});
  final String kind;
  final String text;
  final List<String> tokens;
  var prefix = false;
}

final class FtsBm25 {
  FtsBm25(this.phrases, this.idf, this.average);
  final List<FtsLeaf> phrases;
  final List<double> idf;
  final double average;

  static FtsBm25 build(
      FtsQuery query, List<FtsDocument> documents, int? column) {
    final phrases = query.phrases;
    final hits = List<int>.filled(phrases.length, 0);
    var tokens = 0;
    for (final document in documents) {
      tokens += document.tokenCount;
      for (var i = 0; i < phrases.length; i++) {
        if (phrases[i].matches(document, column)) hits[i]++;
      }
    }
    final rows = documents.length;
    final average = rows == 0 ? 0.0 : tokens / rows;
    final idf = [
      for (final hit in hits)
        () {
          if (rows == 0) return 1e-6;
          final value = math.log((rows - hit + 0.5) / (hit + 0.5));
          return value <= 0 ? 1e-6 : value;
        }()
    ];
    return FtsBm25(phrases, idf, average);
  }

  double score(
      FtsDocument document, List<FtsInst> instances, List<double> weights) {
    if (phrases.isEmpty || average == 0 && document.tokenCount == 0) {
      return phrases.isEmpty ? 0 : -1e-6 * 0;
    }
    final frequency = List<double>.filled(phrases.length, 0);
    for (final inst in instances) {
      final weight = inst.column < weights.length ? weights[inst.column] : 1.0;
      frequency[inst.phrase] += weight;
    }
    final length = document.tokenCount.toDouble();
    var total = 0.0;
    const k1 = 1.2;
    const b = 0.75;
    final denominatorBase = average == 0 ? 0.0 : b * length / average;
    for (var i = 0; i < phrases.length; i++) {
      final freq = frequency[i];
      total += idf[i] *
          ((freq * (k1 + 1)) / (freq + k1 * (1 - b + denominatorBase)));
    }
    return -total;
  }
}

String ftsHighlight(String? text, List<FtsToken> tokens,
    List<FtsInst> instances, int column, String open, String close) {
  if (text == null) return '';
  final ranges = _ranges(instances, column);
  final buffer = StringBuffer();
  var copied = 0;
  var openMark = false;
  var range = 0;
  for (var position = 0; position < tokens.length; position++) {
    final token = tokens[position];
    final start = range < ranges.length ? ranges[range].$1 : -1;
    final end = range < ranges.length ? ranges[range].$2 : -1;
    if (openMark && (position <= start || start < 0) && token.start > copied) {
      buffer.write(close);
      openMark = false;
    }
    if (position == start && !openMark) {
      buffer.write(text.substring(copied, _clip(text, token.start)));
      buffer.write(open);
      copied = _clip(text, token.start);
      openMark = true;
    }
    if (position == end) {
      if (!openMark) {
        buffer.write(open);
        openMark = true;
      }
      final tokenEnd = _clip(text, token.end);
      buffer.write(text.substring(copied, tokenEnd));
      copied = tokenEnd;
      range++;
      if (range < ranges.length && ranges[range].$1 <= position) {
        // A coalesced range was already consumed.
      }
    }
  }
  if (openMark) buffer.write(close);
  buffer.write(text.substring(copied));
  return buffer.toString();
}

int _clip(String text, int byteOffset) {
  final bytes = utf8Bytes(text);
  if (byteOffset >= bytes.length) return text.length;
  var index = 0, unit = 0;
  while (index < bytes.length && index < byteOffset) {
    final code = _peek(bytes, index)!;
    index += code.$2;
    unit += code.$1 > 0xFFFF ? 2 : 1;
  }
  return unit;
}

List<(int, int)> _ranges(List<FtsInst> instances, int column) {
  final relevant = instances.where((inst) => inst.column == column).toList()
    ..sort((a, b) => a.offset.compareTo(b.offset));
  final ranges = <(int, int)>[];
  for (final inst in relevant) {
    final end = inst.offset + inst.size - 1;
    if (ranges.isEmpty || inst.offset > ranges.last.$2) {
      ranges.add((inst.offset, end));
    } else if (end > ranges.last.$2) {
      ranges[ranges.length - 1] = (ranges.last.$1, end);
    }
  }
  return ranges;
}

String ftsSnippet(FtsDocument document, List<FtsInst> instances, int column,
    String open, String close, String ellipsis, int tokens) {
  if (tokens < 1) tokens = 1;
  final columns = column < 0
      ? [for (var i = 0; i < document.texts.length; i++) i]
      : [column];
  var bestColumn = columns.first;
  var bestStart = 0;
  var bestScore = -1;
  var bestSize = document.tokens[bestColumn].length;
  final phraseCount =
      instances.map((inst) => inst.phrase).fold<int>(0, math.max) +
          (instances.isEmpty ? 0 : 1);
  for (final index in columns) {
    final size = document.tokens[index].length;
    final sentences =
        _sentences(document.texts[index] ?? '', document.tokens[index]);
    final seen = <int, bool>{};
    for (final inst in instances.where((item) => item.column == index)) {
      final score = _snippetScore(instances, index, inst.offset, tokens, seen);
      if (score > bestScore) {
        bestScore = score;
        bestColumn = index;
        bestStart = _adjust(inst.offset, tokens, size, instances, index);
        bestSize = size;
      }
      for (var sentence = 0; sentence < sentences.length; sentence++) {
        final at = sentences[sentence];
        if (sentence + 1 < sentences.length &&
            sentences[sentence + 1] <= inst.offset) {
          continue;
        }
        if (at < inst.offset) {
          final sentenceScore =
              _snippetScore(instances, index, at, tokens, {}) +
                  (at == 0 ? 120 : 100);
          if (sentenceScore > bestScore) {
            bestScore = sentenceScore;
            bestColumn = index;
            bestStart = at;
            bestSize = size;
          }
        }
        break;
      }
    }
    if (phraseCount == 0 && bestScore < 0) bestSize = size;
  }
  final text = document.texts[bestColumn] ?? '';
  final source = document.tokens[bestColumn];
  final end = bestStart + tokens - 1;
  final shifted = [
    for (final inst in instances)
      if (inst.column == bestColumn &&
          inst.offset <= end &&
          inst.offset + inst.size - 1 >= bestStart)
        FtsInst(inst.phrase, 0, math.max(0, inst.offset - bestStart), inst.size)
  ];
  final body = ftsHighlight(
      text.isEmpty ? '' : _windowText(text, source, bestStart, end),
      _windowTokens(source, bestStart, end),
      shifted,
      0,
      open,
      close);
  final prefix = bestStart > 0 ? ellipsis : '';
  final suffix = end < bestSize - 1 ? ellipsis : '';
  return '$prefix$body$suffix';
}

String _windowText(String text, List<FtsToken> tokens, int start, int end) {
  if (tokens.isEmpty || start >= tokens.length) return '';
  final first = tokens[math.min(start, tokens.length - 1)];
  final last = tokens[math.min(end, tokens.length - 1)];
  return text.substring(_clip(text, first.start), _clip(text, last.end));
}

List<FtsToken> _windowTokens(List<FtsToken> tokens, int start, int end) {
  if (start >= tokens.length) return const [];
  final origin = tokens[start].start;
  return [
    for (var i = start; i < tokens.length && i <= end; i++)
      FtsToken(tokens[i].text, tokens[i].start - origin, tokens[i].end - origin)
  ];
}

int _snippetScore(List<FtsInst> instances, int column, int start, int tokens,
    Map<int, bool> seen) {
  var score = 0;
  final end = start + tokens;
  for (final inst in instances) {
    if (inst.column == column && inst.offset >= start && inst.offset < end) {
      score += (seen[inst.phrase] ?? false) ? 1 : 1000;
      seen[inst.phrase] = true;
    }
  }
  return score;
}

int _adjust(
    int offset, int tokens, int size, List<FtsInst> instances, int column) {
  var first = offset;
  var last = offset;
  for (final inst in instances) {
    if (inst.column == column &&
        inst.offset >= offset &&
        inst.offset < offset + tokens) {
      if (inst.offset < first) first = inst.offset;
      final end = inst.offset + inst.size;
      if (end > last) last = end;
    }
  }
  var adjusted = first - ((tokens - (last - first)) ~/ 2);
  if (adjusted + tokens > size) adjusted = size - tokens;
  if (adjusted < 0) adjusted = 0;
  return adjusted;
}

List<int> _sentences(String text, List<FtsToken> tokens) {
  final starts = <int>[0];
  final bytes = utf8Bytes(text);
  for (var i = 1; i < tokens.length; i++) {
    var cursor = tokens[i].start - 1;
    var marker = 0;
    var separated = false;
    while (cursor >= 0) {
      final unit = bytes[cursor];
      if (unit != 32 && unit != 9 && unit != 10 && unit != 13) {
        marker = unit;
        break;
      }
      separated = true;
      cursor--;
    }
    if (separated && (marker == 46 || marker == 58)) starts.add(i);
  }
  return starts;
}
