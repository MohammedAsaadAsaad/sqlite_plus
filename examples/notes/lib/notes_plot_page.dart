import 'package:flutter/material.dart';

import 'note_exchange.dart';

class NotesPlotPage extends StatelessWidget {
  const NotesPlotPage({super.key, required this.bars});

  final List<PlotBar> bars;

  @override
  Widget build(BuildContext context) {
    final peak =
        bars.fold<int>(0, (max, bar) => bar.value > max ? bar.value : max);
    return Scaffold(
      backgroundColor: const Color(0xFF12100E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF12100E),
        foregroundColor: const Color(0xFFF6EFE4),
        elevation: 0,
        title: const Text(
          'Notes by day',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: bars.isEmpty
          ? const Center(
              child: Text(
                'No notes to plot',
                key: Key('plot-empty'),
                style: TextStyle(color: Color(0xFFB7A89A)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                const Text(
                  'Each bar is the number of notes whose UTC update day is that date.',
                  style: TextStyle(color: Color(0xFFB7A89A), height: 1.5),
                ),
                const SizedBox(height: 18),
                for (final bar in bars) ...[
                  Text(
                    bar.label,
                    style: const TextStyle(color: Color(0xFFF6EFE4)),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: peak == 0 ? 0 : bar.value / peak,
                      child: Container(
                        key: Key('plot-${bar.label}'),
                        height: 18,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE15A3A),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${bar.value}',
                    key: Key('plot-value-${bar.label}'),
                    style: const TextStyle(color: Color(0xFFB7A89A)),
                  ),
                  const SizedBox(height: 14),
                ],
              ],
            ),
    );
  }
}
