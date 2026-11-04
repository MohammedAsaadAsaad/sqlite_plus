import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

Future<void> main() async {
  final db = await openInMemory();
  try {
    await db
        .execute('CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT)');
    await db.execute('INSERT INTO products VALUES (?, ?)', [1, 'حَلِيب milk']);
    // Plumbing demonstration only: supply a real, already provisioned local
    // embedding model for production semantic retrieval.
    final fixture = FixtureEmbeddingProvider(
        modelId: 'example-fixture-v1',
        dimensions: 2,
        vectors: {
          'حَلِيب milk': [1, 0],
          'حليب': [1, 0],
          'tea': [0, 1]
        });
    final search = await SqlitePlusSearch.open(
        database: db,
        embeddingProvider: fixture,
        learning: const AdaptiveLearningConfig(enabled: true));
    await search.indexTable(
        table: 'products',
        primaryKey: 'id',
        textColumns: ['name'],
        autoUpdate: true);
    final results =
        await search.search('حليب', table: 'products', mode: SearchMode.hybrid);
    print('Arabic hybrid fixture match: ${results.hits.single.documentId}');
    await search.feedback.submit(
        searchId: results.searchId, documentId: '1', relevance: Relevance.high);
    await db.execute('INSERT INTO products VALUES (?, ?)', [2, 'tea']);
    print(
        'Automatically indexed: ${(await search.search('tea', table: 'products')).hits.single.documentId}');
    print('Production local semantic model integration is pending.');
  } finally {
    await db.close();
  }
}
