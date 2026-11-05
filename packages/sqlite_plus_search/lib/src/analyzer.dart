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

  /// Uses [ArabicText.normalize] with `stem: true`. The stemmer's fixed
  /// hamza and ya folds then apply to Arabic runs and override the options
  /// above. Greek, CJK, and other letters stay in the string.
  final bool stemArabic;

  /// Versioned representation suitable for persisted index metadata.
  @override
  String get signature => 'search-text-v1:$foldHamza:$foldYa:$stemArabic';

  @override
  String normalize(String text) => ArabicText.normalize(
        text,
        foldHamza: foldHamza,
        foldYa: foldYa,
        stem: stemArabic,
      );
}
