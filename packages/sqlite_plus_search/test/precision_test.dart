import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  late SqlitePlusSearch search;
  const policy = SearchRankingPolicy();
  setUp(() async {
    db = await openInMemory();
    search = await SqlitePlusSearch.open(database: db);
    await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY,title TEXT,body TEXT)');
  });
  tearDown(() => db.close());
  Future<void> index() => search.indexTable(
      table: 'docs',
      primaryKey: 'id',
      textColumns: ['title', 'body'],
      autoUpdate: true);

  test(
      'exact phrase adjacent scattered and partial precedence before pagination',
      () async {
    await db.execute(
        "INSERT INTO docs VALUES (1,'red fresh apple',NULL),(2,'apple red',NULL),(3,'best red apple now',NULL),(4,'red apple',NULL),(5,'red',NULL)");
    await index();
    final baseline = await search.search('red apple', table: 'docs');
    expect(baseline.hits.every((h) => h.matchQuality == null), true);
    final result = await search.search('red apple',
        table: 'docs', ranking: policy, explain: true);
    expect(result.hits.map((h) => h.documentId), ['4', '3', '2', '1', '5']);
    expect(result.hits.map((h) => h.matchQuality), [
      MatchQuality.exact,
      MatchQuality.phrase,
      MatchQuality.adjacent,
      MatchQuality.allWords,
      MatchQuality.partial
    ]);
    expect(result.hits.first.explanation!['matchTier'], 0);
    final page = await search.search('red apple',
        table: 'docs', ranking: policy, limit: 2, offset: 2);
    expect(page.total, 5);
    expect(page.hits.map((h) => h.documentId), ['2', '1']);
  });

  test('field weights change ties and phrase never crosses fields', () async {
    await db.execute(
        "INSERT INTO docs VALUES (1,'other','red apple'),(2,'red apple','other'),(3,'red','apple')");
    await index();
    final result = await search.search('red apple',
        table: 'docs',
        ranking:
            const SearchRankingPolicy(fieldWeights: {'title': 4, 'body': 1}));
    expect(result.hits.map((h) => h.documentId), ['2', '1', '3']);
    expect(result.hits.last.matchQuality, MatchQuality.allWords);
    expect(result.hits.first.fieldScore, 4);
    final swapped = await search.search('red apple',
        table: 'docs',
        ranking:
            const SearchRankingPolicy(fieldWeights: {'title': 1, 'body': 4}));
    expect(swapped.hits.first.documentId, '1');
  });

  test('custom precedence filters and invalid policies', () async {
    await db.execute(
        "INSERT INTO docs VALUES (1,'red apple',NULL),(2,'apple red',NULL)");
    await index();
    const custom = SearchRankingPolicy(qualityOrder: [
      MatchQuality.adjacent,
      MatchQuality.exact,
      MatchQuality.phrase,
      MatchQuality.allWords,
      MatchQuality.corrected,
      MatchQuality.partial
    ]);
    expect(
        (await search.search('red apple', table: 'docs', ranking: custom))
            .hits
            .first
            .documentId,
        '2');
    final filtered = await search.search('red apple',
        table: 'docs', ranking: policy, filter: SearchFilter('id=?', [2]));
    expect(filtered.hits.single.documentId, '2');
    for (final p in [
      const SearchRankingPolicy(fieldWeights: {'missing': 1}),
      const SearchRankingPolicy(fieldWeights: {'title': -1}),
      const SearchRankingPolicy(qualityOrder: [])
    ]) {
      await expectLater(
          search.search('red', table: 'docs', ranking: p), throwsArgumentError);
    }
    await expectLater(
        search.search('red',
            table: 'docs', ranking: policy, mode: SearchMode.hybrid),
        throwsArgumentError);
  });

  test(
      'Unicode tokenizer agrees with FTS; changes and image reopen preserve ranking',
      () async {
    await db.execute(
        "INSERT INTO docs VALUES (1,'Café',NULL),(2,'red, apple!',NULL),(3,'حَلِيب',NULL)");
    await index();
    for (final q in ['cafe', 'red apple', 'حليب']) {
      expect(
          (await search.search(q, table: 'docs', ranking: policy))
              .hits
              .first
              .matchQuality,
          MatchQuality.exact);
    }
    await db.execute("UPDATE docs SET title='fresh red apple' WHERE id=2");
    expect(
        (await search.search('red apple', table: 'docs', ranking: policy))
            .hits
            .first
            .matchQuality,
        MatchQuality.phrase);
    final copy = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(copy.close);
    final other = await SqlitePlusSearch.open(database: copy);
    expect(
        (await other.search('red apple', table: 'docs', ranking: policy))
            .hits
            .first
            .matchQuality,
        MatchQuality.phrase);
  });

  test('single-field derived text is not normalized twice and follows edits',
      () async {
    await db.execute("INSERT INTO docs VALUES (1,'x',NULL)");
    final custom = await SqlitePlusSearch.open(
        database: db, analyzer: const _ExpandAnalyzer());
    await custom.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['title'],
        autoUpdate: true);
    expect(
        (await custom.search('x', table: 'docs', ranking: policy))
            .hits
            .single
            .matchQuality,
        MatchQuality.exact);
    await db.execute("UPDATE docs SET title='fresh x' WHERE id=1");
    expect(
        (await custom.search('x', table: 'docs', ranking: policy))
            .hits
            .single
            .matchQuality,
        MatchQuality.phrase);
  });

  test('corrected results and learned alternatives use weighted fields',
      () async {
    await db.execute(
        "INSERT INTO docs VALUES (1,'بسكويت جودة',NULL),(2,'other','بسكويت جودة')");
    await index();
    const fuzzy = FuzzySearchConfig(learnAfter: 1);
    const weighted = SearchRankingPolicy(fieldWeights: {'title': 4});
    for (var i = 0; i < 2; i++) {
      final result = await search.search('بسكوت جودة',
          table: 'docs', fuzzy: fuzzy, ranking: weighted);
      expect(result.hits.first.documentId, '1');
      expect(result.hits.every((h) => h.matchQuality == MatchQuality.corrected),
          true);
      expect(result.fuzzyCacheUsed, i == 1);
    }
  });
}

class _ExpandAnalyzer extends SearchAnalyzer {
  const _ExpandAnalyzer();
  @override
  String get signature => 'expand-x-v1';
  @override
  String normalize(String text) => text.replaceAll('x', 'xx');
}
