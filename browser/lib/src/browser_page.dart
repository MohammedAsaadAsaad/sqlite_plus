import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:sqlite_plus/sqlite_plus.dart';

import 'cell_dialog.dart';
import 'data_pane.dart';
import 'format.dart';
import 'home_pane.dart';
import 'launch_bridge.dart';
import 'orm_dialog.dart';
import 'orm_export.dart';
import 'recent_files.dart';
import 'schema_graph.dart';
import 'schema_pane.dart';
import 'session.dart';
import 'sql_pane.dart';
import 'sql_view.dart';
import 'status_banner.dart';
import 'work_progress.dart';

enum BrowserPane { data, sql, graph }

/// Schema, rows, and a SQL editor. Wide windows keep the schema beside the work.
class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    required this.session,
    required this.recents,
  });

  final BrowserSession session;
  final RecentStore recents;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final _sql = TextEditingController();
  SchemaObject? _selected;
  TableSlice _slice = TableSlice.empty;
  StatementResult? _result;
  BrowserPane _pane = BrowserPane.data;
  PageNotice? _notice;
  String? _sortColumn;
  bool _sortAscending = true;
  final Map<String, String> _searches = {};
  bool _busy = false;
  bool _progressShown = false;
  OverlayEntry? _progressEntry;
  final List<String> _log = [];

  BrowserSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    LaunchBridge.listen(_onLaunched);
    widget.recents.load();
    _takeLaunch();
  }

  @override
  void dispose() {
    _removeProgress();
    _sql.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([session, widget.recents]),
      builder: (context, _) {
        final wide = MediaQuery.sizeOf(context).width >= 900;
        final open = session.isOpen;
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: open ? 68 : kToolbarHeight,
            bottom: const PreferredSize(
              preferredSize: Size.fromHeight(3),
              child: ColoredBox(
                color: Color(0xFF0E7C66),
                child: SizedBox(height: 3, width: double.infinity),
              ),
            ),
            title: _title(),
            actions: [
              PopupMenuButton<String>(
                key: const Key('more-menu'),
                tooltip: 'More',
                onSelected: (value) {
                  if (value == 'new') _newDatabase();
                  if (value == 'open') _openDatabase();
                  if (value == 'save') _saveDatabase();
                  if (value == 'sample') _sample();
                  if (value == 'models') _showModels();
                  if (value == 'close') _closeDatabase();
                },
                itemBuilder: (context) => [
                  _menuAction(
                    value: 'new',
                    icon: Icons.note_add_outlined,
                    label: 'New',
                    key: const Key('new-database'),
                    enabled: !_busy,
                  ),
                  _menuAction(
                    value: 'open',
                    icon: Icons.folder_open_outlined,
                    label: 'Open',
                    key: const Key('open-database'),
                    enabled: !_busy,
                  ),
                  _menuAction(
                    value: 'save',
                    icon: Icons.save_outlined,
                    label: 'Save',
                    key: const Key('save-database'),
                    enabled: open && !_busy,
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'sample',
                    enabled: !_busy,
                    child: const Text('Add sample rows'),
                  ),
                  if (open)
                    const PopupMenuItem(
                      value: 'models',
                      child: Text('Dart classes'),
                    ),
                  if (open)
                    const PopupMenuItem(
                      value: 'close',
                      child: Text('Close database'),
                    ),
                ],
              ),
            ],
          ),
          drawer: wide || !open
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
          body: open
              ? wide
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
                  : _work()
              : HomePane(
                  files: widget.recents.files,
                  onOpen: _busy ? () {} : _openDatabase,
                  onNew: _busy ? () {} : _newDatabase,
                  onRecent: _busy ? (_) {} : _openRecent,
                  onForget: (file) {
                    widget.recents.forget(file);
                  },
                ),
          bottomNavigationBar: wide || !open
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

  Widget _title() {
    final file = session.isOpen
        ? (session.dirty ? '${session.label} · unsaved' : session.label)
        : null;
    return Row(
      children: [
        if (MediaQuery.sizeOf(context).width >= 900) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              'assets/app_icon.png',
              width: 32,
              height: 32,
              filterQuality: FilterQuality.medium,
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'SQLite Browser',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              if (file != null)
                Text(
                  file,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF5C6560),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ],
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
        if (_notice != null)
          StatusBanner(
            notice: _notice!,
            onClose: () => setState(() => _notice = null),
          ),
        Expanded(
          child: _pane == BrowserPane.graph
              ? SchemaGraph(
                  objects: session.objects,
                  onOpen: _select,
                  onApply: _applySchema,
                  onApplyScript: _applyScript,
                )
              : _pane == BrowserPane.data
                  ? DataPane(
                      object: _selected,
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
                      sortColumn: _sortColumn,
                      sortAscending: _sortAscending,
                      searches: _searches,
                      onSort: _sortBy,
                      onSearch: _searchColumn,
                      onClearColumn: _clearColumn,
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
      _notice = null;
      _sortColumn = null;
      _sortAscending = true;
      _searches.clear();
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
        _notice = PageNotice(
          result.isQuery ? _queryMessage(result) : '${result.changes} changed',
          result.isQuery ? NoticeKind.note : NoticeKind.ok,
        );
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

  Future<void> _applyScript(List<String> statements) {
    final shown = statements.isEmpty ? null : _oneLine(statements.first);
    return _guard(() async {
      await session.runAll(statements);
      if (!mounted) return;
      setState(() {
        _notice = const PageNotice('Relationship saved', NoticeKind.ok);
        for (final statement in statements) {
          final line = _oneLine(statement);
          if (line == null || line.isEmpty) continue;
          _log.add(line);
        }
        while (_log.length > 12) {
          _log.removeAt(0);
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
    }, progress: shown);
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
      final slice = await session.slice(
        selected.name,
        offset: offset,
        orderBy: _sortColumn,
        ascending: _sortAscending,
        contains: _searches,
      );
      if (!mounted) return;
      setState(() => _slice = slice);
    });
    if (!mounted || _selected?.name != selected.name || _slice.totalKnown) {
      return;
    }
    final total = await session.countRows(
      selected.name,
      contains: _searches,
    );
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

  Future<void> _runSql({int? offset}) async {
    final current = _result;
    if (offset != null && current != null && current.cached != null) {
      final page = current.window(offset);
      setState(() {
        _result = page;
        _notice = PageNotice(_queryMessage(page), NoticeKind.note);
      });
      return;
    }
    if (offset == null && _removesData(_sql.text)) {
      final words = sqlWords(_sql.text);
      final drop = words.isNotEmpty && words.first == 'drop';
      final proceed = await _confirmDelete(
        drop ? 'Drop this object?' : 'Delete these rows?',
        _oneLine(_sql.text) ?? '',
        drop: drop,
      );
      if (!proceed || !mounted) return;
    }
    await _guard(() async {
      final result = await session.run(_sql.text, offset: offset ?? 0);
      if (!mounted) return;
      final statement = _sql.text.trim();
      setState(() {
        _result = result;
        _notice = PageNotice(
          result.isQuery ? _queryMessage(result) : '${result.changes} changed',
          result.isQuery ? NoticeKind.note : NoticeKind.ok,
        );
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

  bool _removesData(String sql) {
    final words = sqlWords(sql);
    if (words.isEmpty) return false;
    final first = words.first;
    return first == 'delete' || first == 'drop';
  }

  Future<void> _insert() {
    final selected = _selected;
    if (selected == null || selected.type != 'table') return Future.value();
    return _guard(() async {
      await session.insertDefault(selected.name);
      await _load(_slice.offset);
    });
  }

  Future<void> _delete(BigInt rowid) async {
    final selected = _selected;
    if (selected == null) return;
    final proceed = await _confirmDelete(
      'Delete this row?',
      'This removes one row from ${selected.name}.',
    );
    if (!proceed || !mounted) return;
    await _guard(() async {
      await session.deleteRow(selected.name, rowid);
      await _load(_slice.offset);
    });
  }

  Future<bool> _confirmDelete(
    String title,
    String body, {
    bool drop = false,
  }) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(
          Icons.warning_amber_rounded,
          color: Color(0xFFC4473A),
          size: 32,
        ),
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            key: const Key('delete-dismiss'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-delete'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFC4473A),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(drop ? 'Drop' : 'Delete'),
          ),
        ],
      ),
    );
    return answer ?? false;
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
    if (!session.isOpen) return Future.value();
    return _guard(() async {
      await session.insertSample();
      final books = session.objects.where((object) => object.name == 'books');
      if (books.isEmpty || !mounted) return;
      await _select(books.single);
    });
  }

  Future<void> _showModels() {
    return showDialog<void>(
      context: context,
      builder: (context) => ModelsDialog(
        source: ormModels(session.objects),
        onSave: _saveModels,
      ),
    );
  }

  Future<String?> _saveModels(String source) async {
    final bytes = Uint8List.fromList(utf8.encode(source));
    final saved = await _chooseSavePath('models.dart', bytes);
    if (saved == null) return null;
    final file = File(saved);
    if (!file.existsSync() || file.lengthSync() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    final leaf = saved.split(RegExp(r'[/\\]')).last;
    return leaf.isEmpty ? 'models.dart' : leaf;
  }

  Future<void> _closeDatabase() async {
    if (!session.isOpen) return;
    if (!await _confirmDiscard()) return;
    await _guard(() async {
      await session.close();
      if (!mounted) return;
      setState(() {
        _selected = null;
        _slice = TableSlice.empty;
        _result = null;
        _notice = null;
        _log.clear();
        _sortColumn = null;
        _sortAscending = true;
        _searches.clear();
        _pane = BrowserPane.data;
      });
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
        _notice = null;
        _log.clear();
        _sortColumn = null;
        _sortAscending = true;
        _searches.clear();
      });
    });
  }

  Future<void> _sortBy(String column, bool ascending) {
    _sortColumn = column;
    _sortAscending = ascending;
    return _load(0);
  }

  Future<void> _searchColumn(String column, String query) {
    final text = query.trim();
    if (text.isEmpty) {
      _searches.remove(column);
    } else {
      _searches[column] = text;
    }
    return _load(0);
  }

  Future<void> _clearColumn(String column) {
    _searches.remove(column);
    if (_sortColumn == column) _sortColumn = null;
    return _load(0);
  }

  Future<void> _takeLaunch() async {
    final opened = await LaunchBridge.takeLaunch();
    if (opened == null || !mounted || session.isOpen) return;
    await _openImage(opened.bytes, opened.name, location: opened.location);
  }

  Future<void> _onLaunched(OpenedFile opened) async {
    if (!mounted || _busy) return;
    if (session.isOpen && !await _confirmDiscard()) return;
    await _openImage(opened.bytes, opened.name, location: opened.location);
  }

  Future<void> _openRecent(RecentFile file) async {
    if (session.isOpen && !await _confirmDiscard()) return;
    try {
      final bytes = await widget.recents.read(file);
      await _openImage(bytes, file.name, location: file.location);
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _openImage(
    Uint8List bytes,
    String name, {
    String? location,
  }) async {
    await _guard(() async {
      await session.openBytes(bytes, label: name);
      if (!mounted) return;
      setState(() {
        _selected = null;
        _slice = TableSlice.empty;
        _result = null;
        _notice = null;
        _log.clear();
        _sortColumn = null;
        _sortAscending = true;
        _searches.clear();
      });
    });
    if (!session.isOpen || session.label != name) return;
    try {
      await widget.recents.remember(
        name: name,
        bytes: bytes,
        location: location,
      );
    } catch (error) {
      _showMessage('$error');
    }
  }

  Future<void> _openDatabase() async {
    if (session.isOpen && !await _confirmDiscard()) return;
    final picked = await FilePicker.platform.pickFiles(withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.single;
    final bytes = file.bytes;
    if (bytes == null) {
      _showMessage('This platform did not return the file bytes.');
      return;
    }
    final path = file.path;
    final location =
        path != null && path.isNotEmpty && !path.startsWith('content:')
            ? path
            : null;
    await _openImage(bytes, file.name, location: location);
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
    final stored = leaf.isEmpty ? name : leaf;
    session.markSaved(stored);
    try {
      await widget.recents.remember(
        name: stored,
        bytes: bytes,
        location: saved,
      );
    } catch (error) {
      _showMessage('$error');
      return;
    }
    if (!mounted) return;
    setState(() => _notice = PageNotice('Saved $stored', NoticeKind.ok));
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
      }
    });
    if (progress != null) {
      _showProgress(progress);
      await _afterPaint();
    }
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
      _removeProgress();
      if (mounted) {
        setState(() {
          _busy = false;
          _progressShown = false;
        });
      }
    }
  }

  /// Paints the running card on the root overlay, above the drawer and dialogs.
  void _showProgress(String? progress) {
    _removeProgress();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (context) => WorkProgress(detail: progress),
    );
    _progressEntry = entry;
    overlay.insert(entry);
  }

  void _removeProgress() {
    _progressEntry?.remove();
    _progressEntry = null;
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
    setState(() => _notice = PageNotice(text, NoticeKind.error));
  }
}

PopupMenuItem<String> _menuAction({
  required String value,
  required IconData icon,
  required String label,
  required Key key,
  required bool enabled,
}) {
  return PopupMenuItem<String>(
    key: key,
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Text(label),
      ],
    ),
  );
}
