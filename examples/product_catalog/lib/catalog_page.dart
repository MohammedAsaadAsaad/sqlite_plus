import 'dart:io';

import 'package:flutter/material.dart';

import 'catalog_controller.dart';
import 'catalog_format.dart';
import 'catalog_work.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage({
    super.key,
    this.products,
    this.storeFile,
    this.prepareOnStart = true,
  });

  final ProductLoader? products;
  final Future<File> Function()? storeFile;

  /// Opens a saved catalog, or builds one when no file exists yet.
  final bool prepareOnStart;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  late final CatalogController _controller;
  final _query = TextEditingController();
  bool _showActivity = false;

  @override
  void initState() {
    super.initState();
    _controller = CatalogController(
      products: widget.products,
      storeFile: widget.storeFile,
    );
    _query.addListener(() => setState(() {}));
    if (widget.prepareOnStart) {
      _controller.prepare();
    }
  }

  void _runExample(String query) {
    _query.text = query;
    if (_controller.canSearch) {
      _controller.runSearch(query);
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final controller = _controller;
        final theme = Theme.of(context);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Catalog'),
            actions: [
              PopupMenuButton<String>(
                key: const Key('catalog-menu'),
                tooltip: 'Commands',
                onSelected: (value) {
                  switch (value) {
                    case 'load':
                      controller.load();
                    case 'index':
                      controller.buildIndex();
                    case 'sample':
                      controller.sample();
                    case 'activity':
                      setState(() => _showActivity = !_showActivity);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    key: const Key('load-products'),
                    value: 'load',
                    enabled: controller.canLoad,
                    child: const Text('Load products'),
                  ),
                  PopupMenuItem(
                    key: const Key('build-index'),
                    value: 'index',
                    enabled: controller.canIndex,
                    child: Text(
                      controller.indexed ? 'Rebuild index' : 'Build index',
                    ),
                  ),
                  PopupMenuItem(
                    key: const Key('sample-resources'),
                    value: 'sample',
                    enabled: controller.canSample,
                    child: const Text('Sample resources'),
                  ),
                  PopupMenuItem(
                    key: const Key('show-activity'),
                    value: 'activity',
                    child: Text(_showActivity ? 'Hide activity' : 'Activity'),
                  ),
                ],
              ),
            ],
          ),
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    Text(
                      controller.status,
                      key: const Key('status-line'),
                      style: theme.textTheme.bodyLarge,
                    ),
                    if (controller.busy) ...[
                      const SizedBox(height: 14),
                      KeyedSubtree(
                        key: const Key('busy'),
                        child: controller.progressTotal > 0
                            ? _Progress(controller: controller)
                            : const SizedBox(height: 4),
                      ),
                    ],
                    const SizedBox(height: 18),
                    TextField(
                      key: const Key('search-field'),
                      controller: _query,
                      enabled: !controller.busy,
                      textInputAction: TextInputAction.search,
                      onSubmitted: controller.canSearch
                          ? controller.runSearch
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Search',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ActionChip(
                          key: const Key('example-biscuit'),
                          label: const Text('biscuit'),
                          onPressed: controller.busy
                              ? null
                              : () => _runExample('biscuit'),
                        ),
                        ActionChip(
                          key: const Key('example-arabic'),
                          label: const Text('بسكويت'),
                          onPressed: controller.busy
                              ? null
                              : () => _runExample('بسكويت'),
                        ),
                        SegmentedButton<SearchScope>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: SearchScope.all,
                              label: Text('All'),
                            ),
                            ButtonSegment(
                              value: SearchScope.arabic,
                              label: Text('Ar'),
                            ),
                            ButtonSegment(
                              value: SearchScope.english,
                              label: Text('En'),
                            ),
                          ],
                          selected: {controller.scope},
                          onSelectionChanged: controller.busy
                              ? null
                              : (selected) =>
                                    controller.setScope(selected.single),
                        ),
                        FilledButton(
                          key: const Key('search-button'),
                          onPressed:
                              controller.canSearch &&
                                  _query.text.trim().isNotEmpty
                              ? () => controller.runSearch(_query.text)
                              : null,
                          child: const Text('Search'),
                        ),
                      ],
                    ),
                    if (controller.error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        controller.error!,
                        key: const Key('error'),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    if (controller.searchElapsed != null) ...[
                      const SizedBox(height: 18),
                      _Results(controller: controller),
                    ],
                    if (_showActivity) ...[
                      const SizedBox(height: 18),
                      _Reports(reports: controller.reports),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = controller.progressTotal;
    final done = controller.progressDone;
    final value = total == 0 ? null : done / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(controller.progressLabel, style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            key: const Key('progress-bar'),
            minHeight: 8,
            value: value,
          ),
        ),
        const SizedBox(height: 6),
        Text('${formatCount(done)} / ${formatCount(total)}'),
      ],
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final elapsed = controller.searchElapsed;
    final pages = controller.pageCount;
    return Column(
      key: const Key('result-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          formatSearchSummary(
            controller.matchTotal,
            elapsed!,
            listed: controller.matches.length,
          ),
          key: const Key('search-time'),
          style: theme.textTheme.titleMedium,
        ),
        if (pages > 1) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton(
                key: const Key('page-previous'),
                tooltip: 'Previous page',
                onPressed: controller.busy || controller.page == 1
                    ? null
                    : () => controller.showPage(controller.page - 1),
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${controller.page} / $pages', key: const Key('page-label')),
              IconButton(
                key: const Key('page-next'),
                tooltip: 'Next page',
                onPressed: controller.busy || controller.page == pages
                    ? null
                    : () => controller.showPage(controller.page + 1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        for (final match in controller.visibleMatches)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Text('${match.rank}', style: theme.textTheme.titleMedium),
            title: Text(match.name),
            subtitle: Text(
              '${match.language} · line ${match.sourceLine} · '
              'score ${match.score.toStringAsFixed(3)}',
            ),
          ),
      ],
    );
  }
}

class _Reports extends StatelessWidget {
  const _Reports({required this.reports});

  final List<PhaseReport> reports;

  @override
  Widget build(BuildContext context) {
    if (reports.isEmpty) {
      return const Text('No operations yet.');
    }
    return Column(
      key: const Key('phase-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${reports.length} recorded',
          key: const Key('operation-count'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < reports.length; i++)
          _ReportCard(report: reports[i], newest: i == 0),
      ],
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report, required this.newest});

  final PhaseReport report;
  final bool newest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(report.title, style: theme.textTheme.titleSmall),
          if (newest) Text('Latest', style: theme.textTheme.labelMedium),
          Text(report.detail),
          Text('Time ${formatElapsed(report.elapsed)}'),
          Text(
            'Image ${formatBytes(report.imageBefore)} → '
            '${formatBytes(report.imageAfter)}',
          ),
          Text(
            'RSS ${formatBytes(report.rssBefore)} → '
            '${formatBytes(report.rssAfter)}',
          ),
          Text('Peak RSS ${formatBytes(report.peakRss)}'),
          Text(
            'Resource sample ${formatElapsed(report.sampleElapsed)} '
            '(outside the operation time)',
          ),
        ],
      ),
    );
  }
}
