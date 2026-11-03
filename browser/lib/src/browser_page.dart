import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

import 'cell_dialog.dart';
import 'data_pane.dart';
import 'schema_graph.dart';
import 'schema_pane.dart';
import 'session.dart';
import 'sql_pane.dart';
import 'sql_view.dart';
import 'work_progress.dart';

enum BrowserPane { data, sql, graph }

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
  bool _progressShown = false;
  String? _progressDetail;
  final List<String> _log = [];

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
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(3),
              child: ColoredBox(
                color: Color(0xFF0E7C66),
                child: SizedBox(height: 3, width: double.infinity),
              ),
            ),
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
                      onApply: _applySchema,
                    ),
                  ),
                ),
          body: Stack(
            children: [
              wide
                  ? Row(
                      children: [
                        SizedBox(
                          width: 620,
                          child: SchemaPane(
                            objects: session.objects,
                            selected: _selected,
                            onSelect: _select,
                            onApply: _applySchema,
                          ),
                        ),
                        Expanded(child: _work()),
                      ],
                    )
                  : _work(),
              if (_progressShown)
                Positioned.fill(
                  child: WorkProgress(detail: _progressDetail),
                ),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : NavigationBar(
                  selectedIndex: _paneIndex,
                  onDestinationSelected: (index) {
                    if (_busy) return;
                    setState(() => _pane = BrowserPane.values[index]);
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
                    NavigationDestination(
                      icon: Icon(Icons.account_tree_outlined),
                      label: 'Graph',
                      key: Key('pane-graph'),
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
        if (_busy && !_progressShown)
          const LinearProgressIndicator(
            minHeight: 3,
            color: Color(0xFF0E7C66),
            backgroundColor: Color(0xFFD6EBE4),
          ),
        if (_message != null)
          Material(
            color: const Color(0xFFE7F2EC),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(_message!),
            ),
          ),
        Expanded(
          child: _pane == BrowserPane.graph
              ? SchemaGraph(
                  objects: session.objects,
                  onOpen: _select,
                  onApply: _applySchema,
                )
              : _pane == BrowserPane.data
                  ? DataPane(
                      object: _selected,
                      catalog: session.objects,
                      slice: _slice,
                      busy: _busy,
                      onFirst: _slice.offset == 0 ? null : () => _load(0),
                      onPrevious: _slice.offset == 0 ? null : () => _move(-1),
                      onNext: _hasNext ? () => _move(1) : null,
                      onLast: _lastOffset == null
                          ? null
                          : () => _load(_lastOffset!),
                      onJump: _jump,
                      onInsert: _selected == null ? null : _insert,
                      onEdit: _edit,
                      onDelete: _delete,
                      onShowSql: _showSql,
                    )
                  : SqlPane(
                      controller: _sql,
                      objects: session.objects,
                      result: _result,
                      log: _log,
                      busy: _busy,
                      onRun: () => _runSql(),
                      onPrevious: _result != null && _result!.offset > 0
                          ? () =>
                              _runSql(offset: _result!.offset - _result!.limit)
                          : null,
                      onNext: _result != null && _result!.more
                          ? () =>
                              _runSql(offset: _result!.offset + _result!.limit)
                          : null,
                    ),
        ),
      ],
    );
  }

  Widget _paneSwitch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<BrowserPane>(
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return const Color(0xFF0E7C66);
                }
                return Colors.white;
              }),
              foregroundColor: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) return Colors.white;
                return const Color(0xFF14211C);
              }),
              side: const WidgetStatePropertyAll(
                BorderSide(color: Color(0xFFD5E2DB)),
              ),
            ),
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
              ButtonSegment(
                value: BrowserPane.graph,
                label: Text('Graph'),
                icon: Icon(Icons.account_tree_outlined),
              ),
            ],
            selected: {_pane},
            onSelectionChanged: (value) {
              if (_busy) return;
              setState(() => _pane = value.single);
            },
          ),
        ),
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

  int? get _lastOffset {
    if (!_slice.totalKnown || _slice.total <= 0 || _slice.limit <= 0) {
      return null;
    }
    final last = ((_slice.total - 1) ~/ _slice.limit) * _slice.limit;
    if (last == _slice.offset) return null;
    return last;
  }

  void _jump(int page) {
    if (_slice.limit <= 0) return;
    var offset = (page - 1) * _slice.limit;
    if (offset < 0) offset = 0;
    if (_slice.totalKnown && _slice.total > 0) {
      final last = ((_slice.total - 1) ~/ _slice.limit) * _slice.limit;
      if (offset > last) offset = last;
    }
    _load(offset);
  }

  String _queryMessage(StatementResult result) {
    if (result.rows.isEmpty) return '0 rows';
    final start = result.offset + 1;
    final end = result.offset + result.rows.length;
    if (!result.more && result.offset == 0) return '${result.rows.length} rows';
    return '$start–$end';
  }

  int get _paneIndex => switch (_pane) {
        BrowserPane.data => 0,
        BrowserPane.sql => 1,
        BrowserPane.graph => 2,
      };

  Future<void> _applySchema(String sql) {
    return _guard(() async {
      final result = await session.run(sql);
      if (!mounted) return;
      setState(() {
        _message = result.isQuery
            ? _queryMessage(result)
            : '${result.changes} changed';
        final statement = sql.trim().replaceAll(RegExp(r'\s+'), ' ');
        if (statement.isNotEmpty) {
          _log.add(statement);
          if (_log.length > 12) _log.removeAt(0);
        }
      });
      final selected = _selected;
      if (selected != null &&
          session.objects.any(
            (object) =>
                object.name == selected.name && object.type == selected.type,
          )) {
        _selected = session.objects.firstWhere(
          (object) =>
              object.name == selected.name && object.type == selected.type,
        );
        if (_selected!.type == 'table' || _selected!.type == 'view') {
          await _load(_slice.offset);
        }
      }
    }, progress: _oneLine(sql));
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

  Future<void> _runSql({int? offset}) {
    final current = _result;
    if (offset != null && current != null && current.cached != null) {
      final page = current.window(offset);
      setState(() {
        _result = page;
        _message = _queryMessage(page);
      });
      return Future.value();
    }
    return _guard(() async {
      final result = await session.run(_sql.text, offset: offset ?? 0);
      if (!mounted) return;
      final statement = _sql.text.trim();
      setState(() {
        _result = result;
        _message = result.isQuery
            ? _queryMessage(result)
            : '${result.changes} changed';
        if (offset == null && statement.isNotEmpty) {
          _log.add(statement.replaceAll(RegExp(r'\s+'), ' '));
          if (_log.length > 12) _log.removeAt(0);
        }
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
    }, progress: _oneLine(_sql.text));
  }

  String? _oneLine(String sql) {
    final collapsed = sql.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (collapsed.isEmpty) return null;
    return collapsed;
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
    final edited = await showDialog<CellEdit>(
      context: context,
      builder: (context) => CellDialog(column: column, current: current),
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
    final name = _selected!.name;
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                SqlCodeView(source: formatSql(sql)),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
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
        _log.clear();
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
        _log.clear();
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

  Future<void> _guard(
    Future<void> Function() body, {
    String? progress,
  }) async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      if (progress != null) {
        _progressShown = true;
        _progressDetail = progress;
      }
    });
    if (progress != null) await _afterPaint();
    if (!mounted) return;
    try {
      await body();
    } on SqlException catch (error) {
      _showMessage(error.message);
    } on UnsupportedError catch (error) {
      _showMessage('${error.message}');
    } catch (error) {
      _showMessage('$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _progressShown = false;
          _progressDetail = null;
        });
      }
    }
  }

  /// Waits until the progress card has been built and painted.
  Future<void> _afterPaint() {
    final binding = WidgetsBinding.instance;
    final done = Completer<void>();
    binding.addPostFrameCallback((_) {
      binding.addPostFrameCallback((_) {
        if (!done.isCompleted) done.complete();
      });
      binding.scheduleFrame();
    });
    binding.scheduleFrame();
    return done.future;
  }

  void _showMessage(String text) {
    if (!mounted) return;
    setState(() => _message = text);
  }
}
