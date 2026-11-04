import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test('Recall@10, MRR and NDCG@10 have known evaluation fixtures', () {
    final fixtures =
        jsonDecode(File('test/fixtures/relevance.json').readAsStringSync())
            as List;
    for (final fixture in fixtures.cast<Map<String, dynamic>>()) {
      final metrics = evaluateRanking(
          (fixture['ranking'] as List).cast<String>(),
          (fixture['judgments'] as Map).cast<String, int>());
      expect(metrics.recall, closeTo(fixture['recall'] as num, 1e-12));
      expect(metrics.reciprocalRank, closeTo(fixture['mrr'] as num, 1e-12));
      expect(metrics.ndcg, closeTo(fixture['ndcg'] as num, 1e-12));
    }
    expect(evaluateRanking(['a', 'a'], {'a': 3}).recall, 1);
    expect(evaluateRanking([], {}).ndcg, 0);
    expect(() => evaluateRanking([], {'a': 4}), throwsArgumentError);
    expect(() => evaluateRanking([], {}, k: 0), throwsArgumentError);
  });
}
