import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import 'bench_model.dart';
import 'native_bench.dart';
import 'sqlite_plus_bench.dart';

const _ink = Color(0xFF101418);
const _paper = Color(0xFF1A2128);
const _line = Color(0xFF2C3844);
const _text = Color(0xFFF4F1EA);
const _muted = Color(0xFF9AA7B2);
const _native = Color(0xFF7EB6D9);
const _plus = Color(0xFFE0A45A);
const _error = Color(0xFFE15A3A);

String _ltr(String value) => '\u2066$value\u2069';

class BenchPage extends StatefulWidget {
  const BenchPage({
    super.key,
    this.directory,
    this.engines,
    this.isolateSqlitePlus = true,
  });

  final Directory? directory;
  final List<BenchEngine>? engines;
  final bool isolateSqlitePlus;

  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> {
  late final TextEditingController _count;
  late final List<BenchEngine> _engines;
  final List<BenchLogEntry> _log = [];
  final Map<BenchOp, Map<String, BenchSample>> _latest = {};
  var _running = false;
  var _closed = false;
  String? _countError;
  String? _progress;
  var _done = 0;
  var _total = 1;
  late ProcessSample _opened;
  late ProcessSample _previous;
  late ProcessSample _latestSample;
  late DateTime _previousAt;
  var _peak = 0;
  var _cpuPercent = 0.0;
  Timer? _timer;
  Isolate? _activeIsolate;
  ReceivePort? _receive;
  Completer<BenchSample>? _pending;

  @override
  void initState() {
    super.initState();
    _count = TextEditingController(text: '1000');
    _engines =
        widget.engines ??
        [NativeBenchEngine(widget.directory!), SqlitePlusBenchEngine()];
    final now = ProcessSample.now();
    _opened = now;
    _previous = now;
    _latestSample = now;
    _previousAt = DateTime.now();
    _peak = now.rssBytes;
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
  }

  void _tick() {
    if (!mounted) return;
    final now = ProcessSample.now();
    final clock = DateTime.now();
    setState(() {
      _cpuPercent = now.cpuPercentSince(
        _previous,
        clock.difference(_previousAt),
      );
      _previous = now;
      _previousAt = clock;
      _latestSample = now;
      if (now.rssBytes > _peak) _peak = now.rssBytes;
    });
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    _count.dispose();
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('cancelled'));
    }
    _activeIsolate?.kill(priority: Isolate.immediate);
    _receive?.close();
    super.dispose();
  }

  Future<void> _run(List<BenchOp> ops) async {
    if (_running || _closed) return;
    final count = parseBenchCount(_count.text);
    if (count == null) {
      setState(() => _countError = 'أدخل عدداً من 1 إلى $maxBenchCount');
      return;
    }
    setState(() {
      _running = true;
      _countError = null;
      _done = 0;
      _total = count;
    });
    try {
      for (var index = 0; index < ops.length; index++) {
        final op = ops[index];
        final step = ops.length == 1 ? '' : '${index + 1}/${ops.length} · ';
        for (final engine in _engines) {
          if (!mounted || _closed) return;
          setState(() {
            _progress = '$step${engine.label} · ${op.label}';
            _done = 0;
            _total = count;
          });
          late BenchSample sample;
          try {
            sample = await _execute(engine, op, count);
          } catch (error) {
            if (!mounted || _closed) return;
            sample = _failedSample(engine, op, count, error);
          }
          if (!mounted || _closed) return;
          setState(() {
            _log.insert(0, BenchLogEntry(at: DateTime.now(), sample: sample));
            if (_log.length > 200) {
              _log.removeRange(200, _log.length);
            }
            _latest.putIfAbsent(op, () => {})[engine.id] = sample;
          });
        }
      }
    } finally {
      if (mounted && !_closed) {
        setState(() {
          _running = false;
          _progress = null;
        });
      }
    }
  }

  BenchSample _failedSample(
    BenchEngine engine,
    BenchOp op,
    int count,
    Object error,
  ) {
    return BenchSample(
      engineId: engine.id,
      engineLabel: engine.label,
      op: op,
      count: count,
      elapsedMicros: 0,
      cpuMicros: 0,
      rssBefore: _latestSample.rssBytes,
      rssAfter: _latestSample.rssBytes,
      rows: 0,
      checksum: 0,
      hits: 0,
      prepareMicros: 0,
      exportMicros: 0,
      storedBytes: 0,
      error: '$error',
    );
  }

  Future<BenchSample> _execute(BenchEngine engine, BenchOp op, int count) {
    void onProgress(int done, int total) {
      if (!mounted || _closed) return;
      if (done != total && done % 20 != 0) return;
      setState(() {
        _done = done;
        _total = total;
      });
    }

    if (widget.isolateSqlitePlus && engine.id == 'sqlite_plus') {
      return _isolate(op, count, onProgress);
    }
    return engine.run(op, count, onProgress);
  }

  Future<BenchSample> _isolate(
    BenchOp op,
    int count,
    void Function(int done, int total) onProgress,
  ) async {
    final receive = ReceivePort();
    _receive = receive;
    final pending = Completer<BenchSample>();
    _pending = pending;
    final subscription = receive.listen((message) {
      if (message is! Map) return;
      final map = Map<String, Object?>.from(message);
      switch (map['kind']) {
        case 'progress':
          onProgress(map['done']! as int, map['total']! as int);
        case 'done':
          if (!pending.isCompleted) {
            pending.complete(BenchSample.fromMessage(map));
          }
        case 'error':
          if (!pending.isCompleted) {
            pending.completeError(StateError('${map['message']}'));
          }
      }
    });
    try {
      _activeIsolate = await Isolate.spawn(sqlitePlusBenchEntry, {
        'send': receive.sendPort,
        'op': op.index,
        'count': count,
      });
      return await pending.future;
    } finally {
      await subscription.cancel();
      receive.close();
      if (identical(_receive, receive)) _receive = null;
      if (identical(_pending, pending)) _pending = null;
      _activeIsolate = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = _engines
        .map((engine) => engine.location)
        .whereType<String>()
        .firstOrNull;
    final cpu = _latestSample.cpuMicrosSince(_opened);
    return Scaffold(
      backgroundColor: _ink,
      appBar: AppBar(
        backgroundColor: _ink,
        foregroundColor: _text,
        elevation: 0,
        title: const Text(
          'ميزان',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          const Text(
            'نفس عبارات SQL على SQLite في أندرويد وعلى sqlite_plus. العدد من 1 إلى 10000. الوقت يقيس العملية نفسها. التجهيز، ومنه فهرس البحث، يظهر وحده، وكذلك تصدير صورة sqlite_plus.',
            style: TextStyle(color: _muted, height: 1.6),
          ),
          if (location != null) ...[
            const SizedBox(height: 8),
            const Text('ملف النيتف', style: TextStyle(color: _muted)),
            const SizedBox(height: 4),
            Text(
              location,
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.right,
              style: const TextStyle(color: _muted, height: 1.5),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _Metric(
                  metricKey: const Key('live-rss'),
                  label: 'الذاكرة',
                  value: formatBytes(_latestSample.rssBytes),
                  detail: 'الذروة ${_ltr(formatBytes(_peak))}',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Metric(
                  metricKey: const Key('live-cpu'),
                  label: 'المعالج',
                  value: '${_cpuPercent.toStringAsFixed(0)}%',
                  detail: 'منذ الفتح ${_ltr(formatMicros(cpu))}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('count-field'),
            controller: _count,
            enabled: !_running,
            keyboardType: TextInputType.number,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _text,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
            decoration: InputDecoration(
              labelText: 'عدد العمليات',
              labelStyle: const TextStyle(color: _muted),
              errorText: _countError,
              filled: true,
              fillColor: _paper,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: _line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: const BorderSide(color: _line),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final op in BenchOp.values)
                OutlinedButton(
                  key: Key('op-${op.name}'),
                  onPressed: _running ? null : () => _run([op]),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _text,
                    side: const BorderSide(color: _line),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                  child: Text(op.label),
                ),
              FilledButton(
                key: const Key('run-all'),
                onPressed: _running ? null : () => _run(BenchOp.values),
                style: FilledButton.styleFrom(
                  backgroundColor: _plus,
                  foregroundColor: const Color(0xFF1A140C),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                child: const Text('تشغيل الكل'),
              ),
            ],
          ),
          if (_running) ...[
            const SizedBox(height: 16),
            Text(
              _progress ?? '',
              key: const Key('progress'),
              style: const TextStyle(color: _text, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: _total == 0 ? null : _done / _total,
              backgroundColor: _line,
              color: _plus,
              minHeight: 6,
              borderRadius: BorderRadius.circular(99),
            ),
          ],
          if (_latest.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              'المقارنة',
              style: TextStyle(
                color: _text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            const _Legend(),
            const SizedBox(height: 8),
            for (final op in BenchOp.values)
              if (_latest[op] != null)
                _CompareCard(op: op, samples: _latest[op]!),
          ],
          const SizedBox(height: 22),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'السجل',
                  style: TextStyle(
                    color: _text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                key: const Key('clear-log'),
                onPressed: _running
                    ? null
                    : () => setState(() {
                        _log.clear();
                        _latest.clear();
                      }),
                child: const Text('مسح السجل'),
              ),
            ],
          ),
          if (_log.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('السجل فارغ', style: TextStyle(color: _muted)),
            )
          else
            for (final entry in _log) _LogTile(entry: entry),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.metricKey,
    required this.label,
    required this.value,
    required this.detail,
  });

  final Key metricKey;
  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: metricKey,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: _muted)),
          const SizedBox(height: 6),
          Text(
            value,
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: _text,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(detail, style: const TextStyle(color: _muted, fontSize: 12)),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        _Swatch(color: _native, label: 'النيتف'),
        SizedBox(width: 16),
        _Swatch(color: _plus, label: 'sqlite_plus'),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: _muted)),
      ],
    );
  }
}

