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
    this.sortColumn,
    this.sortAscending = true,
    this.searches = const {},
    this.onSort,
    this.onSearch,
    this.onClearColumn,
  });

  final SchemaObject? object;
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
  final String? sortColumn;
  final bool sortAscending;
  final Map<String, String> searches;
  final void Function(String column, bool ascending)? onSort;
  final void Function(String column, String query)? onSearch;
  final ValueChanged<String>? onClearColumn;

  @override
  State<DataPane> createState() => _DataPaneState();
}

class _DataPaneState extends State<DataPane> {
  final _go = TextEditingController();

  TableSlice get slice => widget.slice;

  bool get _searching =>
      widget.searches.values.any((value) => value.trim().isNotEmpty);

  @override
  void didUpdateWidget(DataPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.object;
    final next = widget.object;
    if (previous?.name != next?.name || previous?.type != next?.type) {
      _go.clear();
    }
  }

  @override
  void dispose() {
    _go.dispose();
    super.dispose();
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
                child: slice.rows.isEmpty
                    ? Center(
                        child: Text(
                          _searching
                              ? 'No rows match this search.'
                              : 'This table has no rows.',
                        ),
                      )
                    : CellGrid(
                        key: const Key('result-grid'),
                        columns: [
                          for (final column in slice.columns) column.name,
                        ],
                        sortColumn: widget.sortColumn,
                        sortAscending: widget.sortAscending,
                        searched: {
                          for (final entry in widget.searches.entries)
                            if (entry.value.trim().isNotEmpty) entry.key,
                        },
                        onColumn: widget.busy ? null : _columnMenu,
                        rows: [
                          for (final row in slice.rows)
                            slice.hasRowid ? row.skip(1).toList() : row,
                        ],
                        onCell: _edit,
                        onDelete: slice.hasRowid ? _delete : null,
                      ),
              ),
            ),
          ),
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

  Future<void> _columnMenu(String name) async {
    final result = await showDialog<_ColumnMenuResult>(
      context: context,
      builder: (context) => _ColumnMenu(
        name: name,
        search: widget.searches[name] ?? '',
      ),
    );
    if (result == null || !mounted) return;
    if (result.clear) {
      widget.onClearColumn?.call(name);
      return;
    }
    final ascending = result.ascending;
    if (ascending != null) {
      widget.onSort?.call(name, ascending);
      return;
    }
    final query = result.search;
    if (query != null) widget.onSearch?.call(name, query);
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

class _ColumnMenuResult {
  const _ColumnMenuResult.sort(this.ascending)
      : search = null,
        clear = false;

  const _ColumnMenuResult.search(this.search)
      : ascending = null,
        clear = false;

  const _ColumnMenuResult.clear()
      : ascending = null,
        search = null,
        clear = true;

  final bool? ascending;
  final String? search;
  final bool clear;
}

class _ColumnMenu extends StatefulWidget {
  const _ColumnMenu({required this.name, required this.search});

  final String name;
  final String search;

  @override
  State<_ColumnMenu> createState() => _ColumnMenuState();
}

class _ColumnMenuState extends State<_ColumnMenu> {
  late final TextEditingController _search =
      TextEditingController(text: widget.search);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width < 420
        ? MediaQuery.sizeOf(context).width - 48
        : 360.0;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: width,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.name,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF14211C),
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Sort this column, or search the whole table.',
                style: TextStyle(color: Color(0xFF5C6560), fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('column-sort-asc'),
                      onPressed: () => Navigator.of(context)
                          .pop(const _ColumnMenuResult.sort(true)),
                      icon: const Icon(Icons.arrow_upward, size: 16),
                      label: const Text('A to Z'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const Key('column-sort-desc'),
                      onPressed: () => Navigator.of(context)
                          .pop(const _ColumnMenuResult.sort(false)),
                      icon: const Icon(Icons.arrow_downward, size: 16),
                      label: const Text('Z to A'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('column-search'),
                controller: _search,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (value) =>
                    Navigator.of(context).pop(_ColumnMenuResult.search(value)),
                decoration: const InputDecoration(
                  labelText: 'Search',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('column-clear'),
                    onPressed: () => Navigator.of(context)
                        .pop(const _ColumnMenuResult.clear()),
                    child: const Text('Clear'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('column-search-apply'),
                    onPressed: () => Navigator.of(context)
                        .pop(_ColumnMenuResult.search(_search.text)),
                    child: const Text('Search'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
