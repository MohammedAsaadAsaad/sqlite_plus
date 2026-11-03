import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

import 'data_pane.dart';
import 'format.dart';
import 'schema_pane.dart';
import 'session.dart';
import 'sql_pane.dart';

enum BrowserPane { data, sql }

/// Schema, rows, and a SQL editor. Wide windows keep the schema beside the work.
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, required this.session});

  final BrowserSession session;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final _sql = TextEditingController();
  SchemaObject? _selected;
  TableSlice _slice = TableSlice.empty;
  StatementResult? _result;
  BrowserPane _pane = BrowserPane.data;
  String? _message;
  bool _busy = false;

  BrowserSession get session => widget.session;

  @override
  void dispose() {
    _sql.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(
                session.dirty ? '${session.label} · unsaved' : session.label),
            actions: [
              IconButton(
                key: const Key('new-database'),
                tooltip: 'New',
                onPressed: _busy ? null : _newDatabase,
                icon: const Icon(Icons.note_add_outlined),
              ),
              IconButton(
                key: const Key('open-database'),
                tooltip: 'Open',
                onPressed: _busy ? null : _openDatabase,
                icon: const Icon(Icons.folder_open_outlined),
              ),
              IconButton(
                key: const Key('save-database'),
                tooltip: 'Save',
                onPressed: _busy ? null : _saveDatabase,
                icon: const Icon(Icons.save_outlined),
              ),
              PopupMenuButton<String>(
                key: const Key('more-menu'),
                onSelected: (value) {
                  if (value == 'sample') _sample();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(
                      value: 'sample', child: Text('Add sample rows')),
                ],
              ),
            ],
          ),
          drawer: wide
              ? null
              : Drawer(
                  child: SafeArea(
                    child: SchemaPane(
                      objects: session.objects,
                      selected: _selected,
                      onSelect: (object) {
                        Navigator.of(context).pop();
                        _select(object);
                      },
                    ),
                  ),
                ),
          body: wide
              ? Row(
                  children: [
                    ColoredBox(
                      color: Colors.white,
                      child: SizedBox(
                        width: 300,
                        child: SchemaPane(
                          objects: session.objects,
                          selected: _selected,
                          onSelect: _select,
                        ),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _work()),
                  ],
                )
              : _work(),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _pane == BrowserPane.data ? 0 : 1,
                  onDestinationSelected: (index) {
                    setState(() {
                      _pane = index == 0 ? BrowserPane.data : BrowserPane.sql;
                    });
                  },
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.table_rows_outlined),
                      label: 'Rows',
                      key: Key('pane-rows'),
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.code),
                      label: 'SQL',
                      key: Key('pane-sql'),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _work() {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide) _paneSwitch(),
        if (_busy) const LinearProgressIndicator(minHeight: 2),
        if (_message != null)
          Material(
            color: const Color(0xFFE7F2EC),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_message!),
            ),
          ),
        Expanded(
          child: _pane == BrowserPane.data
              ? DataPane(
                  object: _selected,
                  slice: _slice,
                  busy: _busy,
                  onPrevious: _slice.offset == 0 ? null : () => _move(-1),
                  onNext: _hasNext ? () => _move(1) : null,
                  onInsert: _selected == null ? null : _insert,
                  onEdit: _edit,
                  onDelete: _delete,
                  onShowSql: _showSql,
                )
              : SqlPane(
                  controller: _sql,
                  objects: session.objects,
                  result: _result,
                  busy: _busy,
                  onRun: _runSql,
                ),
        ),
      ],
    );
  }

  Widget _paneSwitch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SegmentedButton<BrowserPane>(
        segments: const [
          ButtonSegment(
            value: BrowserPane.data,
            label: Text('Rows'),
            icon: Icon(Icons.table_rows_outlined),
          ),
          ButtonSegment(
            value: BrowserPane.sql,
            label: Text('SQL'),
            icon: Icon(Icons.code),
          ),
        ],
        selected: {_pane},
        onSelectionChanged: (value) => setState(() => _pane = value.single),
      ),
    );
  }

  Future<void> _select(SchemaObject object) async {
    setState(() {
      _selected = object;
      _pane = BrowserPane.data;
      _message = null;
    });
    if (object.type == 'table' || object.type == 'view') {
      await _load(0);
    } else {
      setState(() => _slice = TableSlice.empty);
    }
  }

  bool get _hasNext {
    if (_slice.totalKnown) {
      return _slice.offset + _slice.rows.length < _slice.total;
    }
    return _slice.rows.length == _slice.limit && _slice.limit > 0;
  }

  Future<void> _load(int offset) async {
    final selected = _selected;
    if (selected == null) return;
    if (selected.type != 'table' && selected.type != 'view') return;
    await _guard(() async {
      final slice = await session.slice(selected.name, offset: offset);
      if (!mounted) return;
      setState(() => _slice = slice);
    });
    if (!mounted || _selected?.name != selected.name || _slice.totalKnown) {
      return;
    }
    final total = await session.countRows(selected.name);
    if (!mounted || _selected?.name != selected.name) return;
    setState(() {
      _slice = TableSlice(
        columns: _slice.columns,
        rows: _slice.rows,
        hasRowid: _slice.hasRowid,
        total: total,
        offset: _slice.offset,
        limit: _slice.limit,
      );
    });
  }

  Future<void> _move(int direction) {
    final next = _slice.offset + direction * _slice.limit;
    return _load(next < 0 ? 0 : next);
  }

  Future<void> _runSql() {
    return _guard(() async {
      final result = await session.run(_sql.text);
      if (!mounted) return;
      setState(() {
        _result = result;
        _message = result.isQuery
            ? '${result.rows.length} rows'
            : '${result.changes} changed';
      });
      final selected = _selected;
      if (selected != null &&
          session.objects.any((object) => object.name == selected.name)) {
        _selected = session.objects.firstWhere(
          (object) => object.name == selected.name,
        );
        await _load(_slice.offset);
      } else if (selected != null) {
        setState(() {
          _selected = null;
          _slice = TableSlice.empty;
        });
      }
    });
  }

  Future<void> _insert() {
    final selected = _selected;
    if (selected == null || selected.type != 'table') return Future.value();
    return _guard(() async {
      await session.insertDefault(selected.name);
      await _load(_slice.offset);
    });
  }

  Future<void> _delete(BigInt rowid) {
    final selected = _selected;
    if (selected == null) return Future.value();
    return _guard(() async {
      await session.deleteRow(selected.name, rowid);
      await _load(_slice.offset);
    });
  }

  Future<void> _edit(ColumnInfo column, BigInt rowid, Object? current) async {
    if (current is List<int>) {
      _showMessage('This cell is ${current.length} bytes. Edit it with SQL.');
      return;
    }
    final edited = await showDialog<_CellEdit>(
      context: context,
      builder: (context) => _CellDialog(column: column.name, current: current),
    );
    if (edited == null || !mounted) return;
    final selected = _selected;
    if (selected == null) return;
    await _guard(() async {
      await session.updateCell(selected.name, rowid, column.name, edited.value);
      await _load(_slice.offset);
    });
  }

  Future<void> _showSql() async {
    final sql = _selected?.sql;
    if (sql == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_selected!.name),
        content: SingleChildScrollView(child: SelectableText(sql)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _sample() {
    return _guard(() async {
      await session.insertSample();
      final books = session.objects.where((object) => object.name == 'books');
      if (books.isEmpty || !mounted) return;
      await _select(books.single);
    });
  }

  Future<void> _newDatabase() async {
    if (!await _confirmDiscard()) return;
    await _guard(() async {
      await session.openEmpty();
      if (!mounted) return;
      setState(() {
        _selected = null;
        _slice = TableSlice.empty;
        _result = null;
        _message = null;
      });
    });
  }

  Future<void> _openDatabase() async {
    if (!await _confirmDiscard()) return;
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _showMessage('This platform did not return the file bytes.');
      return;
    }
    await _guard(() async {
      await session.openBytes(bytes, label: file.name);
      if (!mounted) return;
      setState(() {
        _selected = null;
        _slice = TableSlice.empty;
        _result = null;
        _message = null;
      });
    });
  }

  Future<void> _saveDatabase() async {
    late final Uint8List bytes;
    try {
      bytes = session.exportBytes();
    } on StateError catch (error) {
      _showMessage('$error');
      return;
    }
    final name = session.label == 'Memory' ? 'database.db' : session.label;
    final saved = await _chooseSavePath(name, bytes);
    if (saved == null) return;
    final file = File(saved);
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    final leaf = saved.split(RegExp(r'[/\\]')).last;
    session.markSaved(leaf.isEmpty ? name : leaf);
    _showMessage('Saved $leaf');
  }

  Future<String?> _chooseSavePath(String name, Uint8List bytes) async {
    try {
      return await FilePicker.platform.saveFile(fileName: name, bytes: bytes);
    } on UnsupportedError {
      return FilePicker.platform.saveFile(fileName: name);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!session.dirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unsaved changes'),
        content:
            const Text('The open database has changes that are not saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay'),
          ),
          TextButton(
            key: const Key('discard-changes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

  Future<void> _guard(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } on SqlException catch (error) {
      _showMessage(error.message);
    } on UnsupportedError catch (error) {
      _showMessage('${error.message}');
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    setState(() => _message = text);
  }
}

class _CellEdit {
  const _CellEdit(this.value);
  final Object? value;
}

class _CellDialog extends StatefulWidget {
  const _CellDialog({required this.column, required this.current});

  final String column;
  final Object? current;

  @override
  State<_CellDialog> createState() => _CellDialogState();
}

class _CellDialogState extends State<_CellDialog> {
  late final TextEditingController _text = TextEditingController(
    text: editableText(widget.current),
  );
  late bool _nullValue = widget.current == null;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.column),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('cell-editor'),
            controller: _text,
            enabled: !_nullValue,
            autofocus: true,
          ),
          CheckboxListTile(
            key: const Key('cell-null'),
            contentPadding: EdgeInsets.zero,
            title: const Text('NULL'),
            value: _nullValue,
            onChanged: (value) => setState(() => _nullValue = value ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const Key('cell-save'),
          onPressed: () {
            Navigator.of(context).pop(
              _CellEdit(parseCell(_text.text, nullWord: _nullValue)),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
