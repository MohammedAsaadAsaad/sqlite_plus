import 'dart:convert';

import 'package:sqlite_plus/sqlite_plus.dart';

/// The tokenizer name registered by [SqlitePlusArabic.register].
abstract final class ArabicTokenizers {
  /// Light Arabic stemmer for an FTS5 `tokenize` option.
  ///
  /// Diacritics and tatweel are removed. Alef variants fold to ا, alef
  /// maksura folds to ي, ئ folds to ي, and ؤ folds to و. One prefix is
  /// removed when at least three letters remain: وال، بال، كال، فال، لل، ال.
  /// One suffix is then removed on the same condition: يات، ون، ين، ات، ان،
  /// ها، ية، يه، ه، ة، ي. When the word starts with one of those prefixes and
  /// removing it would leave fewer than three letters, the suffix is kept as
  /// well, so `الله` stays `الله`. `حديقة` and `الحديقة` share a token. ASCII
  /// letters are lowercased and are not stemmed. This is not a morphological
  /// analyzer and it is not the SQLite ICU Arabic tokenizer.
  ///
  /// Each [FtsToken.text] uses one Dart code unit per UTF-8 byte of the stem,
  /// the same representation the built-in `unicode61` tokenizer stores in an
  /// FTS5 index.
  static const String arabic = 'arabic';
}

/// Registers [ArabicTokenizers.arabic] on one connection.
abstract final class SqlitePlusArabic {
  /// [database] is a [SqliteDatabase], a [MutableSqliteDatabase], or the
  /// connection's [SqlFunctionRegistry]. A later call replaces the factory.
  ///
  /// Register it before creating or querying a table that uses
  /// `tokenize = 'arabic'`.
  static void register(Object database) {
    _functions(database).tokenizers.register(
          ArabicTokenizers.arabic,
          ArabicTokenizer.new,
        );
  }
}

SqlFunctionRegistry _functions(Object database) {
  if (database is SqliteDatabase) return database.functions;
  if (database is MutableSqliteDatabase) return database.functions;
  if (database is SqlFunctionRegistry) return database;
  throw ArgumentError('Expected a sqlite_plus database');
}

/// FTS5 tokenizer named [ArabicTokenizers.arabic]. It takes no options.
final class ArabicTokenizer extends FtsTokenizer {
  /// Rejects every option. The stemmer rules are fixed.
  ArabicTokenizer(List<String> options) {
    if (options.isNotEmpty) {
      throw const SqlException('error in tokenizer constructor');
    }
  }

  @override
  String get name => ArabicTokenizers.arabic;

  @override
  List<FtsToken> tokenize(String text) {
    final tokens = <FtsToken>[];
    final units = text.runes.toList();
    var byte = 0;
    final bytes = <int>[];
    for (final rune in units) {
      bytes.add(byte);
      byte += _utf8Width(rune);
    }
    var index = 0;
    while (index < units.length) {
      while (index < units.length && !_tokenRune(units[index])) {
        index++;
      }
      if (index == units.length) break;
      final start = index;
      var arabic = false;
      var letter = false;
      while (index < units.length && _tokenRune(units[index])) {
        final rune = units[index];
        if (_arabicLetter(rune)) arabic = true;
        if (_arabicLetter(rune) || _asciiWord(rune)) letter = true;
        index++;
      }
      if (!letter) continue;
      final normalized = StringBuffer();
      for (var cursor = start; cursor < index; cursor++) {
        normalized.write(_fold(units[cursor]));
      }
      final stem =
          arabic ? _stem(normalized.toString()) : normalized.toString();
      if (stem.isEmpty) continue;
      final endByte = index == units.length ? byte : bytes[index];
      tokens.add(FtsToken(
          String.fromCharCodes(utf8.encode(stem)), bytes[start], endByte));
    }
    return tokens;
  }
}

const _prefixes = ['وال', 'بال', 'كال', 'فال', 'لل', 'ال'];
const _suffixes = [
  'يات',
  'ون',
  'ين',
  'ات',
  'ان',
  'ها',
  'ية',
  'يه',
  'ه',
  'ة',
  'ي'
];

String _stem(String token) {
  var text = token;
  var keepSuffix = false;
  for (final prefix in _prefixes) {
    if (!text.startsWith(prefix)) continue;
    if (text.length - prefix.length >= 3) {
      text = text.substring(prefix.length);
    } else {
      keepSuffix = true;
    }
    break;
  }
  if (!keepSuffix) {
    for (final suffix in _suffixes) {
      if (text.endsWith(suffix) && text.length - suffix.length >= 3) {
        text = text.substring(0, text.length - suffix.length);
        break;
      }
    }
  }
  return text;
}

String _fold(int rune) {
  if (rune >= 65 && rune <= 90) return String.fromCharCode(rune + 32);
  if (_ignored(rune)) return '';
  const folded = <int, int>{
    0x0622: 0x0627,
    0x0623: 0x0627,
    0x0625: 0x0627,
    0x0671: 0x0627,
    0x0649: 0x064A,
    0x0624: 0x0648,
    0x0626: 0x064A,
  };
  return String.fromCharCode(folded[rune] ?? rune);
}

bool _ignored(int rune) =>
    rune == 0x0640 ||
    (rune >= 0x064B && rune <= 0x0652) ||
    (rune >= 0x0653 && rune <= 0x0655) ||
    rune == 0x0670;

bool _arabicLetter(int rune) =>
    (rune >= 0x0621 && rune <= 0x063A) ||
    (rune >= 0x0641 && rune <= 0x064A) ||
    rune == 0x0671;

bool _asciiWord(int rune) =>
    (rune >= 48 && rune <= 57) ||
    (rune >= 65 && rune <= 90) ||
    (rune >= 97 && rune <= 122);

bool _tokenRune(int rune) =>
    _arabicLetter(rune) || _asciiWord(rune) || _ignored(rune);

int _utf8Width(int rune) {
  if (rune <= 0x7F) return 1;
  if (rune <= 0x7FF) return 2;
  if (rune <= 0xFFFF) return 3;
  return 4;
}
