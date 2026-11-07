/// Opt-in typo fallback when the filtered keyword result is empty.
///
/// Uses Unicode-code-point Levenshtein distance (no transpositions). Candidate
/// discovery scans derived text; it is not an indexed fuzzy-search algorithm.
final class FuzzySearchConfig {
  const FuzzySearchConfig({
    this.maxEdits = 1,
    this.minTokenLength = 4,
    this.maxExpansions = 16,
    this.learnAfter,
  });

  /// Successful first-page fallbacks before persisting reusable alternatives.
  /// Null disables learning and use of learned alternatives.
  final int? learnAfter;

  final int maxEdits;
  final int minTokenLength;

  /// Maximum alternatives per query token, sorted by distance then spelling.
  final int maxExpansions;

  void validate() {
    if ((learnAfter != null && learnAfter! < 1) ||
        maxEdits < 1 ||
        maxEdits > 2 ||
        minTokenLength < 1 ||
        maxExpansions < 1 ||
        maxExpansions > 64) {
      throw ArgumentError('Invalid fuzzy search configuration');
    }
  }
}

final _tokens = RegExp(r'[\p{L}\p{N}\p{M}\p{Co}]+', unicode: true);

/// Lexical candidates; FTS5 still performs final matching and BM25 ranking.
Iterable<String> fuzzyTerms(String text) =>
    _tokens.allMatches(text).map((match) => match.group(0)!);

String? fuzzyExpression(
    String query, Set<String> vocabulary, FuzzySearchConfig config) {
  return fuzzyGroupsExpression(fuzzyAlternatives(query, vocabulary, config));
}

Map<String, List<String>> fuzzyAlternatives(
    String query, Set<String> vocabulary, FuzzySearchConfig config) {
  final result = <String, List<String>>{};
  for (final term in fuzzyTerms(query).toSet()) {
    final expanded = <String>{term};
    final runes = term.runes.toList();
    if (runes.length >= config.minTokenLength) {
      final candidates = <MapEntry<String, int>>[];
      for (final candidate in vocabulary) {
        if (candidate == term) continue;
        final distance =
            _distance(runes, candidate.runes.toList(), config.maxEdits);
        if (distance <= config.maxEdits) {
          candidates.add(MapEntry(candidate, distance));
        }
      }
      candidates.sort((a, b) {
        final distance = a.value.compareTo(b.value);
        return distance != 0 ? distance : a.key.compareTo(b.key);
      });
      for (final candidate in candidates.take(config.maxExpansions)) {
        expanded.add(candidate.key);
      }
    }
    result[term] = expanded.toList();
  }
  return result;
}

String? fuzzyGroupsExpression(Map<String, List<String>> alternatives) {
  if (!alternatives.values.any((values) => values.length > 1)) return null;
  return alternatives.values
      .map((values) => '(${values.map(_quoteTerm).join(' OR ')})')
      .join(' AND ');
}

/// Fuzzy queries require every lexical token, even before expansion.
String fuzzyExactExpression(String query) =>
    fuzzyTerms(query).toSet().map(_quoteTerm).join(' AND ');

String _quoteTerm(String term) => '"${term.replaceAll('"', '""')}"';

int _distance(List<int> a, List<int> b, int limit) {
  if ((a.length - b.length).abs() > limit) return limit + 1;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, limit + 1);
    current[0] = i;
    var minimum = current[0];
    final start = i - limit > 1 ? i - limit : 1;
    final end = i + limit < b.length ? i + limit : b.length;
    for (var j = start; j <= end; j++) {
      var value = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1);
      if (previous[j] + 1 < value) value = previous[j] + 1;
      if (current[j - 1] + 1 < value) value = current[j - 1] + 1;
      current[j] = value;
      if (value < minimum) minimum = value;
    }
    if (minimum > limit) return limit + 1;
    previous = current;
  }
  return previous[b.length];
}
