import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'catalog_work.dart';
import 'catalog_worker.dart';

/// Saved catalog image. The next launch opens this file instead of rebuilding.
///
/// Android uses this app's own files directory. No path plugin is involved, so
/// the release package stays arm64-only.
Future<File> defaultCatalogFile() async {
  final directory = await _catalogDirectory();
  return File('${directory.path}/product_catalog.sqlite');
}

Future<Directory> _catalogDirectory() async {
  if (Platform.isAndroid) {
    const candidates = [
      '/data/user/0/dev.sqliteplus.product_catalog/files',
      '/data/data/dev.sqliteplus.product_catalog/files',
    ];
    for (final path in candidates) {
      final directory = Directory(path);
      if (await _writable(directory)) return directory;
    }
  }
  final home = Platform.environment['HOME'];
  final directory = Directory(
    home == null ? 'product_catalog' : '$home/.product_catalog',
  );
  await directory.create(recursive: true);
  return directory;
}

Future<bool> _writable(Directory directory) async {
  try {
    await directory.create(recursive: true);
    final probe = File('${directory.path}/.catalog-write-probe');
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return true;
  } catch (_) {
    return false;
  }
}

/// Screen state. Database work runs on a background isolate, 1,000 rows at a time.
class CatalogController extends ChangeNotifier {
  CatalogController({this.products, Future<File> Function()? storeFile})
    : _storeFile = storeFile ?? defaultCatalogFile;

  final ProductLoader? products;
  final Future<File> Function() _storeFile;
  final _worker = CatalogWorkerClient();

  bool arabic = true;
  bool english = true;
  SearchScope scope = SearchScope.all;
  bool busy = false;
  bool loaded = false;
  bool indexed = false;
  String status = 'Catalog is not ready';
  String? error;
  int productCount = 0;
  int progressDone = 0;
  int progressTotal = 0;
  String progressLabel = '';
  ResourceSample? latest;
  List<ProductMatch> matches = const [];
  int matchTotal = 0;
  int page = 1;
  Duration? searchElapsed;
  final List<PhaseReport> reports = [];

  int get pageCount => catalogPageCount(matches.length);

  List<ProductMatch> get visibleMatches =>
      matches.isEmpty ? const [] : catalogPage(matches, page);

  bool get canLoad => !busy && (arabic || english);
  bool get canIndex => !busy && loaded;
  bool get canSearch => !busy && indexed;
  bool get canSample => !busy;

  /// Opens the saved catalog. Builds it once when the file is missing.
  Future<void> prepare() async {
    if (busy) return;
    await _run('Opening catalog…', () async {
      await _worker.start();
      final file = await _storeFile();
      final opened = await _worker.call({'op': 'open', 'path': file.path});
      if (opened['found'] == true) {
        _rememberOpened(opened);
      }
      if (!loaded) await _loadProducts();
      if (!indexed) {
        await _buildIndex();
        await _save(file);
      }
      status = 'Ready';
    }, resetOnError: true);
  }

  void setArabic(bool value) {
    if (busy) return;
    arabic = value;
    notifyListeners();
  }

  void setEnglish(bool value) {
    if (busy) return;
    english = value;
    notifyListeners();
  }

  void setScope(SearchScope value) {
    if (busy) return;
    scope = value;
    notifyListeners();
  }

  Future<void> load() async {
    if (!canLoad) return;
    await _run('Loading products…', () async {
      await _worker.start();
      await _loadProducts();
      await _buildIndex();
      await _save(await _storeFile());
      status = 'Ready';
    }, resetOnError: true);
  }

  Future<void> buildIndex() async {
    if (!canIndex) return;
    await _run('Building the search index…', () async {
      await _buildIndex(rebuild: indexed);
      await _save(await _storeFile());
      status = 'Ready';
    }, resetOnError: true);
  }

