import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

void main() {
  late MutableSqliteDatabase db;
  late SqlitePlusSearch search;
  const fuzzy = FuzzySearchConfig();
  setUp(() async {
    db = await openInMemory();
    search = await SqlitePlusSearch.open(database: db);
    await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY, body TEXT, shelf TEXT)');
    await db.execute('INSERT INTO docs VALUES (1,?,?), (2,?,?), (3,?,?)',
        ['biscuit حَلِيب', 'a', 'biscuits حديقة', 'b', 'tea', 'a']);
    await search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true);
  });
  tearDown(() => db.close());

  Future<List<String>> find(String query,
          {FuzzySearchConfig? config = fuzzy}) async =>
      (await search.search(query, table: 'docs', fuzzy: config))
          .hits
          .map((hit) => hit.documentId)
          .toList();

  test('opt-in insertion deletion substitution and Arabic normalization',
      () async {
    expect(await find('biscut', config: null), isEmpty);
    for (final query in ['biscut', 'biscuuit', 'biscxit', 'حلييب']) {
      expect(await find(query), ['1']);
    }
    expect(await find('حَلِيب'), ['1']);
  });

  test('exact results stay unchanged and short tokens do not expand', () async {
    expect(await find('biscuit'), await find('biscuit', config: null));
    expect(await find('tex'), isEmpty);
    expect(
        await find('tex', config: const FuzzySearchConfig(minTokenLength: 3)),
        ['3']);
    expect(await find('zzzzzzzz'), isEmpty);
    expect(await find('   '), isEmpty);
    expect(await find('" OR *'), isEmpty);
  });

  test('distance bounds and deterministic expansion cap', () async {
    expect(await find('biscxxit'), isEmpty);
    expect(await find('biscxxit', config: const FuzzySearchConfig(maxEdits: 2)),
        ['1']);
    await db.execute("INSERT INTO docs VALUES (4,'biscut','a')");
    expect(
        await find('biscat', config: const FuzzySearchConfig(maxExpansions: 1)),
        ['4']);
  });

  test('filter precedes fallback decision, total and pagination', () async {
    final result = await search.search('biscuit',
        table: 'docs',
        fuzzy: fuzzy,
        filter: SearchFilter('shelf = ?', ['b']),
        limit: 1);
    expect(result.hits.single.documentId, '2');
    expect(result.total, 1);
    final next = await search.search('biscuit',
        table: 'docs',
        fuzzy: fuzzy,
        filter: SearchFilter('shelf = ?', ['b']),
        offset: 1);
    expect(next.hits, isEmpty);
    expect(next.total, 1);
  });

  test('updates deletes rollback and image reopen use current derived text',
      () async {
    await db.execute("UPDATE docs SET body='cracker' WHERE id=1");
    expect(await find('biscut'), isEmpty);
    expect(await find('crackr'), ['1']);
    await db.execute('BEGIN');
    await db.execute("UPDATE docs SET body='another' WHERE id=1");
    await db.execute('ROLLBACK');
    expect(await find('crackr'), ['1']);
    await search.verifyIndex(table: 'docs');
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    final other = await SqlitePlusSearch.open(database: reopened);
    expect(
        (await other.search('crackr', table: 'docs', fuzzy: fuzzy))
            .hits
            .single
            .documentId,
        '1');
    await db.execute('DELETE FROM docs WHERE id=1');
    expect(await find('crackr'), isEmpty);
  });

  test('hybrid preserves original embedding input and exposes keyword rank',
      () async {
    final hybrid = await SqlitePlusSearch.open(
        database: db,
        embeddingProvider: FixtureEmbeddingProvider(
            modelId: 'fuzzy-fixture',
            dimensions: 2,
            vectors: {
              'biscuit حَلِيب': [1, 0],
              'biscuits حديقة': [0, 1],
              'tea': [0, 1],
              'biscut': [1, 0],
            }));
    await hybrid
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    final result = await hybrid.search('biscut',
        table: 'docs', fuzzy: fuzzy, mode: SearchMode.hybrid, explain: true);
    expect(result.hits.first.documentId, '1');
    expect(result.hits.first.explanation!['keywordRank'], 1);
    expect(result.hits.first.explanation!['vectorRank'], 1);
  });

  test('Unicode code points and punctuation are lexical boundaries', () async {
    await db.execute("INSERT INTO docs VALUES (4,'𐐨𐐩𐐪𐐫 café','a')");
    expect(await find('𐐨𐐩𐐪𐐬'), ['4']);
    expect(await find('biscut!'), ['1']);
  });

  test('candidate discovery crosses page boundaries and detects invalid text',
      () async {
    final values = <String>[];
    final args = <Object?>[];
    for (var id = 4; id <= 520; id++) {
      values.add('(?,?,?)');
      args.addAll([id, id == 520 ? 'pineapple' : 'ordinary', 'a']);
    }
    await db.execute('INSERT INTO docs VALUES ${values.join(',')}', args);
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    expect(await find('pineappl'), ['520']);
    await db
        .execute("UPDATE _sps_1_keys SET body=x'0102' WHERE source_key='520'");
    await expectLater(find('pineappl'), throwsStateError);
    await expectLater(search.verifyIndex(table: 'docs'), throwsStateError);
  });

  test('all query words are required before and after typo expansion',
      () async {
    await db.execute(
        "INSERT INTO docs VALUES (4,'بسكويت جودة فانيليا','a'), (5,'سكر جودة ممتاز','a'), (6,'بسكويت شركة ثانية','a'), (7,'biscuit vanilla','a'), (8,'tea vanilla','a')");
    expect(await find('جودة بسكوت'), ['4']);
    expect(await find('بسكوت جودة'), ['4']);
    expect(await find('جودة بسكويت'), ['4']);
    expect(await find('biscut vanilla'), ['7']);
    expect(await find('zzzzzzzz vanilla'), isEmpty);
    // Existing non-fuzzy OR behavior is preserved.
    expect(await find('zzzzzzzz vanilla', config: null), ['7', '8']);
  });

  test('invalid settings and semantic-only mode fail explicitly', () async {
    for (final config in [
      const FuzzySearchConfig(maxEdits: 0),
      const FuzzySearchConfig(maxEdits: 3),
      const FuzzySearchConfig(minTokenLength: 0),
      const FuzzySearchConfig(maxExpansions: 0),
      const FuzzySearchConfig(maxExpansions: 65),
    ]) {
      await expectLater(find('biscut', config: config), throwsArgumentError);
    }
    await expectLater(
        search.search('biscut',
            table: 'docs', fuzzy: fuzzy, mode: SearchMode.semantic),
        throwsArgumentError);
  });
}
