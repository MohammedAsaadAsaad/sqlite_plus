import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

/// One product name from a bundled list. [sourceLine] is 1-based in that file.
class ProductLine {
  const ProductLine({
    required this.language,
    required this.sourceLine,
    required this.name,
  });

  final String language;
  final int sourceLine;
  final String name;
}

/// Keyword search scope. The predicate is fixed application SQL.
enum SearchScope { all, arabic, english }

/// One named product returned for a hit.
class ProductMatch {
  const ProductMatch({
    required this.rank,
    required this.language,
    required this.sourceLine,
    required this.name,
    required this.score,
  });

  final int rank;
  final String language;
  final int sourceLine;
  final String name;
  final double score;
}

/// Search plus the name lookup that fills the result list.
class SearchRun {
  const SearchRun({
    required this.matches,
    required this.total,
    required this.searchElapsed,
    required this.lookupElapsed,
  });

  final List<ProductMatch> matches;
  final int total;
  final Duration searchElapsed;
  final Duration lookupElapsed;
}

/// Process memory and the sqlite_plus image, taken outside the operation clock.
class ResourceSample {
  const ResourceSample({
    required this.rssBytes,
    required this.peakRssBytes,
    required this.imageBytes,
  });

  final int rssBytes;
  final int peakRssBytes;
  final int imageBytes;
}

/// One user-visible step. [elapsed] excludes the resource sample.
class PhaseReport {
  const PhaseReport({
    required this.title,
    required this.elapsed,
    required this.sampleElapsed,
    required this.rssBefore,
    required this.rssAfter,
    required this.peakRss,
    required this.imageBefore,
    required this.imageAfter,
    required this.detail,
  });

  final String title;
  final Duration elapsed;
  final Duration sampleElapsed;
  final int rssBefore;
  final int rssAfter;
  final int peakRss;
  final int imageBefore;
  final int imageAfter;
  final String detail;
}

/// A finished step and the value it produced.
class Measured<T> {
  const Measured(this.report, this.value);

  final PhaseReport report;
  final T value;
}

typedef ProductLoader = Future<List<ProductLine>> Function({
  required bool arabic,
  required bool english,
});

/// Splits a product file into non-empty lines. Blank lines are not products.
List<ProductLine> parseProductFile(String text, String language) {
  final products = <ProductLine>[];
  final lines = text.split(RegExp(r'\r?\n'));
  for (var i = 0; i < lines.length; i++) {
    final name = lines[i].trim();
    if (name.isEmpty) continue;
    products.add(
      ProductLine(language: language, sourceLine: i + 1, name: name),
    );
  }
  return products;
}

/// Reads the lists selected by the caller. Nothing is read until this runs.
Future<List<ProductLine>> loadBundledProducts({
  required bool arabic,
  required bool english,
}) async {
  final products = <ProductLine>[];
  if (arabic) {
    products.addAll(
      parseProductFile(
        await rootBundle.loadString('assets/products/arabic_products_10k.txt'),
        'Arabic',
      ),
    );
  }
  if (english) {
    products.addAll(
      parseProductFile(
        await rootBundle.loadString('assets/products/english_products_10k.txt'),
        'English',
      ),
    );
  }
  return products;
}

ResourceSample sampleResources(MutableSqliteDatabase? database) {
  return ResourceSample(
    rssBytes: ProcessInfo.currentRss,
    peakRssBytes: ProcessInfo.maxRss,
    imageBytes: database == null ? 0 : database.exportImage().length,
  );
}

/// Times [action], then samples RSS and the database image outside that clock.
Future<Measured<T>> measurePhase<T>({
  required String title,
  required MutableSqliteDatabase? Function() database,
  required Future<T> Function() action,
  required String Function(T value) detail,
}) async {
  final beforeClock = Stopwatch()..start();
  final before = sampleResources(database());
  beforeClock.stop();
  final operation = Stopwatch()..start();
  final value = await action();
  operation.stop();
  final afterClock = Stopwatch()..start();
  final after = sampleResources(database());
  afterClock.stop();
  return Measured(
    PhaseReport(
      title: title,
      elapsed: operation.elapsed,
      sampleElapsed: beforeClock.elapsed + afterClock.elapsed,
      rssBefore: before.rssBytes,
      rssAfter: after.rssBytes,
      peakRss: after.peakRssBytes,
      imageBefore: before.imageBytes,
      imageAfter: after.imageBytes,
      detail: detail(value),
    ),
    value,
  );
}

