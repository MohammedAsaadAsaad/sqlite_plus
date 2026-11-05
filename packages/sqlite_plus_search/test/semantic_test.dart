import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';
import 'package:test/test.dart';

// Synthetic vectors verify plumbing only; these are not real-model tests.
void main() {
  FixtureEmbeddingProvider fixture({String modelId = 'fixture-v1'}) =>
      FixtureEmbeddingProvider(
        modelId: modelId,
        dimensions: 2,
        vectors: {
          'milk': [1, 0],
          'tea': [0, 1],
          'water': [-1, 0],
          'query': [1, 0]
        },
      );
  test('exact local vector retrieval filters before top-k and persists',
      () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute(
        'CREATE TABLE docs(id INTEGER PRIMARY KEY, body TEXT, allowed INTEGER)');
    await db.execute(
        "INSERT INTO docs VALUES (1,'milk',0),(2,'tea',1),(3,'water',1)");
    final search =
        await SqlitePlusSearch.open(database: db, embeddingProvider: fixture());
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    final names = (await db.query('SELECT name FROM sqlite_schema'))
        .rows
        .map((row) => row.single)
        .toSet();
    expect(names, contains('_sps_1_vec'));
    expect(names.contains('_sps_1_vectors'), isFalse);
    final all =
        await search.search('query', table: 'docs', mode: SearchMode.semantic);
    expect(all.hits.map((hit) => hit.documentId), ['1', '2', '3']);
    final filtered = await search.search('query',
        table: 'docs',
        mode: SearchMode.semantic,
        limit: 1,
        filter: SearchFilter('allowed = ?', [1]));
    expect(filtered.hits.single.documentId, '2');
    expect(filtered.total, 2);
    final reopened = await MutableSqliteDatabase.fromImage(db.exportImage());
    addTearDown(reopened.close);
    final other = await SqlitePlusSearch.open(
        database: reopened, embeddingProvider: fixture());
    expect(
        (await other.search('query', table: 'docs', mode: SearchMode.semantic))
            .hits
            .first
            .score,
        1);
    final incompatible = await SqlitePlusSearch.open(
        database: reopened, embeddingProvider: fixture(modelId: 'changed'));
    await expectLater(
        incompatible.search('query', table: 'docs', mode: SearchMode.semantic),
        throwsStateError);
    await expectLater(
        other.search('unknown', table: 'docs', mode: SearchMode.semantic),
        throwsStateError);
  });

  test('provider failure rolls back complete rebuild', () async {
    final db = await openInMemory();
    addTearDown(db.close);
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY, body TEXT)');
    await db.execute("INSERT INTO docs VALUES (1,'milk')");
    final search =
        await SqlitePlusSearch.open(database: db, embeddingProvider: fixture());
    await search
        .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']);
    await db.execute("UPDATE docs SET body='unknown'");
    await expectLater(
        search
            .indexTable(table: 'docs', primaryKey: 'id', textColumns: ['body']),
        throwsStateError);
    expect(
        (await search.search('query', table: 'docs', mode: SearchMode.semantic))
            .hits
            .single
            .documentId,
        '1');
  });
}
