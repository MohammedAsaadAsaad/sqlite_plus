import 'package:flutter/material.dart';

import 'catalog_controller.dart';
import 'catalog_format.dart';
import 'catalog_work.dart';

class CatalogPage extends StatefulWidget {
  const CatalogPage({super.key, this.products});

  final ProductLoader? products;

  @override
  State<CatalogPage> createState() => _CatalogPageState();
}

class _CatalogPageState extends State<CatalogPage> {
  late final CatalogController _controller;
  final _query = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = CatalogController(products: widget.products);
    _query.addListener(() => setState(() {}));
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
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  children: [
                    Text('Catalog', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      controller.status,
                      key: const Key('status-line'),
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 14),
                    if (controller.busy)
                      KeyedSubtree(
                        key: const Key('busy'),
                        child: controller.progressTotal > 0
                            ? _Progress(controller: controller)
                            : const SizedBox(height: 4),
                      )
                    else
                      _Metrics(controller: controller),
                    const SizedBox(height: 14),
                    SegmentedButton<String>(
                      multiSelectionEnabled: true,
                      emptySelectionAllowed: true,
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 'Arabic', label: Text('Arabic')),
                        ButtonSegment(value: 'English', label: Text('English')),
                      ],
                      selected: {
                        if (controller.arabic) 'Arabic',
                        if (controller.english) 'English',
                      },
                      onSelectionChanged: controller.busy
                          ? null
                          : (selected) {
                              controller.setArabic(selected.contains('Arabic'));
                              controller.setEnglish(
                                selected.contains('English'),
                              );
                            },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            key: const Key('load-products'),
                            onPressed: controller.canLoad
                                ? controller.load
                                : null,
                            child: const Text('Load'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            key: const Key('build-index'),
                            onPressed: controller.canIndex
                                ? controller.buildIndex
                                : null,
                            child: const Text('Index'),
                          ),
                        ),
                      ],
                    ),
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
                    if (controller.matches.isNotEmpty ||
                        controller.status == 'No matches') ...[
                      const SizedBox(height: 18),
                      _Results(controller: controller),
                    ],
                    const SizedBox(height: 18),
                    _Reports(reports: controller.reports),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        key: const Key('sample-resources'),
                        onPressed: controller.canSample
                            ? controller.sample
                            : null,
                        child: const Text('Sample resources'),
                      ),
                    ),
                    Text(
                      'Each step runs on a background isolate, 1,000 products at a time. '
                      'The time shown excludes the resource sample.',
                      style: theme.textTheme.bodySmall,
                    ),
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

class _Metrics extends StatelessWidget {
  const _Metrics({required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    final latest = controller.latest;
    return Row(
      children: [
        _Metric(label: 'Products', value: formatCount(controller.productCount)),
        _Metric(
          label: 'Image',
          value: latest == null ? '—' : formatBytes(latest.imageBytes),
        ),
        _Metric(
          label: 'Memory',
          value: latest == null ? '—' : formatBytes(latest.rssBytes),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(height: 2),
            Text(value, style: theme.textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}

class _Results extends StatelessWidget {
  const _Results({required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const Key('result-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          controller.matchTotal == 0
              ? 'No matches'
              : '${controller.matches.length} shown of ${controller.matchTotal}',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        for (final match in controller.matches)
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
