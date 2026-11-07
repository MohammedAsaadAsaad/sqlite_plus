import 'dart:convert';
import 'dart:io';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

Future<void> main() async {
  final names = <String>[];
  for (final language in ['arabic', 'english']) {
    names.addAll(File(
            'examples/product_catalog/assets/products/${language}_products_10k.txt')
        .readAsLinesSync()
        .where((line) => line.trim().isNotEmpty));
  }
  final db = await openInMemory();
  try {
    await db.execute('CREATE TABLE products(id INTEGER PRIMARY KEY,body TEXT)');
    for (var start = 0; start < names.length; start += 1000) {
      final end = start + 1000 < names.length ? start + 1000 : names.length;
      await db.execute(
          'INSERT INTO products VALUES ${List.filled(end - start, '(?,?)').join(',')}',
          [
            for (var i = start; i < end; i++) ...[i + 1, names[i]]
          ]);
    }
    final search = await SqlitePlusSearch.open(
        database: db, analyzer: const SearchTextAnalyzer(stemArabic: true));
    await search
        .indexTable(table: 'products', primaryKey: 'id', textColumns: ['body']);
    final before = db.exportImage().length;
    Future<List<int>> samples(
        FuzzySearchConfig config, bool expectCache) async {
      final timings = <int>[];
      for (var i = 0; i < 5; i++) {
        final clock = Stopwatch()..start();
        final result =
            await search.search('جودة بسكوت', table: 'products', fuzzy: config);
        timings.add(clock.elapsedMicroseconds);
        if (result.total != 12 || result.fuzzyCacheUsed != expectCache) {
          throw StateError(
              'Unexpected results/cache: ${result.total}/${result.fuzzyCacheUsed}');
        }
      }
      return timings;
    }

    final baseline = await samples(const FuzzySearchConfig(), false);
    final training =
        await samples(const FuzzySearchConfig(learnAfter: 5), false);
    final learned = await samples(const FuzzySearchConfig(learnAfter: 5), true);
    print(jsonEncode({
      'rows': names.length,
      'query': 'جودة بسكوت',
      'baseline_us': baseline,
      'training_us': training,
      'learned_us': learned,
      'image_before': before,
      'image_after': db.exportImage().length,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await db.close();
  }
}
