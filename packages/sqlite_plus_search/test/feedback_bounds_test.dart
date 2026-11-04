import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test(
      '1001 returned hits retain 1000 label contexts; oldest expires and reset invalidates the rest',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    await db.execute(
        'INSERT INTO docs VALUES ${List.filled(1001, '(?,?)').join(',')}', [
      for (var i = 1; i <= 1001; i++) ...[i, 'milk']
    ]);
    final search = await SqlitePlusSearch.open(
        database: db, learning: const AdaptiveLearningConfig(enabled: true));
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    final results = await search.search('milk', table: 'docs', limit: 1001);
    expect(results.hits.length, 1001);
    expect(
        (await db.query('SELECT count(*) FROM _sps_feedback'))
            .rows
            .single
            .single,
        BigInt.from(1000));
    await expectLater(
        search.feedback.submit(
            searchId: results.searchId,
            documentId: results.hits.first.documentId,
            relevance: Relevance.high),
        throwsStateError);
    await search.feedback.submit(
        searchId: results.searchId,
        documentId: results.hits.last.documentId,
        relevance: Relevance.high);
    await search.feedback.reset(table: 'docs');
    await expectLater(
        search.feedback.submit(
            searchId: results.searchId,
            documentId: results.hits[1].documentId,
            relevance: Relevance.high),
        throwsStateError);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
      'repeated explicit labels cannot exceed persisted weight and score influence bounds',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    await db
        .execute("INSERT INTO docs VALUES (1,'milk milk'),(2,'milk extra')");
    final search = await SqlitePlusSearch.open(
        database: db,
        learning: const AdaptiveLearningConfig(enabled: true),
        embeddingProvider: FixtureEmbeddingProvider(
            modelId: 'bounded-fixture-v1',
            dimensions: 2,
            vectors: {
              'milk milk': [0, 1],
              'milk extra': [1, 0],
              'milk': [1, 0]
            }));
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    for (var step = 0; step < 35; step++) {
      final result =
          await search.search('milk', table: 'docs', mode: SearchMode.hybrid);
      await search.feedback.submit(
          searchId: result.searchId, documentId: '1', relevance: Relevance.low);
      await search.feedback.submit(
          searchId: result.searchId,
          documentId: '2',
          relevance: Relevance.high);
    }
    final weights = (await search.feedback
        .exportModel(table: 'docs'))['weights'] as List<double>;
    expect(weights.every((w) => w.isFinite && w.abs() <= 1), isTrue);
    final result = await search.search('milk',
        table: 'docs', mode: SearchMode.hybrid, explain: true);
    final maximumBase = result.hits
        .map((h) => h.explanation!['baseScore']!.abs())
        .reduce((a, b) => a > b ? a : b);
    for (final hit in result.hits) {
      expect((hit.score - hit.explanation!['baseScore']!).abs(),
          lessThanOrEqualTo(maximumBase * 0.5 + 1e-12));
    }
  });
}