/// How many products are written, then the isolate yields before the next batch.
const int catalogBatchSize = 1000;

/// Names shown on one result page. The search itself runs once.
const int catalogPageSize = 20;

/// Most hits one search keeps. Keyword search rejects a larger limit.
const int catalogResultLimit = 10000;

/// Pages needed to show [matches] at [catalogPageSize].
int catalogPageCount(int matches) {
  if (matches < 0) throw ArgumentError('Match count cannot be negative');
  if (matches == 0) return 0;
  return (matches + catalogPageSize - 1) ~/ catalogPageSize;
}

/// One page of [matches]. [page] starts at 1. An empty list has no page.
List<T> catalogPage<T>(List<T> matches, int page) {
  final count = catalogPageCount(matches.length);
  if (page < 1 || page > count) {
    throw ArgumentError('Page $page is outside 1..$count');
  }
  final start = (page - 1) * catalogPageSize;
  final end = start + catalogPageSize;
  return matches.sublist(start, end > matches.length ? matches.length : end);
}

/// Names in [text], without keeping a list of every line.
int countProductNames(String text) {
  var count = 0;
  var start = 0;
  for (var i = 0; i <= text.length; i++) {
    if (i != text.length && text.codeUnitAt(i) != 10) continue;
    var end = i;
    if (end > start && text.codeUnitAt(end - 1) == 13) end--;
    if (text.substring(start, end).trim().isNotEmpty) count++;
    start = i + 1;
  }
  return count;
}

/// Yields at most [catalogBatchSize] names at a time.
Iterable<List<ProductLine>> productBatches(String text, String language) sync* {
  final batch = <ProductLine>[];
  var start = 0;
  var lineNumber = 1;
  for (var i = 0; i <= text.length; i++) {
    if (i != text.length && text.codeUnitAt(i) != 10) continue;
    var end = i;
    if (end > start && text.codeUnitAt(end - 1) == 13) end--;
    final name = text.substring(start, end).trim();
    if (name.isNotEmpty) {
      batch.add(
        ProductLine(language: language, sourceLine: lineNumber, name: name),
      );
      if (batch.length == catalogBatchSize) {
        yield List<ProductLine>.of(batch);
        batch.clear();
      }
    }
    lineNumber++;
    start = i + 1;
  }
  if (batch.isNotEmpty) yield List<ProductLine>.of(batch);
}

/// In-memory catalog. The caller decides when each step runs.
class CatalogSession {
  MutableSqliteDatabase? database;
  SqlitePlusSearch? search;
  int productCount = 0;
  bool indexed = false;

  Future<int> insert(
    List<ProductLine> products, {
    void Function(int inserted, int total)? onProgress,
  }) async {
    if (database != null) {
      throw StateError('Products are already loaded');
    }
    if (products.isEmpty) {
      throw ArgumentError('Choose at least one product file');
    }
    var done = 0;
    for (var start = 0; start < products.length; start += catalogBatchSize) {
      final end = start + catalogBatchSize < products.length
          ? start + catalogBatchSize
          : products.length;
      done = await insertChunk(products.sublist(start, end));
      onProgress?.call(done, products.length);
      await Future<void>.delayed(Duration.zero);
    }
    return done;
  }

