import 'package:flutter/foundation.dart';

import 'catalog_format.dart';
import 'catalog_work.dart';

/// Screen state. Every database and search step starts from a user action.
class CatalogController extends ChangeNotifier {
  CatalogController({ProductLoader? products})
    : _products = products ?? loadBundledProducts;

  final ProductLoader _products;

  bool arabic = true;
  bool english = true;
  SearchScope scope = SearchScope.all;
  bool busy = false;
  bool loaded = false;
  bool indexed = false;
  String status = 'Nothing has run yet';
  String? error;
  int productCount = 0;
  ResourceSample? latest;
  List<ProductMatch> matches = const [];
  int matchTotal = 0;
  final List<PhaseReport> reports = [];

  CatalogSession? _session;

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
      final read = await measurePhase<List<ProductLine>>(
        title: 'Read product files',
        database: () => _session?.database,
        action: () => _products(arabic: arabic, english: english),
        detail: (products) => '${products.length} names in memory',
      );
      _add(read.report);
      final products = read.value;
      await _session?.close();
      final session = CatalogSession();
      _session = session;
      loaded = false;
      indexed = false;
      productCount = 0;
      matches = const [];
      matchTotal = 0;
      status = 'Inserting products…';
      notifyListeners();
      final inserted = await measurePhase<int>(
        title: 'Insert products',
        database: () => session.database,
        action: () => session.insert(
          products,
          onProgress: (done, total) {
            status = 'Inserting $done of $total';
            notifyListeners();
          },
        ),
        detail: (count) => '$count rows in products',
      );
      _add(inserted.report);
      loaded = true;
      productCount = inserted.value;
      status = 'Products are in the database. The search index is not built.';
    }, resetOnError: true);
  }

  Future<void> buildIndex() async {
    if (!canIndex) return;
    final session = _session;
    if (session == null) return;
    await _run('Building the search index…', () async {
      final built = await measurePhase<void>(
        title: 'Build search index',
        database: () => session.database,
        action: session.buildIndex,
        detail: (_) =>
            'Keyword index, Arabic stemming on, $productCount products',
      );
      _add(built.report);
      indexed = true;
      status = 'Search index is ready';
    }, resetOnError: true);
  }

  Future<void> runSearch(String query) async {
    if (!canSearch) return;
    final session = _session;
    if (session == null) return;
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
      final found = await measurePhase<SearchRun>(
        title: 'Search "$shown"',
        database: () => session.database,
        action: () => session.searchProducts(trimmed, scope: scope),
        detail: (run) =>
            '${run.matches.length} shown of ${run.total} hits · '
            'search ${formatElapsed(run.searchElapsed)} · '
            'name lookup ${formatElapsed(run.lookupElapsed)}',
      );
      _add(found.report);
      matches = found.value.matches;
      matchTotal = found.value.total;
      status = matchTotal == 0 ? 'No matches' : '$matchTotal matches';
    });
  }

  Future<void> sample() async {
    if (!canSample) return;
    await _run('Sampling resources…', () async {
      final taken = await measurePhase<ResourceSample>(
        title: 'Resource sample',
        database: () => _session?.database,
        action: () async => sampleResources(_session?.database),
        detail: (_) => 'Point-in-time RSS and database image',
      );
      _add(taken.report);
      status = 'Resource sample recorded';
    });
  }

  Future<void> _run(
    String label,
    Future<void> Function() action, {
    bool resetOnError = false,
  }) async {
    busy = true;
    error = null;
    status = label;
    notifyListeners();
    try {
      await action();
    } catch (error) {
      if (resetOnError) {
        await _session?.close();
        _session = null;
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
    final session = _session;
    _session = null;
    session?.close();
    super.dispose();
  }
}
