import 'dart:convert';

import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';

/// Pluggable lexical processing shared by index and query paths.
/// Implementations must have a stable versioned signature, including any
/// language rules, stemming and synonym dictionary revision. Never perform IO.
abstract class SearchAnalyzer {
  const SearchAnalyzer();
  String get signature;
  String normalize(String text);

  /// Treat input literally; override only for trusted, tested query processing.
  String matchExpression(String text) => normalize(text)
      .split(RegExp(r'\s+'))
      .where((term) => term.isNotEmpty)
      .map((term) => '"${term.replaceAll('"', '""')}"')
      .join(' OR ');
}

/// Normalizes text before sqlite_plus's Unicode-aware FTS5 tokenization.
///
/// All options must be identical at index and query time. Changing them requires
/// an explicit rebuild. This is lexical processing, not semantic understanding.
final class SearchTextAnalyzer extends SearchAnalyzer {
  const SearchTextAnalyzer({
    this.foldHamza = false,
    this.foldYa = true,
    this.stemArabic = false,
  });

  final bool foldHamza;
  final bool foldYa;

  /// Uses the existing Arabic light stemmer, including its fixed hamza/ya folds.
  /// When true those fixed folds override the corresponding options above.
  final bool stemArabic;

  /// Versioned representation suitable for persisted index metadata.
  @override
  String get signature => 'search-text-v1:$foldHamza:$foldYa:$stemArabic';

  @override
  String normalize(String text) {
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
    if (!stemArabic) return normalized;
    final stemmer = ArabicTokenizer(const []);
    // Apply only to Arabic runs; leave Greek, CJK, English, etc. to unicode61.
    return normalized.replaceAllMapped(
        RegExp(r'[\u0621-\u063a\u0641-\u064a\u0671]+'), (match) {
      final tokens = stemmer.tokenize(match[0]!);
      return tokens.map((token) => utf8.decode(token.text.codeUnits)).join(' ');
    });
  }
}