  /// Writes one batch of at most [catalogBatchSize] and commits it.
  Future<int> insertChunk(List<ProductLine> products) async {
    if (products.isEmpty || products.length > catalogBatchSize) {
      throw ArgumentError('A batch holds 1 to $catalogBatchSize products');
    }
    final db = await _ensureTable();
    final idStart = productCount;
    await db.execute('BEGIN');
    try {
      final values = List.filled(products.length, '(?, ?, ?, ?)').join(', ');
      final parameters = <Object?>[];
      for (var i = 0; i < products.length; i++) {
        final line = products[i];
        parameters
          ..add(idStart + i + 1)
          ..add(line.language)
          ..add(line.sourceLine)
          ..add(line.name);
      }
      await db.execute(
        'INSERT INTO products(id, language, source_line, name) VALUES $values',
        parameters,
      );
      await db.execute('COMMIT');
    } catch (error, stack) {
      if (db.inTransaction) {
        try {
          await db.execute('ROLLBACK');
        } catch (_) {
          // The original insert error is the one the caller sees.
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
    productCount += products.length;
    return productCount;
  }

  Future<MutableSqliteDatabase> _ensureTable() async {
    final existing = database;
    if (existing != null) return existing;
    final db = await openInMemory();
    database = db;
    await db.execute(
      'CREATE TABLE products ('
      'id INTEGER PRIMARY KEY, '
      'language TEXT NOT NULL, '
      'source_line INTEGER NOT NULL, '
      'name TEXT NOT NULL)',
    );
    return db;
  }

  /// Reopens a database image saved by [exportImage].
  Future<void> openImage(Uint8List bytes) async {
    if (database != null) {
      throw StateError('Products are already loaded');
    }
    final db = await MutableSqliteDatabase.fromImage(bytes);
    database = db;
    try {
      final count = await db.query('SELECT count(*) FROM products');
      productCount = _asInt(count.rows.single[0]);
      final meta = await db.query(
        "SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = '_sps_collections'",
      );
      if (meta.rows.isEmpty) return;
      final indexedRows = await db.query(
        'SELECT count(*) FROM _sps_collections NOT INDEXED WHERE source = ?',
        ['products'],
      );
      if (_asInt(indexedRows.rows.single[0]) != 1) return;
      search = await SqlitePlusSearch.open(
        database: db,
        analyzer: const SearchTextAnalyzer(stemArabic: true),
      );
      indexed = true;
    } catch (error, stack) {
      await close();
      Error.throwWithStackTrace(error, stack);
    }
  }

  Uint8List exportImage() {
    final db = database;
    if (db == null) throw StateError('No database to save');
    return db.exportImage();
  }

  /// Keyword index with Arabic stemming. English letters are left as written.
  Future<void> buildIndex({
    bool rebuild = false,
    void Function(int done, int total)? onProgress,
  }) async {
    final db = database;
    if (db == null) {
      throw StateError('Load products before building the index');
    }
    if (indexed && !rebuild) {
      throw StateError('The search index is already built');
    }
    final opened =
        search ??
        await SqlitePlusSearch.open(
          database: db,
          analyzer: const SearchTextAnalyzer(stemArabic: true),
        );
    await opened.indexTable(
      table: 'products',
      primaryKey: 'id',
      textColumns: const ['name'],
      onProgress: onProgress,
    );
    search = opened;
    indexed = true;
  }

  Future<SearchRun> searchProducts(
    String query, {
    SearchScope scope = SearchScope.all,
    int limit = catalogResultLimit,
    int offset = 0,
  }) async {
    final opened = search;
    final db = database;
    if (opened == null || db == null || !indexed) {
      throw StateError('Build the search index before searching');
    }
    final trimmed = query.trim();
    if (trimmed.isEmpty) throw ArgumentError('Enter a search query');
    final searchClock = Stopwatch()..start();
    final results = await opened.search(
      trimmed,
      table: 'products',
      limit: limit,
      offset: offset,
      filter: _scopeFilter(scope),
    );
    searchClock.stop();
    final lookupClock = Stopwatch()..start();
    final matches = <ProductMatch>[];
    if (results.hits.isNotEmpty) {
      final ids = [for (final hit in results.hits) int.parse(hit.documentId)];
      final placeholders = List.filled(ids.length, '?').join(', ');
      final rows = await db.query(
        'SELECT id, language, source_line, name FROM products '
        'WHERE id IN ($placeholders)',
        ids,
      );
      final byId = <int, List<Object?>>{
        for (final row in rows.rows) _asInt(row[0]): row,
      };
      for (var i = 0; i < results.hits.length; i++) {
        final hit = results.hits[i];
        final row = byId[int.parse(hit.documentId)];
        if (row == null) {
          throw StateError('Search hit is missing from products');
        }
        matches.add(
          ProductMatch(
            rank: offset + i + 1,
            language: row[1] as String,
            sourceLine: _asInt(row[2]),
            name: row[3] as String,
            score: hit.score,
          ),
        );
      }
    }
    lookupClock.stop();
    return SearchRun(
      matches: matches,
      total: results.total,
      searchElapsed: searchClock.elapsed,
      lookupElapsed: lookupClock.elapsed,
    );
  }

  Future<void> close() async {
    final db = database;
    database = null;
    search = null;
    indexed = false;
    productCount = 0;
    if (db != null) await db.close();
  }
}

SearchFilter? _scopeFilter(SearchScope scope) {
  switch (scope) {
    case SearchScope.arabic:
      return SearchFilter('language = ?', const ['Arabic']);
    case SearchScope.english:
      return SearchFilter('language = ?', const ['English']);
    case SearchScope.all:
      return null;
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is BigInt) return value.toInt();
  throw StateError('Expected an integer id, got $value');
}
