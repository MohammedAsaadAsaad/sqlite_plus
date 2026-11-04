import 'package:flutter/material.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

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
    this.loadRelated,
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

  /// Reads the rows of another table that match the values on this page.
  final Future<MatchedRows> Function({
    required String table,
    required String column,
    required List<Object?> values,
  })? loadRelated;

  @override
  State<DataPane> createState() => _DataPaneState();
}

class _DataPaneState extends State<DataPane> {
  final _go = TextEditingController();
  String? _linkColumn;
  ForeignKeyInfo? _linkKey;
  MatchedRows? _linkRows;
  var _linkBusy = false;
  String? _linkNote;

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
      _clearLink();
      return;
    }
    if (_linkColumn != null && oldWidget.slice != widget.slice) {
      _reloadLink();
    }
  }

  void _clearLink() {
    _linkColumn = null;
    _linkKey = null;
    _linkRows = null;
    _linkBusy = false;
    _linkNote = null;
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
                        linkedColumns: {
                          for (final key in object.foreignKeys) key.from,
                        },
                        onLink: widget.loadRelated == null ? null : _toggleLink,
                        openLink: _linkColumn,
                        relatedIndent: _relatedIndent(),
                        relatedWidth: _linkColumn == null ? 0 : _relatedWidth(),
                        relatedPanel:
                            _linkColumn == null ? null : _relatedPanel(),
                      ),
              ),
            ),
          ),
        ),
        _pager(),
      ],
    );
  }

  List<ForeignKeyInfo> _links(String column) {
    final object = widget.object;
    if (object == null) return const [];
    return [
      for (final key in object.foreignKeys)
        if (key.from == column) key,
    ];
  }

  List<Object?> _pageValues(String column) {
    final index = slice.columns.indexWhere((item) => item.name == column);
    if (index < 0) return const [];
    final values = <Object?>[];
    final seen = <String>{};
    for (final row in slice.rows) {
      final cellIndex = slice.hasRowid ? index + 1 : index;
      if (cellIndex >= row.length) continue;
      final value = row[cellIndex];
      if (value == null) continue;
      if (seen.add(value.toString())) values.add(value);
    }
    return values;
  }

  double _relatedIndent() {
    final name = _linkColumn;
    if (name == null) return 0;
    final index = slice.columns.indexWhere((item) => item.name == name);
    if (index < 0) return 0;
    return index * CellGrid.width;
  }

  double _relatedWidth() {
    final rows = _linkRows;
    final count =
        rows == null || rows.columns.isEmpty ? 1 : rows.columns.length;
    return count * _relatedCell + 36;
  }

  Future<void> _toggleLink(String column) async {
    if (_linkColumn == column && !_linkBusy) {
      setState(_clearLink);
      return;
    }
    final keys = _links(column);
    if (keys.isEmpty || widget.loadRelated == null) return;
    final chosen = keys.length == 1 ? keys.single : await _chooseLink(keys);
    if (!mounted || chosen == null) return;
    setState(() {
      _linkColumn = column;
      _linkKey = chosen;
      _linkRows = null;
      _linkBusy = true;
      _linkNote = null;
    });
    await _reloadLink();
  }

  Future<void> _reloadLink() async {
    final key = _linkKey;
    final column = _linkColumn;
    final load = widget.loadRelated;
    if (key == null || column == null || load == null) return;
    final target = key.to;
    if (target == null || target.isEmpty) {
      if (!mounted) return;
      setState(() {
        _linkBusy = false;
        _linkRows = MatchedRows.empty;
        _linkNote = 'This reference has no column.';
      });
      return;
    }
    try {
      final rows = await load(
        table: key.table,
        column: target,
        values: _pageValues(column),
      );
      if (!mounted || _linkColumn != column || _linkKey != key) return;
      setState(() {
        _linkRows = rows;
        _linkBusy = false;
        _linkNote = null;
      });
    } on SqlException catch (error) {
      if (!mounted || _linkColumn != column) return;
      setState(() {
        _linkBusy = false;
        _linkRows = MatchedRows.empty;
        _linkNote = error.message;
      });
    }
  }

  Future<ForeignKeyInfo?> _chooseLink(List<ForeignKeyInfo> keys) {
    return showDialog<ForeignKeyInfo>(
      context: context,
      builder: (context) => _RelatedChoiceDialog(keys: keys),
    );
  }

  Widget _relatedPanel() {
    final key = _linkKey;
    final target = key == null
        ? ''
        : (key.to == null || key.to!.isEmpty)
            ? key.table
            : '${key.table}.${key.to}';
    final rows = _linkRows;
    return _RelatedPanel(
      title: target,
      busy: _linkBusy,
      note: _linkNote,
      columns: rows?.columns ?? const [],
      rows: rows?.rows ?? const [],
      more: rows?.more ?? false,
      onClose: () => setState(_clearLink),
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

const _relatedCell = 140.0;

class _RelatedPanel extends StatelessWidget {
  const _RelatedPanel({
    required this.title,
    required this.busy,
    required this.note,
    required this.columns,
    required this.rows,
    required this.more,
    required this.onClose,
  });

  final String title;
  final bool busy;
  final String? note;
  final List<String> columns;
  final List<List<Object?>> rows;
  final bool more;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final width = (columns.isEmpty ? 1 : columns.length) * _relatedCell + 36;
    final bodyRows = rows.length > 4 ? 4 : rows.length;
    final height =
        busy || rows.isEmpty ? 92.0 : 36.0 + bodyRows * 32 + (more ? 22 : 0);
    return SizedBox(
      key: const Key('related-table'),
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Color(0xFFF4FBF7),
          border: Border(
            left: BorderSide(color: Color(0xFF0E7C66), width: 3),
            bottom: BorderSide(color: Color(0xFFD5E2DB)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 32,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.table_rows,
                    size: 14,
                    color: Color(0xFF0E7C66),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0E7C66),
                      ),
                    ),
                  ),
                  IconButton(
                    key: const Key('related-close'),
                    tooltip: 'Hide related rows',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 28, height: 28),
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 16),
                  ),
                ],
              ),
            ),
            Expanded(
              child: busy
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : rows.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          child: Text(
                            note ?? 'No related rows on this page.',
                            style: const TextStyle(
                              color: Color(0xFF5C6560),
                              fontSize: 12,
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: rows.length + (more ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == rows.length) {
                              return const Padding(
                                padding: EdgeInsets.fromLTRB(12, 2, 12, 4),
                                child: Text(
                                  'More rows were left out.',
                                  style: TextStyle(
                                    color: Color(0xFF5C6560),
                                    fontSize: 11,
                                  ),
                                ),
                              );
                            }
                            final row = rows[index];
                            return SizedBox(
                              height: 32,
                              child: Row(
                                children: [
                                  for (var column = 0;
                                      column < columns.length;
                                      column++)
                                    SizedBox(
                                      width: _relatedCell,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                        ),
                                        child: Text(
                                          formatCell(
                                            column < row.length
                                                ? row[column]
                                                : null,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RelatedChoiceDialog extends StatefulWidget {
  const _RelatedChoiceDialog({required this.keys});

  final List<ForeignKeyInfo> keys;

  @override
  State<_RelatedChoiceDialog> createState() => _RelatedChoiceDialogState();
}

class _RelatedChoiceDialogState extends State<_RelatedChoiceDialog> {
  late ForeignKeyInfo _choice = widget.keys.first;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Related rows',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                'This column references more than one column. Which one should the rows use?',
                style: TextStyle(color: Color(0xFF5C6560), fontSize: 13),
              ),
              const SizedBox(height: 8),
              RadioGroup<ForeignKeyInfo>(
                groupValue: _choice,
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _choice = value);
                },
                child: Column(
                  children: [
                    for (final key in widget.keys)
                      RadioListTile<ForeignKeyInfo>(
                        key: Key(
                          'related-choice-${key.table}-${key.to ?? ''}-${key.constraint}',
                        ),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: Text(_choiceLabel(key)),
                        value: key,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('related-load'),
                    onPressed: () => Navigator.of(context).pop(_choice),
                    child: const Text('Load'),
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

String _choiceLabel(ForeignKeyInfo key) {
  final column = key.to;
  if (column == null || column.isEmpty) return key.table;
  return '${key.table}.$column';
}
