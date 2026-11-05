import 'dart:convert';

import 'arabic_tokenizer.dart';

final _stemmer = ArabicTokenizer(const []);
final _arabicRun = RegExp(r'[\u0621-\u063a\u0641-\u064a\u0671]+');

/// Lexical Arabic folding for text that is later tokenized by another scanner.
///
/// This is not [ArabicTokenizer] and it is not an FTS5 `tokenize` option.
/// The FTS tokenizer only recognizes Arabic and ASCII, so Greek, CJK, and
/// other letters would disappear if a mixed string were stemmed that way.
/// [normalize] keeps those letters and, when [stem] is true, runs the light
/// stemmer on Arabic runs only.
///
/// Diacritics in U+064B–U+065F and U+06D6–U+06ED, tatweel, and the Quranic
/// sukun U+0670 are removed. Alef variants fold to ا. Arabic-Indic and
/// Extended Arabic-Indic digits fold to ASCII. [foldYa] maps ى to ي.
/// [foldHamza] maps ؤ to و and ئ to ي. With [stem], the stemmer's fixed folds
/// still apply to each Arabic run, including ya and hamza.
///
/// This is not the SQLite ICU Arabic tokenizer and it is not a morphological
/// analyzer.
abstract final class ArabicText {
  /// Folds [text]. ASCII letters are lowercased. An empty string stays empty.
  static String normalize(
    String text, {
    bool foldHamza = false,
    bool foldYa = true,
    bool stem = false,
  }) {
    final output = StringBuffer();
    for (var rune in text.toLowerCase().runes) {
      if (rune == 0x640 ||
          (rune >= 0x64b && rune <= 0x65f) ||
          rune == 0x670 ||
          (rune >= 0x6d6 && rune <= 0x6ed)) {
        continue;
      }
      if (const {0x622, 0x623, 0x625, 0x671}.contains(rune)) rune = 0x627;
      if (foldYa && rune == 0x649) rune = 0x64a;
      if (foldHamza && rune == 0x624) rune = 0x648;
      if (foldHamza && rune == 0x626) rune = 0x64a;
      if (rune >= 0x660 && rune <= 0x669) rune = rune - 0x660 + 48;
      if (rune >= 0x6f0 && rune <= 0x6f9) rune = rune - 0x6f0 + 48;
      output.writeCharCode(rune);
    }
    final normalized = output.toString();
    if (!stem) return normalized;
    return normalized.replaceAllMapped(_arabicRun, (match) {
      final tokens = _stemmer.tokenize(match[0]!);
      return tokens.map((token) => utf8.decode(token.text.codeUnits)).join(' ');
    });
  }
}
