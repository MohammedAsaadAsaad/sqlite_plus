import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test(
      'rank preferences transfer to disjoint held-out queries/documents without changing control',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT,category TEXT)');
    final vectors = <String, List<double>>{};
    var id = 0;
    for (final category in ['milk', 'tea', 'juice', 'water']) {
      vectors[category] = category == 'water' ? [0, 1] : [1, 0];
      for (final suffix in ['infant', 'baby']) {
        final body = '$category $suffix';
        vectors[body] =
            category == 'water' || suffix == 'infant' ? [0, 1] : [1, 0];
        await db
            .execute('INSERT INTO docs VALUES (?,?,?)', [++id, body, category]);
      }
    }
    final search = await SqlitePlusSearch.open(
        database: db,
        embeddingProvider: FixtureEmbeddingProvider(
            modelId: 'held-out-synthetic-v1', dimensions: 2, vectors: vectors),
        learning: const AdaptiveLearningConfig(enabled: true));
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    Future<SearchResults> query(String text) => search.search(text,
        table: 'docs',
        mode: SearchMode.hybrid,
        filter: SearchFilter('category=?', [text]));
    Future<List<({double recall, double reciprocalRank, double ndcg})>>
        evaluate() async => [
              for (final entry in {'tea': '4', 'juice': '6'}.entries)
                evaluateRanking(
                    (await query(entry.key))
                        .hits
                        .map((h) => h.documentId)
                        .toList(),
                    {entry.value: 3})
            ];
    final before = await evaluate();
    final controlBefore =
        (await query('water')).hits.map((h) => h.documentId).toList();
    for (var i = 0; i < 8; i++) {
      final training = await query('milk');
      await search.feedback.submit(
          searchId: training.searchId,
          documentId: '1',
          relevance: Relevance.low);
      await search.feedback.submit(
          searchId: training.searchId,
          documentId: '2',
          relevance: Relevance.high);
    }
    final after = await evaluate();
    for (var i = 0; i < before.length; i++) {
      expect(before[i].reciprocalRank, 0.5);
      expect(after[i].reciprocalRank, 1);
      expect(after[i].ndcg, greaterThan(before[i].ndcg));
      expect(after[i].recall, before[i].recall);
    }
    expect((await query('water')).hits.map((h) => h.documentId), controlBefore);
    // These disjoint fixtures test feature-learning generalization only. They
    // are not a real embedding model or cross-language semantic evaluation.
  });
}
