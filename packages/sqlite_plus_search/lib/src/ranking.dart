/// Reciprocal Rank Fusion over complete, best-first rankings.
/// Missing documents contribute zero; repeated IDs in one ranking count once.
Map<String, double> reciprocalRankFusion(List<List<String>> rankings,
    {int rankConstant = 60}) {
  if (rankConstant < 1) throw ArgumentError('rankConstant must be positive');
  final scores = <String, double>{};
  for (final ranking in rankings) {
    final seen = <String>{};
    var rank = 0;
    for (final id in ranking) {
      if (!seen.add(id)) continue;
      rank++;
      scores[id] = (scores[id] ?? 0) + 1 / (rankConstant + rank);
    }
  }
  return Map.unmodifiable(scores);
}

/// Match precision, independent of the base BM25 score.
enum MatchQuality { exact, phrase, adjacent, allWords, corrected, partial }

/// Optional precision ordering for keyword searches. Defaults are quality,
/// weighted token coverage per field, BM25/feedback score, then document id.
/// Fields omitted from [fieldWeights] have weight 1. No index rebuild is needed.
final class SearchRankingPolicy {
  const SearchRankingPolicy({
    this.fieldWeights = const {},
    this.qualityOrder = const [
      MatchQuality.exact,
      MatchQuality.phrase,
      MatchQuality.adjacent,
      MatchQuality.allWords,
      MatchQuality.corrected,
      MatchQuality.partial,
    ],
  });

  final Map<String, double> fieldWeights;
  final List<MatchQuality> qualityOrder;

  void validate(List<String> indexedFields) {
    if (qualityOrder.length != MatchQuality.values.length ||
        qualityOrder.toSet().length != MatchQuality.values.length ||
        fieldWeights.entries.any((entry) =>
            !indexedFields.contains(entry.key) ||
            !entry.value.isFinite ||
            entry.value < 0)) {
      throw ArgumentError('Invalid search ranking policy');
    }
  }
}