  Future<void> _loadProducts() async {
    final readClock = Stopwatch()..start();
    final sources = await _sources();
    readClock.stop();
    final total = sources.fold<int>(0, (sum, source) => sum + source.count);
    if (total == 0) {
      throw ArgumentError('Choose at least one product file');
    }
    _add(
      _report(
        title: 'Read product files',
        elapsed: readClock.elapsed,
        before: _processSample(imageBytes: latest?.imageBytes ?? 0),
        after: _processSample(imageBytes: latest?.imageBytes ?? 0),
        sampleElapsed: Duration.zero,
        detail: '$total names',
      ),
    );
    await _worker.call({'op': 'reset'});
    loaded = false;
    indexed = false;
    productCount = 0;
    _clearSearch();
    final before = await _takeSample();
    final insertClock = Stopwatch()..start();
    var done = 0;
    _showProgress(0, total, 'Inserting');
    for (final source in sources) {
      if (source.lines != null) {
        final lines = source.lines!;
        for (var start = 0; start < lines.length; start += catalogBatchSize) {
          final end = start + catalogBatchSize < lines.length
              ? start + catalogBatchSize
              : lines.length;
          done = await _insertBatch(lines.sublist(start, end), done, total);
        }
      } else {
        for (final batch in productBatches(source.text!, source.language)) {
          done = await _insertBatch(batch, done, total);
        }
      }
    }
    insertClock.stop();
    final after = await _takeSample();
    productCount = done;
    loaded = true;
    _add(
      _report(
        title: 'Insert products',
        elapsed: insertClock.elapsed,
        before: before.sample,
        after: after.sample,
        sampleElapsed: after.sampleElapsed,
        detail: '$done rows in products',
      ),
    );
  }

  Future<void> _buildIndex({bool rebuild = false}) async {
    final before = await _takeSample();
    _showProgress(0, productCount, 'Indexing');
    _worker.onProgress = (done, total, rss) {
      progressDone = done;
      progressTotal = total;
      progressLabel = done >= total && total > 0
          ? 'Writing the word index'
          : 'Indexing';
      status = progressLabel == 'Writing the word index'
          ? 'Writing the word index…'
          : 'Indexing $done of $total';
      latest = ResourceSample(
        rssBytes: rss,
        peakRssBytes: latest?.peakRssBytes ?? rss,
        imageBytes: latest?.imageBytes ?? 0,
      );
      notifyListeners();
    };
    final clock = Stopwatch()..start();
    await _worker.call({'op': 'index', 'rebuild': rebuild});
    clock.stop();
    _worker.onProgress = null;
    final after = await _takeSample();
    _add(
      _report(
        title: 'Build search index',
        elapsed: clock.elapsed,
        before: before.sample,
        after: after.sample,
        sampleElapsed: after.sampleElapsed,
        detail: 'Keyword index, Arabic stemming on, $productCount products',
      ),
    );
    indexed = true;
  }

  void _rememberOpened(Map<String, Object?> opened) {
    loaded = (opened['count'] as int? ?? 0) > 0 || opened['indexed'] == true;
    indexed = opened['indexed'] == true;
    productCount = opened['count'] as int? ?? 0;
    final raw = opened['sample'];
    if (raw is Map) {
      latest = _sampleFrom(raw, Duration.zero).sample;
    }
  }

  Future<void> _save(File file) async {
    await _worker.call({'op': 'save', 'path': file.path});
  }

