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
    const fuzzy = FuzzySearchConfig(learnAfter: 5);
    for (var i = 0; i < 5; i++) {
      await search.search('جودة بسكوت', table: 'products', fuzzy: fuzzy);
    }
    final measurements = <String, Object?>{};
    for (final query in ['بسكويت', 'جودة بسكويت', 'جودة بسكوت']) {
      final ordinary = <int>[], precision = <int>[];
      for (var i = 0; i < 5; i++) {
        for (final enabled in i.isEven ? [false, true] : [true, false]) {
          final clock = Stopwatch()..start();
          final result = await search.search(query,
              table: 'products',
              fuzzy: fuzzy,
              ranking: enabled ? const SearchRankingPolicy() : null);
          (enabled ? precision : ordinary).add(clock.elapsedMicroseconds);
          if (result.total != (query == 'بسكويت' ? 493 : 12)) {
            throw StateError('Changed hit count');
          }
        }
      }
      measurements[query] = {
        'baseline_us': ordinary,
        'precision_us': precision
      };
    }
    print(jsonEncode({
      'rows': names.length,
      'measurements': measurements,
      'image_before': before,
      'image_after': db.exportImage().length,
      'peak_rss': ProcessInfo.maxRss
    }));
  } finally {
    await db.close();
  }
}
