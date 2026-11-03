import 'package:flutter/material.dart';

import 'format.dart';
import 'session.dart';

/// One SQL statement and its rows or change count.
class SqlPane extends StatelessWidget {
  const SqlPane({
    super.key,
    required this.controller,
    required this.result,
    required this.busy,
    required this.onRun,
  });

  final TextEditingController controller;
  final StatementResult? result;
  final bool busy;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('sql-input'),
            controller: controller,
            minLines: 5,
            maxLines: 10,
            style: const TextStyle(fontFamily: 'monospace'),
            decoration: const InputDecoration(
              labelText: 'One statement',
              alignLabelWithHint: true,
              filled: true,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              key: const Key('run-sql'),
              onPressed: busy ? null : onRun,
              child: const Text('Run'),
            ),
          ),
          const SizedBox(height: 12),
          if (result != null && result.isQuery)
            Text('${result.rows.length} rows · ${result.columns.join(', ')}'),
          if (result != null && !result.isQuery)
            Text('${result.changes} rows changed'),
          const SizedBox(height: 8),
          if (result != null && result.isQuery && result.columns.isNotEmpty)
            Expanded(
              child: Scrollbar(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    child: DataTable(
                      key: const Key('sql-grid'),
                      columns: [
                        for (final name in result.columns)
                          DataColumn(label: Text(name)),
                      ],
                      rows: [
                        for (final row in result.rows)
                          DataRow(
                            cells: [
                              for (final value in row)
                                DataCell(Text(formatCell(value))),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