  Future<void> runSearch(String query) async {
    if (!canSearch) return;
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      error = 'Enter a search query';
      notifyListeners();
      return;
    }
    await _run('Searching…', () async {
      final clock = Stopwatch()..start();
      final response = await _worker.call({
        'op': 'search',
        'query': trimmed,
        'scope': scope.name,
      });
      clock.stop();
      final rawMatches = response['matches'] as List;
      final found = [
        for (final raw in rawMatches)
          ProductMatch(
            rank: (raw as Map)['rank'] as int,
            language: raw['language'] as String,
            sourceLine: (raw['line'] as num).toInt(),
            name: raw['name'] as String,
            score: (raw['score'] as num).toDouble(),
          ),
      ];
      matches = found;
      matchTotal = response['total'] as int;
      page = 1;
      searchElapsed = clock.elapsed;
      status = 'Ready';
    });
  }

  /// Moves within the hits already returned. This does not search again.
  void showPage(int next) {
    if (busy || next < 1 || next > pageCount || next == page) return;
    page = next;
    notifyListeners();
  }

  void _clearSearch() {
    matches = const [];
    matchTotal = 0;
    page = 1;
    searchElapsed = null;
  }

  Future<void> sample() async {
    if (!canSample) return;
    await _run('Sampling resources…', () async {
      await _worker.start();
      final before = _processSample(imageBytes: latest?.imageBytes ?? 0);
      final clock = Stopwatch()..start();
      final taken = await _takeSample();
      clock.stop();
      _add(
        _report(
          title: 'Resource sample',
          elapsed: clock.elapsed,
          before: before,
          after: taken.sample,
          sampleElapsed: taken.sampleElapsed,
          detail: 'Point-in-time RSS and database image',
        ),
      );
      status = 'Resource sample recorded';
    });
  }

  Future<int> _insertBatch(List<ProductLine> batch, int done, int total) async {
    final response = await _worker.call({
      'op': 'insert',
      'rows': [
        for (final line in batch) [line.language, line.sourceLine, line.name],
      ],
    });
    final next = response['count'] as int;
    progressDone = next;
    progressTotal = total;
    progressLabel = 'Inserting';
    status = 'Inserting $next of $total';
    latest = ResourceSample(
      rssBytes: response['rss'] as int,
      peakRssBytes: response['peak'] as int,
      imageBytes: latest?.imageBytes ?? 0,
    );
    notifyListeners();
    return next;
  }

  void _showProgress(int done, int total, String label) {
    progressDone = done;
    progressTotal = total;
    progressLabel = label;
    notifyListeners();
  }

  Future<List<_Source>> _sources() async {
    final loader = products;
    if (loader != null) {
      final lines = await loader(arabic: arabic, english: english);
      return [_Source(language: '', count: lines.length, lines: lines)];
    }
    final sources = <_Source>[];
    if (arabic) {
      final text = await rootBundle.loadString(
        'assets/products/arabic_products_10k.txt',
      );
      sources.add(
        _Source(language: 'Arabic', count: countProductNames(text), text: text),
      );
    }
    if (english) {
      final text = await rootBundle.loadString(
        'assets/products/english_products_10k.txt',
      );
      sources.add(
        _Source(
          language: 'English',
          count: countProductNames(text),
          text: text,
        ),
      );
    }
    return sources;
  }

  Future<_Taken> _takeSample() async {
    final clock = Stopwatch()..start();
    final response = await _worker.call({'op': 'sample'});
    clock.stop();
    return _sampleFrom(response['sample'] as Map, clock.elapsed);
  }

  _Taken _sampleFrom(Map raw, Duration elapsed) {
    return _Taken(
      ResourceSample(
        rssBytes: raw['rss'] as int,
        peakRssBytes: raw['peak'] as int,
        imageBytes: raw['image'] as int,
      ),
      elapsed,
    );
  }

  ResourceSample _processSample({required int imageBytes}) {
    return ResourceSample(
      rssBytes: ProcessInfo.currentRss,
      peakRssBytes: ProcessInfo.maxRss,
      imageBytes: imageBytes,
    );
  }

  PhaseReport _report({
    required String title,
    required Duration elapsed,
    required ResourceSample before,
    required ResourceSample after,
    required Duration sampleElapsed,
    required String detail,
  }) {
    return PhaseReport(
      title: title,
      elapsed: elapsed,
      sampleElapsed: sampleElapsed,
      rssBefore: before.rssBytes,
      rssAfter: after.rssBytes,
      peakRss: after.peakRssBytes,
      imageBefore: before.imageBytes,
      imageAfter: after.imageBytes,
      detail: detail,
    );
  }

  Future<void> _run(
    String label,
    Future<void> Function() action, {
    bool resetOnError = false,
  }) async {
    busy = true;
    error = null;
    status = label;
    progressDone = 0;
    progressTotal = 0;
    progressLabel = '';
    notifyListeners();
    try {
      await action();
    } catch (error) {
      if (resetOnError) {
        try {
          await _worker.start();
          await _worker.call({'op': 'reset'});
        } catch (_) {
          // The error above is the one shown.
        }
        loaded = false;
        indexed = false;
        productCount = 0;
        _clearSearch();
      }
      this.error = error.toString();
      status = 'Failed';
    } finally {
      busy = false;
      progressLabel = '';
      notifyListeners();
    }
  }

  void _add(PhaseReport report) {
    reports.insert(0, report);
    latest = ResourceSample(
      rssBytes: report.rssAfter,
      peakRssBytes: report.peakRss,
      imageBytes: report.imageAfter,
    );
  }

  @override
  void dispose() {
    _worker.close();
    super.dispose();
  }
}

final class _Source {
  _Source({required this.language, required this.count, this.text, this.lines});

  final String language;
  final int count;
  final String? text;
  final List<ProductLine>? lines;
}

final class _Taken {
  _Taken(this.sample, this.sampleElapsed);

  final ResourceSample sample;
  final Duration sampleElapsed;

  int get rssBytes => sample.rssBytes;
  int get peakRssBytes => sample.peakRssBytes;
  int get imageBytes => sample.imageBytes;
}
