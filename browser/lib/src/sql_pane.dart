import 'package:flutter/material.dart';

import 'grid.dart';
import 'session.dart';
import 'sql_complete.dart';

/// One SQL statement, a popup of the next valid tokens, and its result.
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
  final _link = LayerLink();
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    _schedulePortal();
  }

  @override
  void didUpdateWidget(SqlPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    _schedulePortal();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _schedulePortal();
  }

  void _schedulePortal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_suggestions.isEmpty) {
        _portal.hide();
      } else {
        _portal.show();
      }
    });
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
          OverlayPortal(
            controller: _portal,
            overlayChildBuilder: (context) => _menu(),
            child: CompositedTransformTarget(
              link: _link,
              child: TextField(
                key: const Key('sql-input'),
                controller: widget.controller,
                minLines: 4,
                maxLines: 8,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  height: 1.45,
                ),
                decoration: const InputDecoration(
                  hintText: 'SELECT title FROM books',
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (result != null && result.isQuery)
            Text('${result.rows.length} rows · ${result.columns.join(', ')}'),
          if (result != null && !result.isQuery)
            Text('${result.changes} rows changed'),
          const SizedBox(height: 8),
          Expanded(
            child: result != null && result.isQuery && result.columns.isNotEmpty
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFD5E2DB)),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CellGrid(
                        key: const Key('sql-grid'),
                        columns: result.columns,
                        rows: result.rows,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  Widget _menu() {
    final suggestions = _suggestions;
    return CompositedTransformFollower(
      link: _link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.bottomLeft,
      followerAnchor: Alignment.topLeft,
      offset: const Offset(0, 6),
      child: Align(
        alignment: Alignment.topLeft,
        child: Material(
          color: Colors.white,
          elevation: 12,
          shadowColor: const Color(0x6614221C),
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360, maxHeight: 248),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 6),
              shrinkWrap: true,
              itemCount: suggestions.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = suggestions[index];
                return ListTile(
                  key: Key('suggest-${item.insert}'),
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  leading:
                      Icon(_icon(item.kind), size: 18, color: _tint(item.kind)),
                  title: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: item.detail.isEmpty
                      ? null
                      : Text(
                          item.detail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: Text(
                    item.kind,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF5E736B),
                    ),
                  ),
                  onTap: () => _apply(item),
                );
              },
            ),
          ),
        ),
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
        return Icons.data_object;
    }
  }

  Color _tint(String kind) {
    switch (kind) {
      case 'column':
        return const Color(0xFF8A6A12);
      case 'table':
      case 'view':
        return const Color(0xFF0E7C66);
      default:
        return const Color(0xFF1C4E44);
    }
  }
}
