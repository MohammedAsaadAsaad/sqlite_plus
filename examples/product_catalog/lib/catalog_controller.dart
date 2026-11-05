import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'catalog_format.dart';
import 'catalog_work.dart';
import 'catalog_worker.dart';

/// Screen state. Database work runs on a background isolate, 1,000 rows at a time.
class CatalogController extends ChangeNotifier {
  CatalogController({this.products});

  final ProductLoader? products;
  final _worker = CatalogWorkerClient();

  bool arabic = true;
  bool english = true;
  SearchScope scope = SearchScope.all;
  bool busy = false;
  bool loaded = false;
  bool indexed = false;
  String status = 'Nothing has run yet';
  String? error;
  int productCount = 0;
  int progressDone = 0;
  int progressTotal = 0;
  String progressLabel = '';
  ResourceSample? latest;
  List<ProductMatch> matches = const [];
  int matchTotal = 0;
  final List<PhaseReport> reports = [];

  bool get canLoad => !busy && (arabic || english);
  bool get canIndex => !busy && loaded && !indexed;
  bool get canSearch => !busy && indexed;
  bool get canSample => !busy;

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
    await _run('Reading product files…', () async {
      await _worker.start();
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
          before: _processSample(imageBytes: 0),
          after: _processSample(imageBytes: 0),
          sampleElapsed: Duration.zero,
          detail: '$total names',
        ),
      );
      await _worker.call({'op': 'reset'});
      loaded = false;
      indexed = false;
      productCount = 0;
      matches = const [];
      matchTotal = 0;
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
      status = 'Products are in the database. The search index is not built.';
    }, resetOnError: true);
  }

  Future<void> buildIndex() async {
    if (!canIndex) return;
    await _run('Building the search index…', () async {
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
      await _worker.call({'op': 'index'});
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
      status = 'Search index is ready';
    }, resetOnError: true);
  }

  Future<void> runSearch(String query) async {
    if (!canSearch) return;
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      error = 'Enter a search query';
      notifyListeners();
      return;
    }
    final shown = trimmed.length <= 40
        ? trimmed
        : '${trimmed.substring(0, 40)}…';
    await _run('Searching…', () async {
      final before = await _takeSample();
      final clock = Stopwatch()..start();
      final response = await _worker.call({
        'op': 'search',
        'query': trimmed,
        'scope': scope.name,
      });
      clock.stop();
      final after = _sampleFrom(response['sample'] as Map, Duration.zero);
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
      final total = response['total'] as int;
      final searchUs = response['searchUs'] as int;
      final lookupUs = response['lookupUs'] as int;
      _add(
        _report(
          title: 'Search "$shown"',
          elapsed: clock.elapsed,
          before: before.sample,
          after: after.sample,
          sampleElapsed: Duration.zero,
          detail:
              '${found.length} shown of $total hits · '
              'search ${formatElapsed(Duration(microseconds: searchUs))} · '
              'name lookup ${formatElapsed(Duration(microseconds: lookupUs))}',
        ),
      );
      matches = found;
      matchTotal = total;
      status = total == 0 ? 'No matches' : '$total matches';
    });
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
        'assets/products_arabic_10k.txt',
      );
      sources.add(
        _Source(language: 'Arabic', count: countProductNames(text), text: text),
      );
    }
    if (english) {
      final text = await rootBundle.loadString(
        'assets/products_english_10k.txt',
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
        matches = const [];
        matchTotal = 0;
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
