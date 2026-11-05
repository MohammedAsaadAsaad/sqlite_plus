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
        return Scaffold(
          body: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 920),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Product catalog',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Two bundled lists, 10,000 names each. '
                        'Nothing is loaded, indexed, or searched until you ask.',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 20),
                      _Summary(controller: controller),
                      const SizedBox(height: 16),
                      _Actions(
                        controller: controller,
                        query: _query,
                        onExample: _runExample,
                      ),
                      if (controller.error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          controller.error!,
                          key: const Key('error'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ],
                      if (controller.matches.isNotEmpty ||
                          controller.status == 'No matches') ...[
                        const SizedBox(height: 20),
                        _Results(controller: controller),
                      ],
                      const SizedBox(height: 20),
                      _Reports(reports: controller.reports),
                      const SizedBox(height: 16),
                      Text(
                        'Each operation time excludes the resource sample. '
                        'RSS is the process resident set. '
                        'Image size is the sqlite_plus database image. '
                        'Figures are one sample on this device.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    final latest = controller.latest;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(controller.status, key: const Key('status-line')),
            if (controller.busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Working', key: Key('busy')),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _Stat('Products', '${controller.productCount}'),
                _Stat('Index', controller.indexed ? 'Ready' : 'Not built'),
                _Stat(
                  'Image',
                  latest == null ? '—' : formatBytes(latest.imageBytes),
                ),
                _Stat(
                  'RSS',
                  latest == null ? '—' : formatBytes(latest.rssBytes),
                ),
                _Stat(
                  'Peak RSS',
                  latest == null ? '—' : formatBytes(latest.peakRssBytes),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 2),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.controller,
    required this.query,
    required this.onExample,
  });

  final CatalogController controller;
  final TextEditingController query;
  final void Function(String query) onExample;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                FilterChip(
                  key: const Key('arabic-file'),
                  label: const Text('Arabic products'),
                  selected: controller.arabic,
                  onSelected: controller.busy ? null : controller.setArabic,
                ),
                FilterChip(
                  key: const Key('english-file'),
                  label: const Text('English products'),
                  selected: controller.english,
                  onSelected: controller.busy ? null : controller.setEnglish,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('load-products'),
                  onPressed: controller.canLoad ? controller.load : null,
                  child: const Text('Load products'),
                ),
                FilledButton(
                  key: const Key('build-index'),
                  onPressed: controller.canIndex ? controller.buildIndex : null,
                  child: const Text('Build search index'),
                ),
                OutlinedButton(
                  key: const Key('sample-resources'),
                  onPressed: controller.canSample ? controller.sample : null,
                  child: const Text('Sample resources'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('search-field'),
              controller: query,
              enabled: !controller.busy,
              decoration: const InputDecoration(
                labelText: 'Search',
                hintText: 'biscuit or بسكويت',
                border: OutlineInputBorder(),
              ),
              onSubmitted: controller.canSearch ? controller.runSearch : null,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Examples'),
                ActionChip(
                  key: const Key('example-biscuit'),
                  label: const Text('biscuit'),
                  onPressed: controller.busy
                      ? null
                      : () => onExample('biscuit'),
                ),
                ActionChip(
                  key: const Key('example-arabic'),
                  label: const Text('بسكويت'),
                  onPressed: controller.busy ? null : () => onExample('بسكويت'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<SearchScope>(
                  segments: const [
                    ButtonSegment(value: SearchScope.all, label: Text('All')),
                    ButtonSegment(
                      value: SearchScope.arabic,
                      label: Text('Arabic'),
                    ),
                    ButtonSegment(
                      value: SearchScope.english,
                      label: Text('English'),
                    ),
                  ],
                  selected: {controller.scope},
                  onSelectionChanged: controller.busy
                      ? null
                      : (selected) => controller.setScope(selected.single),
                ),
                FilledButton(
                  key: const Key('search-button'),
                  onPressed:
                      controller.canSearch && query.text.trim().isNotEmpty
                      ? () => controller.runSearch(query.text)
                      : null,
                  child: const Text('Search'),
                ),
              ],
            ),
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
    return Column(
      key: const Key('result-list'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          controller.matchTotal == 0
              ? 'No matches'
              : '${controller.matches.length} shown of ${controller.matchTotal}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        for (final match in controller.matches)
          Card(
            child: ListTile(
              leading: Text('${match.rank}'),
              title: Text(match.name),
              subtitle: Text(
                '${match.language} · line ${match.sourceLine} · '
                'score ${match.score.toStringAsFixed(3)}',
              ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(report.title, style: theme.textTheme.titleSmall),
            if (newest) Text('Latest', style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            Text(report.detail),
            const SizedBox(height: 8),
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
      ),
    );
  }
}
