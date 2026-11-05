import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

/// Times keyword search over the two bundled 10,000-name catalogs.
Future<void> main() async {
  final root =
      Directory.current.path.endsWith('sqlite_plus_search') ? '../..' : '.';
  final arabic = File(
          '$root/examples/product_catalog/assets/products/arabic_products_10k.txt')
      .readAsStringSync();
  final english = File(
          '$root/examples/product_catalog/assets/products/english_products_10k.txt')
      .readAsStringSync();
  final names = [
    ..._lines(arabic, 'Arabic'),
    ..._lines(english, 'English'),
  ];
  final db = await openInMemory();
  await db.execute(
      'CREATE TABLE products(id INTEGER PRIMARY KEY, language TEXT NOT NULL, '
      'source_line INTEGER NOT NULL, name TEXT NOT NULL)');
  final insert = Stopwatch()..start();
  for (var start = 0; start < names.length; start += 1000) {
    final end = start + 1000 < names.length ? start + 1000 : names.length;
    final values = List.filled(end - start, '(?,?,?,?)').join(',');
    final parameters = <Object?>[];
    for (var i = start; i < end; i++) {
      parameters.addAll([i + 1, names[i].$1, names[i].$2, names[i].$3]);
    }
    await db.execute(
        'INSERT INTO products(id, language, source_line, name) VALUES $values',
        parameters);
  }
  insert.stop();
  final search = await SqlitePlusSearch.open(
      database: db, analyzer: const SearchTextAnalyzer(stemArabic: true));
  final index = Stopwatch()..start();
  await search.indexTable(
      table: 'products', primaryKey: 'id', textColumns: const ['name']);
  index.stop();
  final image = db.exportImage();
  await db.close();
  final imagePath = Platform.environment['CATALOG_IMAGE'];
  if (imagePath != null && imagePath.isNotEmpty) {
    File(imagePath).writeAsBytesSync(image);
    stdout.writeln('image_path $imagePath');
  }
  final opened = await MutableSqliteDatabase.fromImage(image);
  final restored = await SqlitePlusSearch.open(
      database: opened, analyzer: const SearchTextAnalyzer(stemArabic: true));
  final leaves =
      await opened.query('SELECT count(*) FROM _sps_1_fts_data WHERE id > 100');
  final terms = await opened.query('SELECT count(*) FROM _sps_1_fts_idx');
  stdout.writeln('rows ${names.length}');
  stdout.writeln('insert_us ${insert.elapsedMicroseconds}');
  stdout.writeln('index_us ${index.elapsedMicroseconds}');
  stdout.writeln('image_bytes ${image.length}');
  stdout.writeln('leaves ${leaves.rows.single.single}');
  stdout.writeln('terms ${terms.rows.single.single}');
  stdout.flush();
  for (final query in ['بسكويت', 'biscuit']) {
    for (var pass = 1; pass <= 3; pass++) {
      final clock = Stopwatch()..start();
      final result = await restored.search(query,
          table: 'products', limit: 20, offset: pass == 3 ? 320 : 0);
      clock.stop();
      stdout.writeln(
          'search pass=$pass query=$query hits=${result.total} shown=${result.hits.length} us=${clock.elapsedMicroseconds}');
    }
    final expression =
        const SearchTextAnalyzer(stemArabic: true).matchExpression(query);
    stdout.writeln('expression query=$query text=$expression');
    final match = Stopwatch()..start();
    final rows = await opened.query(
        'SELECT rowid, bm25(_sps_1_fts) FROM _sps_1_fts WHERE _sps_1_fts MATCH ?',
        [expression]);
    match.stop();
    stdout.writeln(
        'match query=$query rows=${rows.rows.length} us=${match.elapsedMicroseconds}');
  }
  await opened.close();
}

List<(String, int, String)> _lines(String text, String language) {
  final lines = text.split(RegExp(r'\r?\n'));
  final names = <(String, int, String)>[];
  for (var i = 0; i < lines.length; i++) {
    final name = lines[i].trim();
    if (name.isEmpty) continue;
    names.add((language, i + 1, name));
  }
  return names;
}
