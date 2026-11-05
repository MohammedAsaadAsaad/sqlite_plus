import 'dart:convert';
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

// Development-only IO harness. No real-model performance claims.
Future<void> main(List<String> args) async {
  final count = args.isEmpty ? 1000 : int.parse(args.single);
  if (![1000, 10000, 100000, 1000000].contains(count)) {
    throw ArgumentError('Use 1000, 10000, 100000 or 1000000 records');
  }
  final db = await openInMemory();
  const document = 'milk baby حليب';
  final model = FixtureEmbeddingProvider(
      modelId: 'benchmark-fixture-v1',
      dimensions: 2,
      vectors: {
        document: [1, 0],
        'milk': [1, 0],
        'tea': [0, 1]
      });
  final search = await SqlitePlusSearch.open(
      database: db,
      embeddingProvider: model,
      learning: const AdaptiveLearningConfig(enabled: true));
  try {
    await db.execute('CREATE TABLE docs(id INTEGER PRIMARY KEY,body TEXT)');
    await db.execute('BEGIN');
    for (var start = 0; start < count; start += 1000) {
      final values = <String>[];
      final params = <Object?>[];
      for (var i = start; i < start + 1000 && i < count; i++) {
        values.add('(?,?)');
        params.addAll([i + 1, document]);
      }
      await db.execute('INSERT INTO docs VALUES ${values.join(',')}', params);
    }
    await db.execute('COMMIT');
    stderr.writeln('source_ready records=$count');
    Map<String, int> memory() => {
          'rss_bytes': ProcessInfo.currentRss,
          'peak_rss_bytes': ProcessInfo.maxRss,
        };
    final afterSource = memory();
    Future<int> measure(Future<void> Function() run) async {
      final watch = Stopwatch()..start();
      await run();
      watch.stop();
      return watch.elapsedMicroseconds;
    }

    final indexing = await measure(() => search.indexTable(
        table: 'docs',
        primaryKey: 'id',
        textColumns: ['body'],
        autoUpdate: true));
    stderr.writeln('index_ready records=$count');
    final afterIndex = memory();
    final imageAfterIndex = db.exportImage().length;
    final coldKeyword = await measure(() async {
      await search.search('milk', table: 'docs');
    });
    final coldHybrid = await measure(() async {
      await search.search('milk', table: 'docs', mode: SearchMode.hybrid);
    });
    final coldSemantic = await measure(() async {
      await search.search('milk', table: 'docs', mode: SearchMode.semantic);
    });
    final keyword = <int>[], hybrid = <int>[], semantic = <int>[];
    for (var i = 0; i < 5; i++) {
      keyword.add(await measure(() async {
        await search.search('milk', table: 'docs');
      }));
      semantic.add(await measure(() async {
        await search.search('milk', table: 'docs', mode: SearchMode.semantic);
      }));
      hybrid.add(await measure(() async {
        await search.search('milk', table: 'docs', mode: SearchMode.hybrid);
      }));
    }
    final afterQueries = memory();
    final updateAndQuery = Stopwatch()..start();
    final sourceUpdate = await measure(() async {
      await db.execute("UPDATE docs SET body='tea' WHERE id=1");
    });
    final incrementalSync =
        await measure(() => search.synchronize(table: 'docs'));
    final afterSync = memory();
    final postUpdateQuery = await measure(() async {
      await search.search('tea', table: 'docs', mode: SearchMode.hybrid);
    });
    updateAndQuery.stop();
    final results =
        await search.search('tea', table: 'docs', mode: SearchMode.hybrid);
    if (results.hits.first.documentId != '1' || results.total != count) {
      throw StateError('Incorrect benchmark retrieval');
    }
    await search.verifyIndex(table: 'docs');
    final feedback = await measure(() => search.feedback.submit(
        searchId: results.searchId,
        documentId: '1',
        relevance: Relevance.high));
    print(const JsonEncoder.withIndent('  ').convert({
      'records': count,
      'sdk': Platform.version,
      'os': Platform.operatingSystem,
      'processors': Platform.numberOfProcessors,
      'backend': 'memory',
      'provider': model.modelId,
      'dimensions': 2,
      'corpus': 'identical milk baby Arabic documents; one tea update',
      'index_us': indexing,
      'cold_keyword_us': coldKeyword,
      'cold_hybrid_us': coldHybrid,
      'cold_semantic_us': coldSemantic,
      'warm_keyword_us': keyword,
      'warm_hybrid_us': hybrid,
      'warm_semantic_us': semantic,
      'incremental_update_and_hybrid_us': updateAndQuery.elapsedMicroseconds,
      'source_update_us': sourceUpdate,
      'incremental_sync_us': incrementalSync,
      'post_update_hybrid_us': postUpdateQuery,
      'feedback_us': feedback,
      'rss_after_source': afterSource,
      'rss_after_index': afterIndex,
      'rss_after_queries': afterQueries,
      'rss_after_sync': afterSync,
      'rss_bytes': ProcessInfo.currentRss,
      'peak_rss_bytes': ProcessInfo.maxRss,
      'image_bytes_after_index': imageAfterIndex,
      'image_bytes': db.exportImage().length,
      'note':
          'Single AOT process; cold means first query after indexing, not OS cache reset. Fixture inference only. Learning context writes are included. RSS is sampled after the source load, after indexing, after the warm queries, after synchronization, and at the end. Image size is recorded after indexing and at the end.'
    }));
  } finally {
    await db.close();
  }
}
