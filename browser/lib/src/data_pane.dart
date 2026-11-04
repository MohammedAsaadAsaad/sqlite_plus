import 'package:flutter/material.dart';

import 'format.dart';
import 'grid.dart';
import 'session.dart';
import 'sql_view.dart';

/// One page of the selected table or view, with a filter row and a pager.
class DataPane extends StatefulWidget {
  const DataPane({
    super.key,
    required this.object,
    required this.catalog,
    required this.slice,
    required this.busy,
    required this.onFirst,
    required this.onPrevious,
    required this.onNext,
    required this.onLast,
    required this.onJump,
    required this.onInsert,
    required this.onEdit,
    required this.onDelete,
    required this.onShowSql,
  });

  final SchemaObject? object;
  final List<SchemaObject> catalog;
  final TableSlice slice;
  final bool busy;
  final VoidCallback? onFirst;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onLast;
  final ValueChanged<int>? onJump;
  final VoidCallback? onInsert;
  final void Function(ColumnInfo column, BigInt rowid, Object? current)? onEdit;
  final void Function(BigInt rowid)? onDelete;
  final VoidCallback onShowSql;

  @override
  State<DataPane> createState() => _DataPaneState();
}

class _DataPaneState extends State<DataPane> {
  final _filters = <TextEditingController>[];
  final _go = TextEditingController();

  TableSlice get slice => widget.slice;

  @override
  void initState() {
    super.initState();
    _ensureFilters();
  }

  @override
  void didUpdateWidget(DataPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureFilters();
    final previous = oldWidget.object;
    final next = widget.object;
    if (previous?.name != next?.name || previous?.type != next?.type) {
      for (final filter in _filters) {
        filter.removeListener(_refresh);
        filter.clear();
        filter.addListener(_refresh);
      }
      _go.clear();
    }
  }

  @override
  void dispose() {
    for (final filter in _filters) {
      filter.dispose();
    }
    _go.dispose();
    super.dispose();
  }

