import 'package:flutter/material.dart';

import 'grid.dart';
import 'session.dart';
import 'sql_editor.dart';

enum _SqlScreen { query, result }

/// One SQL statement and its result. The statement log lives on its own tab.
class SqlPane extends StatefulWidget {
  const SqlPane({
    super.key,
    required this.controller,
    required this.objects,
    required this.result,
    required this.busy,
    required this.onRun,
    required this.onPrevious,
    required this.onNext,
  });

  final TextEditingController controller;
  final List<SchemaObject> objects;
  final StatementResult? result;
  final bool busy;
  final VoidCallback onRun;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  State<SqlPane> createState() => _SqlPaneState();
}

class _SqlPaneState extends State<SqlPane> {
  var _compact = false;
  var _screen = _SqlScreen.query;

  @override
  void didUpdateWidget(SqlPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_compact &&
        !identical(widget.result, oldWidget.result) &&
        widget.result != null) {
      _screen = _SqlScreen.result;
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    return LayoutBuilder(
      builder: (context, constraints) {
        _compact = constraints.maxWidth < 640;
        if (_compact) return _compactPane(result);
        return _widePane(result);
      },
    );
  }

  Widget _compactPane(StatementResult? result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              Expanded(
                  child: _screenButton(
                      'Query', _SqlScreen.query, const Key('sql-show-query'))),
              const SizedBox(width: 8),
              Expanded(
                  child: _screenButton('Result', _SqlScreen.result,
                      const Key('sql-show-result'))),
            ],
          ),
        ),
        Expanded(
          child: _screen == _SqlScreen.query
              ? _queryBody(result)
              : _resultBody(result),
        ),
      ],
    );
  }

  Widget _screenButton(String label, _SqlScreen screen, Key key) {
    final selected = _screen == screen;
    return FilledButton(
      key: key,
      style: FilledButton.styleFrom(
        backgroundColor: selected ? const Color(0xFF0E7C66) : Colors.white,
        foregroundColor: selected ? Colors.white : const Color(0xFF14211C),
        side: const BorderSide(color: Color(0xFFD5E2DB)),
        elevation: 0,
      ),
      onPressed: () => setState(() => _screen = screen),
      child: Text(label),
    );
  }

  Widget _queryBody(StatementResult? result) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statementHeader(),
          const SizedBox(height: 8),
          Expanded(child: _editor(expand: true)),
          if (result != null && !result.isQuery) ...[
            const SizedBox(height: 8),
            Text('${result.changes} rows changed'),
          ],
        ],
      ),
    );
  }

  Widget _resultBody(StatementResult? result) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Result',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          if (result == null)
            const Expanded(
              child: Center(child: Text('Run a statement to see rows here.')),
            )
          else if (!result.isQuery)
            Text('${result.changes} rows changed')
          else ...[
            Expanded(child: _gridFrame(result)),
            _pager(result),
          ],
        ],
      ),
    );
  }

  Widget _statementHeader() {
    return Row(
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
    );
  }

  Widget _gridFrame(StatementResult result) {
    if (!result.isQuery || result.columns.isEmpty) {
      return const SizedBox.shrink();
    }
    return DecoratedBox(
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
    );
  }

  Widget _widePane(StatementResult? result) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _statementHeader(),
          const SizedBox(height: 8),
          _editor(expand: false),
          const SizedBox(height: 8),
          if (result != null && !result.isQuery)
            Text('${result.changes} rows changed'),
          const SizedBox(height: 8),
          Expanded(
            child:
                result == null ? const SizedBox.shrink() : _gridFrame(result),
          ),
          if (result != null && result.isQuery) _pager(result),
        ],
      ),
    );
  }

  Widget _editor({required bool expand}) {
    return SqlEditor(
      controller: widget.controller,
      objects: widget.objects,
      expand: expand,
    );
  }

  Widget _pager(StatementResult result) {
    return Row(
      children: [
        IconButton(
          key: const Key('sql-page-previous'),
          tooltip: 'Previous',
          onPressed: widget.busy ? null : widget.onPrevious,
          icon: const Icon(Icons.chevron_left),
        ),
        Text(_range(result), key: const Key('sql-page-range')),
        IconButton(
          key: const Key('sql-page-next'),
          tooltip: 'Next',
          onPressed: widget.busy ? null : widget.onNext,
          icon: const Icon(Icons.chevron_right),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            result.columns.join(', '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  String _range(StatementResult result) {
    if (result.rows.isEmpty) return '0 rows';
    final start = result.offset + 1;
    final end = result.offset + result.rows.length;
    return '$start–$end';
  }
}
