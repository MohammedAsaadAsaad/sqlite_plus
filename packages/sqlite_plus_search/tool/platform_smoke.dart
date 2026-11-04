// Same assertions run on the Dart VM and compiled JavaScript/Node, without IO.
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final db = await openInMemory();
  final provider = FixtureEmbeddingProvider(
      modelId: 'platform-fixture-v1',
      dimensions: 2,
      vectors: {
        'حَلِيب milk': [1, 0],
        'شاي tea': [0, 1],
        '中文 Ελληνικά': [-1, 0],
        'حليب': [1, 0],
        'tea': [0, 1]
      });
  await db.execute(
      'CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT,category TEXT)');
  await db.execute('INSERT INTO docs VALUES (1,?,?), (2,?,?), (3,?,?)',
      ['حَلِيب milk', 'a', 'شاي tea', 'b', '中文 Ελληνικά', 'b']);
  final search = await SqlitePlusSearch.open(
      database: db,
      embeddingProvider: provider,
      learning: const AdaptiveLearningConfig(enabled: true));
  await search.indexTable(
      table: 'docs', primaryKey: 'id', textColumns: ['body'], autoUpdate: true);
  await search.verifyIndex(table: 'docs');
  check(
      (await search.search('حليب', table: 'docs')).hits.single.documentId ==
          '1',
      'Arabic normalization');
  check(
      (await search.search('MILK', table: 'docs')).hits.single.documentId ==
          '1',
      'English case fold');
  check(
      (await search.search('中文', table: 'docs')).hits.single.documentId == '3',
      'CJK lexical retrieval');
  check(
      (await search.search('Ελληνικά', table: 'docs')).hits.single.documentId ==
          '3',
      'Greek lexical retrieval');
  final filtered = await search.search('حليب',
      table: 'docs',
      mode: SearchMode.semantic,
      filter: SearchFilter('category=?', ['b']),
      limit: 1);
  check(filtered.hits.single.documentId == '2', 'Filter before vector top-k');
  final hybrid = await search.search('حليب',
      table: 'docs', mode: SearchMode.hybrid, explain: true);
  check(hybrid.hits.first.documentId == '1' && hybrid.total == 3,
      'Hybrid fusion');
  check(hybrid.hits.first.explanation!['vectorRank'] == 1, 'Explanation');
  await search.feedback.submit(
      searchId: hybrid.searchId, documentId: '1', relevance: Relevance.high);
  final model = await search.feedback.exportModel(table: 'docs');
  check((model['weights'] as List<double>)[0] > 0, 'Learning');
  await db.execute('BEGIN');
  await db.execute("DELETE FROM docs WHERE id=1");
  await db.execute('ROLLBACK');
  check((await search.search('milk', table: 'docs')).total == 1, 'Rollback');
  await db.execute('UPDATE docs SET body=? WHERE id=1', ['شاي tea']);
  await db.execute('DELETE FROM docs WHERE id=2');
  check((await search.search('milk', table: 'docs')).total == 0,
      'Incremental keyword update');
  check(
      (await search.search('tea', table: 'docs')).hits.single.documentId == '1',
      'Incremental delete');
  await search.verifyIndex(table: 'docs');
  final copy = await MutableSqliteDatabase.fromImage(db.exportImage());
  final reopened = await SqlitePlusSearch.open(
      database: copy,
      embeddingProvider: provider,
      learning: const AdaptiveLearningConfig(enabled: true));
  check(
      (await reopened.search('tea', table: 'docs', mode: SearchMode.hybrid))
              .hits
              .first
              .documentId ==
          '1',
      'Image round trip');
  check(
      (await reopened.feedback.exportModel(table: 'docs'))['weights']
              .toString() ==
          model['weights'].toString(),
      'Model persistence');
  await reopened.feedback.reset(table: 'docs');
  check(
      (await reopened.feedback.exportModel(table: 'docs'))['weights']
              .toString() ==
          [0.0, 0.0].toString(),
      'Model reset');
  await reopened.feedback.importModel(table: 'docs', model: model);
  check(
      (await reopened.feedback.exportModel(table: 'docs'))['weights']
              .toString() ==
          model['weights'].toString(),
      'Model import');
  await copy.close();
  await db.close();
  print('Platform search assertions passed (synthetic provider).');
}
