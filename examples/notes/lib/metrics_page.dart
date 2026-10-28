import 'dart:async';

import 'package:flutter/material.dart';

import 'database_page.dart';
import 'note_work.dart';

class MetricsPage extends StatefulWidget {
  const MetricsPage({super.key});

  @override
  State<MetricsPage> createState() => _MetricsPageState();
}

class _MetricsPageState extends State<MetricsPage> {
  late ProcessSample _opened;
  late ProcessSample _previous;
  late ProcessSample _latest;
  late DateTime _previousAt;
  var _peak = 0;
  var _cpuPercent = 0.0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final now = ProcessSample.now();
    _opened = now;
    _previous = now;
    _latest = now;
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
      _latest = now;
      if (now.rssBytes > _peak) _peak = now.rssBytes;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cpu = _latest.cpuMicrosSince(_opened);
    return Scaffold(
      backgroundColor: const Color(0xFF12100E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF12100E),
        foregroundColor: const Color(0xFFF6EFE4),
        elevation: 0,
        title: const Text(
          'Metrics',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: [
          const Text(
            'Measurements for the whole process, updated every half second.',
            style: TextStyle(color: Color(0xFFB7A89A), height: 1.5),
          ),
          const SizedBox(height: 18),
          _Fact(
            label: 'Memory now',
            value: formatBytes(_latest.rssBytes),
            valueKey: const Key('metrics-rss'),
          ),
          _Fact(
            label: 'Memory peak',
            value: formatBytes(_peak),
            valueKey: const Key('metrics-peak'),
          ),
          _Fact(
            label: 'CPU',
            value: '${_cpuPercent.toStringAsFixed(1)}%',
            valueKey: const Key('metrics-cpu'),
          ),
          _Fact(
            label: 'CPU time',
            value: formatDuration(cpu),
            valueKey: const Key('metrics-cpu-time'),
          ),
          const SizedBox(height: 12),
          const Text(
            'CPU time comes from the process clocks in /proc/self/stat at 100 Hz. The share can pass 100% when more than one core is in use.',
            style: TextStyle(
              color: Color(0xFF6E5E52),
              height: 1.5,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({
    required this.label,
    required this.value,
    required this.valueKey,
  });

  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xFF6E5E52), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            key: valueKey,
            style: const TextStyle(
              color: Color(0xFFF6EFE4),
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
