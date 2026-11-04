import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test('RRF handles absent, duplicate and tied ranks', () {
    final scores = reciprocalRankFusion([
      ['a', 'b', 'a'],
      ['b', 'c']
    ]);
    expect(scores['a'], closeTo(1 / 61, 1e-12));
    expect(scores['b'], closeTo(1 / 62 + 1 / 61, 1e-12));
    expect(scores['c'], closeTo(1 / 62, 1e-12));
    expect(reciprocalRankFusion([]), isEmpty);
    expect(
        () => reciprocalRankFusion([], rankConstant: 0), throwsArgumentError);
  });

  test('hybrid fuses lexical and vector rankings with explanations and filters',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY, body TEXT, category TEXT)');
    await db.execute(
        "INSERT INTO docs VALUES (1,'milk','a'),(2,'tea','b'),(3,'milk milk','b')");
    final provider = FixtureEmbeddingProvider(
        modelId: 'hybrid-fixture-v1',
        dimensions: 2,
        vectors: {
          'milk': [1, 0],
          'tea': [0, 1],
          'milk milk': [0.5, 0.5]
        });
    final search =
        await SqlitePlusSearch.open(database: db, embeddingProvider: provider);
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    final result = await search.search('milk',
        table: 'docs', mode: SearchMode.hybrid, explain: true);
    expect(result.total, 3);
    expect(result.hits.last.documentId, '2');
    expect(
        result.hits.first.explanation!['baseScore'], result.hits.first.score);
    final filtered = await search.search('milk',
        table: 'docs',
        mode: SearchMode.hybrid,
        filter: SearchFilter('category=?', ['b']),
        limit: 1);
    expect(filtered.hits.single.documentId, '3');
    expect(filtered.hits.single.explanation, isNull);
    expect(
        (await search.search('milk',
                table: 'docs', mode: SearchMode.hybrid, offset: 1))
            .hits
            .map((h) => h.documentId),
        result.hits.skip(1).map((h) => h.documentId));
  });
}