class _CompareCard extends StatelessWidget {
  const _CompareCard({required this.op, required this.samples});

  final BenchOp op;
  final Map<String, BenchSample> samples;

  @override
  Widget build(BuildContext context) {
    final native = samples['native'];
    final plus = samples['sqlite_plus'];
    final comparable =
        native != null && plus != null && !native.failed && !plus.failed;
    final matched =
        comparable &&
        native.rows == plus.rows &&
        native.checksum == plus.checksum &&
        native.hits == plus.hits;
    final maxMicros = [
      native?.elapsedMicros ?? 0,
      plus?.elapsedMicros ?? 0,
    ].reduce((a, b) => a > b ? a : b);
    return Container(
      key: Key('compare-${op.name}'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  op.label,
                  style: const TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (comparable)
                Text(
                  matched ? 'النتيجة متطابقة' : 'النتيجة مختلفة',
                  style: TextStyle(color: matched ? _plus : _error),
                ),
            ],
          ),
          const SizedBox(height: 10),
          if (native != null)
            _Bar(sample: native, color: _native, maxMicros: maxMicros),
          if (plus != null) ...[
            const SizedBox(height: 8),
            _Bar(sample: plus, color: _plus, maxMicros: maxMicros),
          ],
          if (comparable && native.elapsedMicros > 0) ...[
            const SizedBox(height: 8),
            Text(
              'sqlite_plus / النيتف  ${(plus.elapsedMicros / native.elapsedMicros).toStringAsFixed(2)}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(color: _muted),
            ),
          ],
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.sample,
    required this.color,
    required this.maxMicros,
  });

  final BenchSample sample;
  final Color color;
  final int maxMicros;

  @override
  Widget build(BuildContext context) {
    final fraction = sample.failed || maxMicros <= 0
        ? 0.0
        : sample.elapsedMicros / maxMicros;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(sample.engineLabel, style: TextStyle(color: color)),
            const Spacer(),
            Text(
              sample.failed ? 'توقفت' : formatMicros(sample.elapsedMicros),
              textDirection: TextDirection.ltr,
              style: const TextStyle(color: _text, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: fraction.clamp(0, 1),
            minHeight: 8,
            backgroundColor: _line,
            color: color,
          ),
        ),
        if (sample.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(sample.error!, style: const TextStyle(color: _error)),
          ),
      ],
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry});

  final BenchLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final sample = entry.sample;
    final color = sample.engineId == 'native' ? _native : _plus;
    return Container(
      key: const Key('log-line'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _paper,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                formatClock(entry.at),
                textDirection: TextDirection.ltr,
                style: const TextStyle(color: _muted),
              ),
              const Spacer(),
              Text(
                sample.engineLabel,
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${sample.op.label} · ${_ltr('${sample.count}')}',
            style: const TextStyle(color: _text),
          ),
          const SizedBox(height: 4),
          Text(
            sample.failed ? 'توقفت' : formatMicros(sample.elapsedMicros),
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: _text,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'المعالج ${_ltr(formatMicros(sample.cpuMicros))} · الذاكرة ${_ltr(formatBytes(sample.rssBefore))} → ${_ltr(formatBytes(sample.rssAfter))}',
            style: const TextStyle(color: _muted, height: 1.4),
          ),
          Text(
            'صفوف ${_ltr('${sample.rows}')} · مجموع ${_ltr('${sample.checksum}')} · نتائج ${_ltr('${sample.hits}')}',
            style: const TextStyle(color: _muted, height: 1.4),
          ),
          Text(
            'تجهيز ${_ltr(formatMicros(sample.prepareMicros))} · تصدير ${_ltr(formatMicros(sample.exportMicros))} · الحجم ${_ltr(formatBytes(sample.storedBytes))}',
            style: const TextStyle(color: _muted, height: 1.4),
          ),
          if (sample.error != null)
            Text(sample.error!, style: const TextStyle(color: _error)),
        ],
      ),
    );
  }
}
