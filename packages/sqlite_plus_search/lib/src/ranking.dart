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
