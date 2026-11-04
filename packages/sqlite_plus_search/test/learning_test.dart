import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  test('learning validation, disabled feedback and bounded model imports',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    for (final rate in [0.0, -1.0, 0.6, double.nan]) {
      await expectLater(
          SqlitePlusSearch.open(
              database: db,
              learning: AdaptiveLearningConfig(learningRate: rate)),
          throwsArgumentError);
    }
    final search = await SqlitePlusSearch.open(database: db);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    await db.execute("INSERT INTO docs VALUES (1,'milk')");
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    final result = await search.search('milk', table: 'docs');
    await expectLater(
        search.feedback.submit(
            searchId: result.searchId,
            documentId: '1',
            relevance: Relevance.high),
        throwsStateError);
    final model = await search.feedback.exportModel(table: 'docs');
    await expectLater(
        search.feedback.importModel(table: 'docs', model: {
          ...model,
          'weights': [1.001, 0]
        }),
        throwsArgumentError);
    await search.feedback.importModel(table: 'docs', model: {
      ...model,
      'weights': [-1, 1]
    });
    expect((await search.feedback.exportModel(table: 'docs'))['weights'],
        [-1.0, 1.0]);
  });

  test('feedback changes ranks, persists, resets and isolates collections',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    await db
        .execute("INSERT INTO docs VALUES (1,'milk milk'),(2,'milk extra')");
    await db.execute('CREATE TABLE other(id INTEGER PRIMARY KEY,body TEXT)');
    await db
        .execute("INSERT INTO other VALUES (1,'milk milk'),(2,'milk extra')");
    final provider = FixtureEmbeddingProvider(
        modelId: 'learn-fixture',
        dimensions: 2,
        vectors: {
          'milk milk': [0, 1],
          'milk extra': [1, 0],
          'milk': [1, 0],
          'tea': [1, 0],
          'query': [1, 0]
        });
    final search = await SqlitePlusSearch.open(
        database: db,
        embeddingProvider: provider,
        learning: const AdaptiveLearningConfig(enabled: true));
    for (final table in ['docs', 'other']) {
      await search
          .indexTable(table: table, primaryKey: 'id', textColumns: ['body']);
    }
    // milk has lexical rank 1, but vector rank 2; tea has no lexical match.
    final before =
        await search.search('milk', table: 'docs', mode: SearchMode.hybrid);
    for (var i = 0; i < 30; i++) {
      final result =
          await search.search('milk', table: 'docs', mode: SearchMode.hybrid);
      await search.feedback.submit(
          searchId: result.searchId, documentId: '1', relevance: Relevance.low);
      await search.feedback.submit(
          searchId: result.searchId,
          documentId: '2',
          relevance: Relevance.high);
    }
    final model = await search.feedback.exportModel(table: 'docs');
    expect(model['weights'], isNot([0.0, 0.0]));
    expect((await search.feedback.exportModel(table: 'other'))['weights'],
        [0.0, 0.0]);
    final after =
        await search.search('milk', table: 'docs', mode: SearchMode.hybrid);
    expect(before.hits.first.documentId, '1');
    expect(after.hits.first.documentId, '2');
    final beforeMetrics = evaluateRanking(
        before.hits.map((h) => h.documentId).toList(), {'2': 3});
    final afterMetrics =
        evaluateRanking(after.hits.map((h) => h.documentId).toList(), {'2': 3});
    expect(
        afterMetrics.reciprocalRank, greaterThan(beforeMetrics.reciprocalRank));
    expect(afterMetrics.ndcg, greaterThan(beforeMetrics.ndcg));
    expect(afterMetrics.recall, 1);
    await expectLater(
        search.feedback.submit(
            searchId: after.searchId,
            documentId: 'unknown',
            relevance: Relevance.high),
        throwsStateError);
    await search.feedback.submit(
        searchId: after.searchId, documentId: '1', relevance: Relevance.low);
    await expectLater(
        search.feedback.submit(
            searchId: after.searchId,
            documentId: '1',
            relevance: Relevance.low),
        throwsStateError);
    final saved = await search.feedback.exportModel(table: 'docs');
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    final other = await SqlitePlusSearch.open(
        database: reopened,
        embeddingProvider: provider,
        learning: const AdaptiveLearningConfig(enabled: true));
    expect(await other.feedback.exportModel(table: 'docs'), saved);
    await other.feedback.reset(table: 'docs');
    expect((await other.feedback.exportModel(table: 'docs'))['weights'],
        [0.0, 0.0]);
    await other.feedback.importModel(table: 'docs', model: saved);
    expect(await other.feedback.exportModel(table: 'docs'), saved);
    await expectLater(other.feedback.importModel(table: 'other', model: saved),
        throwsArgumentError);
    await expectLater(
        other.feedback.importModel(table: 'docs', model: {
          ...saved,
          'weights': [double.nan, 0]
        }),
        throwsArgumentError);
    await expectLater(
        other.feedback
            .importModel(table: 'docs', model: {...saved, 'version': 2}),
        throwsArgumentError);
    expect(await other.feedback.exportModel(table: 'docs'), saved);
  });
}
