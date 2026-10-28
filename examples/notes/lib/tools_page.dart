import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'database_page.dart';
import 'metrics_page.dart';
import 'note_store.dart';
import 'note_work.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({super.key, required this.store});

  final NoteStore store;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  final _count = TextEditingController(text: '100');
  var _singleTransaction = true;

  @override
  void dispose() {
    _count.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final measurement = store.lastInsert;
        final vacuum = store.lastVacuum;
        return Scaffold(
          backgroundColor: const Color(0xFF12100E),
          appBar: AppBar(
            backgroundColor: const Color(0xFF12100E),
            foregroundColor: const Color(0xFFF6EFE4),
            elevation: 0,
            title: const Text(
              'أدوات',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              TextField(
                key: const Key('insert-count'),
                controller: _count,
                enabled: !store.busy,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(color: Color(0xFFF6EFE4), fontSize: 22),
                cursorColor: const Color(0xFFE15A3A),
                decoration: InputDecoration(
                  labelText: 'عدد الملاحظات العشوائية',
                  labelStyle: const TextStyle(color: Color(0xFFB7A89A)),
                  helperText: 'من 1 إلى $maxRandomNotes',
                  helperStyle: const TextStyle(color: Color(0xFF8C7D70)),
                  filled: true,
                  fillColor: const Color(0xFF1E1A16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('insert-transaction'),
                contentPadding: EdgeInsets.zero,
                activeThumbColor: const Color(0xFFE15A3A),
                title: const Text(
                  'بـ transaction',
                  style: TextStyle(
                    color: Color(0xFFF6EFE4),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  _singleTransaction
                      ? 'كل الملاحظات في saveChanges واحد'
                      : 'كل ملاحظة في saveChanges مستقل',
                  style: const TextStyle(color: Color(0xFFB7A89A)),
                ),
                value: _singleTransaction,
                onChanged: store.busy
                    ? null
                    : (value) => setState(() => _singleTransaction = value),
              ),
              const SizedBox(height: 8),
              FilledButton(
                key: const Key('insert-run'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE15A3A),
                  foregroundColor: const Color(0xFF1A120E),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: store.busy
                    ? null
                    : () {
                        final count = int.tryParse(_count.text.trim());
                        if (count == null ||
                            count < 1 ||
                            count > maxRandomNotes) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'أدخل عدداً بين 1 و $maxRandomNotes',
                              ),
                            ),
                          );
                          return;
                        }
                        _run(
                          () => store.insertRandom(
                            count,
                            singleTransaction: _singleTransaction,
                          ),
                        );
                      },
                child: const Text(
                  'أدرج',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              if (store.busy) ...[
                const SizedBox(height: 16),
                Text(
                  store.progressTotal == 0
                      ? store.progressLabel
                      : '${store.progressLabel}  ${store.progressDone}/${store.progressTotal}',
                  style: const TextStyle(color: Color(0xFFF6EFE4)),
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  key: const Key('insert-progress'),
                  color: const Color(0xFFE15A3A),
                  backgroundColor: const Color(0xFF1E1A16),
                  value: store.progressTotal == 0
                      ? null
                      : store.progressDone / store.progressTotal,
                ),
              ],
              if (measurement != null) ...[
                const SizedBox(height: 18),
                _MeasureCard(measurement: measurement),
              ],
              const SizedBox(height: 22),
              _ToolButton(
                buttonKey: const Key('delete-all'),
                label: 'امسح الكل',
                onPressed: store.busy
                    ? null
                    : () async {
                        final confirmed = await showModalBottomSheet<bool>(
                          context: context,
                          backgroundColor: const Color(0xFF1E1A16),
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(24),
                            ),
                          ),
                          builder: (context) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                18,
                                24,
                                28,
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                    'مسح كل الملاحظات؟',
                                    style: TextStyle(
                                      color: Color(0xFFF6EFE4),
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  FilledButton(
                                    key: const Key('confirm-delete-all'),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFE15A3A),
                                      foregroundColor: const Color(0xFF1A120E),
                                    ),
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('مسح'),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                        if (confirmed == true) await _run(store.deleteAll);
                      },
              ),
              const SizedBox(height: 10),
              _ToolButton(
                buttonKey: const Key('live-metrics'),
                label: 'القياسات',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const MetricsPage()),
                ),
              ),
              const SizedBox(height: 10),
              _ToolButton(
                buttonKey: const Key('database-details'),
                label: 'تفاصيل القاعدة',
                onPressed: store.busy
                    ? null
                    : () => _run(() async {
                        final snapshot = await store.details();
                        if (!context.mounted) return;
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => DatabasePage(snapshot: snapshot),
                          ),
                        );
                      }),
              ),
              const SizedBox(height: 10),
              _ToolButton(
                buttonKey: const Key('vacuum-run'),
                label: 'VACUUM',
                onPressed: store.busy ? null : () => _run(store.vacuum),
              ),
              if (vacuum != null) ...[
                const SizedBox(height: 18),
                _VacuumCard(measurement: vacuum),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _MeasureCard extends StatelessWidget {
  const _MeasureCard({required this.measurement});

  final InsertMeasurement measurement;

  @override
  Widget build(BuildContext context) {
    final cpuShare = measurement.elapsedMicros == 0
        ? 0
        : (measurement.cpuMicros * 100) / measurement.elapsedMicros;
    return _Card(
      title: measurement.singleTransaction ? 'معاملة واحدة' : 'حفظ منفصل',
      lines: [
        'أُدرج ${measurement.inserted}',
        'الوقت ${formatDuration(measurement.elapsedMicros)}',
        'المعالج ${formatDuration(measurement.cpuMicros)} · ${cpuShare.toStringAsFixed(1)}%',
        'الرام قبل ${formatBytes(measurement.rssBefore)}',
        'الرام أثناء الذروة ${formatBytes(measurement.rssPeak)}',
        'الرام بعد ${formatBytes(measurement.rssAfter)}',
      ],
    );
  }
}

class _VacuumCard extends StatelessWidget {
  const _VacuumCard({required this.measurement});

  final VacuumMeasurement measurement;

  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'قبل وبعد VACUUM',
      lines: [
        'صفحات ${measurement.before.pageCount} ← ${measurement.after.pageCount}',
        'فارغة ${measurement.before.freelistCount} ← ${measurement.after.freelistCount}',
        'الصورة ${formatBytes(measurement.before.imageBytes)} ← ${formatBytes(measurement.after.imageBytes)}',
        'ملاحظات ${measurement.before.noteCount} ← ${measurement.after.noteCount}',
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.lines});

  final String title;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('result-$title'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1A16),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFE15A3A),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                line,
                style: const TextStyle(color: Color(0xFFF6EFE4)),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.buttonKey,
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      key: buttonKey,
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFF6EFE4),
        side: const BorderSide(color: Color(0xFF3A312A)),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      onPressed: onPressed,
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}
