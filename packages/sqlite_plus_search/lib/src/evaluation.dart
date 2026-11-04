import 'dart:math' as math;

/// Single-query graded relevance evaluation. Aggregate metrics across held-out
/// queries in the application; training-set improvements are not generalization.
({double recall, double reciprocalRank, double ndcg}) evaluateRanking(
    List<String> ranking, Map<String, int> judgments,
    {int k = 10}) {
  if (k < 1 || judgments.values.any((grade) => grade < 0 || grade > 3)) {
    throw ArgumentError('Expected positive k and relevance grades in 0..3');
  }
  final unique = ranking.toSet().toList();
  final relevant =
      judgments.entries.where((e) => e.value > 0).map((e) => e.key).toSet();
  final top = unique.take(k).toList();
  final recalled = top.where(relevant.contains).length;
  final first = unique.indexWhere(relevant.contains);
  double dcg(List<int> grades) {
    var sum = 0.0;
    for (var i = 0; i < grades.length; i++) {
      sum += (math.pow(2, grades[i]) - 1) / (math.log(i + 2) / math.ln2);
    }
    return sum;
  }

  final ideal = judgments.values.toList()..sort((a, b) => b.compareTo(a));
  final best = dcg(ideal.take(k).toList());
  return (
    recall: relevant.isEmpty ? 0.0 : recalled / relevant.length,
    reciprocalRank: first < 0 ? 0.0 : 1 / (first + 1),
    ndcg: best == 0
        ? 0.0
        : dcg(top.map((id) => judgments[id] ?? 0).toList()) / best
  );
}
