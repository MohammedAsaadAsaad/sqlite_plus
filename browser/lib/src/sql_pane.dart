import 'package:flutter/material.dart';

import 'grid.dart';
import 'session.dart';
import 'sql_complete.dart';

/// One SQL statement, completions from the open schema, and its result.
class SqlPane extends StatefulWidget {
  const SqlPane({
    super.key,
    required this.controller,
    required this.objects,
    required this.result,
    required this.busy,
    required this.onRun,
  });

  final TextEditingController controller;
  final List<SchemaObject> objects;
  final StatementResult? result;
  final bool busy;
  final VoidCallback onRun;

  @override
  State<SqlPane> createState() => _SqlPaneState();
}

class _SqlPaneState extends State<SqlPane> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(SqlPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  List<SqlCompletion> get _suggestions {
    final cursor = widget.controller.selection.baseOffset;
    return sqlCompletions(
      text: widget.controller.text,
      cursor: cursor,
      objects: widget.objects,
    );
  }

  void _apply(SqlCompletion completion) {
    final text = widget.controller.text;
    final cursor = widget.controller.selection.baseOffset;
    final end = cursor < 0 ? text.length : cursor.clamp(0, text.length);
    final written = '${completion.insert} ';
    final next = text.replaceRange(completion.prefixStart, end, written);
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: completion.prefixStart + written.length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final suggestions = _suggestions;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Statement',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const Key('run-sql'),
                onPressed: widget.busy ? null : widget.onRun,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Run'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('sql-input'),
            controller: widget.controller,
            minLines: 4,
            maxLines: 8,
            style: const TextStyle(fontFamily: 'monospace', height: 1.4),
            decoration: const InputDecoration(
              hintText: 'SELECT title FROM books',
              alignLabelWithHint: true,
            ),
          ),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: suggestions.length,
                separatorBuilder: (context, index) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final item = suggestions[index];
                  return ActionChip(
                    key: Key('suggest-${item.insert}'),
                    avatar: Icon(_icon(item.kind), size: 16),
                    label: Text(item.label),
                    onPressed: () => _apply(item),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (result != null && result.isQuery)
            Text('${result.rows.length} rows · ${result.columns.join(', ')}'),
          if (result != null && !result.isQuery)
            Text('${result.changes} rows changed'),
          const SizedBox(height: 8),
          Expanded(
            child: result != null && result.isQuery && result.columns.isNotEmpty
                ? CellGrid(
                    key: const Key('sql-grid'),
                    columns: result.columns,
                    rows: result.rows,
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  IconData _icon(String kind) {
    switch (kind) {
      case 'table':
        return Icons.table_chart_outlined;
      case 'view':
        return Icons.visibility_outlined;
      case 'column':
        return Icons.view_column_outlined;
      default:
        return Icons.code;
    }
  }
}