  void _ensureFilters() {
    final count = slice.columns.length;
    while (_filters.length < count) {
      final controller = TextEditingController();
      controller.addListener(_refresh);
      _filters.add(controller);
    }
    while (_filters.length > count) {
      final removed = _filters.removeLast();
      removed.removeListener(_refresh);
      removed.dispose();
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _submitGo() {
    final page = int.tryParse(_go.text.trim());
    final jump = widget.onJump;
    if (page == null || page < 1 || jump == null) return;
    jump(page);
  }

  @override
  Widget build(BuildContext context) {
    final object = widget.object;
    if (object == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Choose a table, or open SQL and create one.'),
        ),
      );
    }
    if (object.type != 'table' && object.type != 'view') {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            object.name,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          if (object.type == 'index') ...[
            const SizedBox(height: 12),
            _IndexFacts(object: object),
          ],
          const SizedBox(height: 12),
          SqlCodeView(source: formatSql(object.sql ?? object.name)),
        ],
      );
    }
    final visible = _visibleRows();
    final filtering = _filters.any((filter) => filter.text.trim().isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Text(
                object.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              IconButton(
                key: const Key('show-sql'),
                tooltip: 'Create statement',
                onPressed: object.sql == null ? null : widget.onShowSql,
                icon: const Icon(Icons.info_outline),
              ),
              IconButton(
                key: const Key('insert-row'),
                tooltip: 'Insert default row',
                onPressed: widget.busy || object.type != 'table'
                    ? null
                    : widget.onInsert,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        if (!slice.hasRowid && object.type == 'table')
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('This table has no rowid. Change it with SQL.'),
          ),
        if (_facts(object).isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final fact in _facts(object))
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFE7F2EC),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Text(fact, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFD5E2DB)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: slice.rows.isEmpty && !filtering
                    ? const Center(child: Text('This table has no rows.'))
                    : CellGrid(
                        key: const Key('result-grid'),
                        columns: [
                          for (final column in slice.columns) column.name,
                        ],
                        filters: _filters,
                        rows: [
                          for (final index in visible)
                            slice.hasRowid
                                ? slice.rows[index].skip(1).toList()
                                : slice.rows[index],
                        ],
                        onCell: (index, column) =>
                            _edit(visible[index], column),
                        onDelete: slice.hasRowid
                            ? (index) => _delete(visible[index])
                            : null,
                      ),
              ),
            ),
          ),
        ),
        if (filtering && visible.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('No rows on this page match the filter.'),
          ),
        _pager(),
      ],
    );
  }

  Widget _pager() {
    final start = slice.rows.isEmpty ? slice.offset : slice.offset + 1;
    final end = slice.offset + slice.rows.length;
    final range =
        slice.totalKnown ? '$start–$end of ${slice.total}' : '$start–$end';
    return Material(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 12, 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              IconButton(
                key: const Key('page-first'),
                tooltip: 'First page',
                onPressed: widget.busy ? null : widget.onFirst,
                icon: const Icon(Icons.first_page),
              ),
              IconButton(
                key: const Key('page-previous'),
                tooltip: 'Previous',
                onPressed: widget.busy ? null : widget.onPrevious,
                icon: const Icon(Icons.chevron_left),
              ),
              Text(range, key: const Key('page-range')),
              IconButton(
                key: const Key('page-next'),
                tooltip: 'Next',
                onPressed: widget.busy ? null : widget.onNext,
                icon: const Icon(Icons.chevron_right),
              ),
              IconButton(
                key: const Key('page-last'),
                tooltip: 'Last page',
                onPressed: widget.busy ? null : widget.onLast,
                icon: const Icon(Icons.last_page),
              ),
              const SizedBox(width: 12),
              const Text('Go to'),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextField(
                  key: const Key('page-go'),
                  controller: _go,
                  enabled: !widget.busy && widget.onJump != null,
                  keyboardType: TextInputType.number,
                  onSubmitted: (_) => _submitGo(),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '1',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<int> _visibleRows() {
    final shown = <int>[];
    for (var index = 0; index < slice.rows.length; index++) {
      final source = slice.rows[index];
      final values = slice.hasRowid ? source.skip(1).toList() : source;
      if (_matches(values)) shown.add(index);
    }
    return shown;
  }

  bool _matches(List<Object?> values) {
    for (var column = 0;
        column < _filters.length && column < values.length;
        column++) {
      final query = _filters[column].text.trim().toLowerCase();
      if (query.isEmpty) continue;
      if (!formatCell(values[column]).toLowerCase().contains(query)) {
        return false;
      }
    }
    return true;
  }

  void _edit(int index, int column) {
    final source = slice.rows[index];
    final rowid = slice.hasRowid && source.first is BigInt
        ? source.first as BigInt
        : null;
    final edit = widget.onEdit;
    if (rowid == null || edit == null) return;
    final values = slice.hasRowid ? source.skip(1).toList() : source;
    edit(
      slice.columns[column],
      rowid,
      column < values.length ? values[column] : null,
    );
  }

  void _delete(int index) {
    final source = slice.rows[index];
    final remove = widget.onDelete;
    if (source.first is! BigInt || remove == null) return;
    remove(source.first as BigInt);
  }

  List<String> _facts(SchemaObject object) {
    final facts = <String>[];
    for (final column in object.columns) {
      final value = column.defaultValue;
      if (value != null && value.isNotEmpty) {
        facts.add('${column.name} default $value');
      }
    }
    for (final key in object.foreignKeys) {
      final target = key.to == null || key.to!.isEmpty
          ? key.table
          : '${key.table}.${key.to}';
      final actions = <String>[
        if (key.onUpdate.isNotEmpty &&
            key.onUpdate.toUpperCase() != 'NO ACTION')
          'ON UPDATE ${key.onUpdate}',
        if (key.onDelete.isNotEmpty &&
            key.onDelete.toUpperCase() != 'NO ACTION')
          'ON DELETE ${key.onDelete}',
      ];
      final action = actions.isEmpty ? '' : ' · ${actions.join(' · ')}';
      facts.add('${key.from} → $target$action');
    }
    for (final index in widget.catalog) {
      if (index.type != 'index' || index.table != object.name) continue;
      final columns = index.indexColumns.join(', ');
      final mark = index.unique ? 'UNIQUE ' : '';
      facts.add(
        columns.isEmpty
            ? '$mark${index.name}'
            : '$mark${index.name} ($columns)',
      );
    }
    for (final trigger in widget.catalog) {
      if (trigger.type == 'trigger' && trigger.table == object.name) {
        facts.add('trigger ${trigger.name}');
      }
    }
    return facts;
  }
}

class _IndexFacts extends StatelessWidget {
  const _IndexFacts({required this.object});

  final SchemaObject object;

  @override
  Widget build(BuildContext context) {
    final entries = object.entries;
    final size = object.byteSize;
    final columns = object.indexColumns.join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _stat(
              'Entries',
              entries == null ? 'Unknown' : '$entries',
              valueKey: const Key('index-entries'),
            ),
            _stat(
              'Size',
              size == null ? 'Unknown' : formatBytes(size),
              valueKey: const Key('index-size'),
            ),
            _stat('Table', object.table),
            if (columns.isNotEmpty) _stat('Columns', columns),
            if (object.unique) _stat('Kind', 'Unique'),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Entries count the keys stored in this index. Size is the pages it uses.',
          style: TextStyle(color: Color(0xFF5C6560), fontSize: 12),
        ),
      ],
    );
  }

  Widget _stat(String label, String value, {Key? valueKey}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFD6EBE4)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF5C6560),
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              key: valueKey,
              style: const TextStyle(
                color: Color(0xFF14211C),
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
