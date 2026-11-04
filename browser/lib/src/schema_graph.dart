import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'graph_layout.dart';
import 'object_dialogs.dart';
import 'schema_sql.dart';
import 'session.dart';

/// Tables on a board that pans and zooms.
///
/// A table moves when it is dragged. After a column is chosen, only a key
/// column on another table stays available. The link is written after it is
/// confirmed.
class SchemaGraph extends StatefulWidget {
  const SchemaGraph({
    super.key,
    required this.objects,
    required this.onOpen,
    required this.onApply,
    required this.onApplyScript,
    this.layouts,
    this.layoutKey,
    this.onLayout,
  });

  final List<SchemaObject> objects;
  final ValueChanged<SchemaObject> onOpen;
  final Future<void> Function(String sql) onApply;
  final Future<void> Function(List<String> statements) onApplyScript;

  /// Saved card positions. Null keeps the arrangement in this widget only.
  final GraphLayoutStore? layouts;

  /// Filesystem path or content URI of the open database. Null is a memory
  /// database, and its arrangement is not written.
  final String? layoutKey;

  /// The positions after a drag or after tables are added or removed.
  final ValueChanged<Map<String, GraphPoint>>? onLayout;

  @override
  State<SchemaGraph> createState() => _SchemaGraphState();
}

class _Picked {
  const _Picked(this.table, this.column);

  final String table;
  final String column;
}

class _SchemaGraphState extends State<SchemaGraph> {
  final Map<String, Offset> _positions = {};
  final Map<int, Offset> _pointers = {};
  String? _appliedKey;
  var _loaded = false;
  var _persistQueued = false;
  Offset _origin = Offset.zero;
  Size _view = Size.zero;
  double _scale = 1;
  double _pinchDistance = 0;
  double _pinchScale = 1;
  _Picked? _picked;
  String? _cardDrag;

  List<SchemaObject> get _tables => [
        for (final object in widget.objects)
          if (object.type == 'table') object,
      ];

  @override
  void didUpdateWidget(SchemaGraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layoutKey != widget.layoutKey) {
      _appliedKey = widget.layoutKey;
      _persist();
    }
  }

  void _loadStored() {
    if (_loaded && _appliedKey == widget.layoutKey) return;
    if (!_loaded) {
      _positions
        ..clear()
        ..addAll(_storedOffsets());
      _loaded = true;
    }
    _appliedKey = widget.layoutKey;
  }

  Map<String, Offset> _storedOffsets() {
    final saved = widget.layouts?.read(widget.layoutKey) ?? const {};
    return {
      for (final entry in saved.entries)
        entry.key: Offset(entry.value.x, entry.value.y),
    };
  }

  void _schedulePersist() {
    if (_persistQueued) return;
    _persistQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _persistQueued = false;
      if (!mounted) return;
      _persist();
    });
  }

  void _persist() {
    final points = {
      for (final entry in _positions.entries)
        entry.key: GraphPoint(entry.value.dx, entry.value.dy),
    };
    widget.onLayout?.call(points);
    final key = widget.layoutKey;
    final store = widget.layouts;
    if (key == null || key.isEmpty || store == null) return;
    store.save(key, points);
  }

  void _placeNew(List<SchemaObject> tables) {
    _loadStored();
    final layout = _layout(tables, 960);
    final names = {for (final table in tables) table.name};
    final before = _positions.keys.toSet();
    _positions.removeWhere((name, _) => !names.contains(name));
    var added = false;
    for (final table in tables) {
      if (_positions.containsKey(table.name)) continue;
      added = true;
      _positions[table.name] =
          layout.rects[table.name]?.topLeft ?? const Offset(24, 24);
    }
    if (before.difference(names).isNotEmpty || added) {
      _schedulePersist();
    }
    final picked = _picked;
    if (picked != null &&
        !tables.any(
          (table) =>
              table.name == picked.table &&
              table.columns.any((column) => column.name == picked.column),
        )) {
      _picked = null;
    }
  }

  Map<String, Rect> _rects(List<SchemaObject> tables) {
    return {
      for (final table in tables)
        table.name: Rect.fromLTWH(
          _positions[table.name]?.dx ?? 24,
          _positions[table.name]?.dy ?? 24,
          _cardWidth,
          _header + table.columns.length * _row,
        ),
    };
  }

  Size _canvas(Map<String, Rect> rects) {
    var width = 1680.0;
    var height = 1100.0;
    for (final rect in rects.values) {
      width = math.max(width, rect.right + 120);
      height = math.max(height, rect.bottom + 120);
    }
    return Size(width, height);
  }

  Offset _clampOrigin(Offset origin, Size canvas) {
    final view = _view;
    if (view.isEmpty) return origin;
    final width = canvas.width * _scale;
    final height = canvas.height * _scale;
    final minX = math.min(0.0, view.width - width);
    final minY = math.min(0.0, view.height - height);
    return Offset(
      origin.dx.clamp(minX, 0).toDouble(),
      origin.dy.clamp(minY, 0).toDouble(),
    );
  }

  void _zoomTo(double next, Offset focal, Size canvas) {
    final scale = next.clamp(0.45, 2.6);
    final scene = (focal - _origin) / _scale;
    final origin = focal - scene * scale;
    setState(() {
      _scale = scale;
      _origin = _clampOrigin(origin, canvas);
    });
  }

  void _zoomStep(double factor, Size canvas) {
    _zoomTo(
      _scale * factor,
      Offset(_view.width / 2, _view.height / 2),
      canvas,
    );
  }

  double _pointerSpan() {
    final points = _pointers.values.toList();
    if (points.length < 2) return 0;
    final gap = (points[0] - points[1]).distance;
    return gap < 1 ? 1 : gap;
  }

  Offset _pointerCenter() {
    final points = _pointers.values.toList();
    if (points.isEmpty) return Offset.zero;
    var sum = Offset.zero;
    for (final point in points) {
      sum += point;
    }
    return sum / points.length.toDouble();
  }

  void _pan(Offset delta, Size canvas) {
    setState(() => _origin = _clampOrigin(_origin + delta, canvas));
  }

  Future<void> _confirm(
    SchemaObject child,
    String childColumn,
    SchemaObject parent,
    String parentColumn,
  ) async {
    final plan = planColumnLink(
      child: child,
      childColumn: childColumn,
      parent: parent,
      parentColumn: parentColumn,
      catalog: widget.objects,
    );
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (context) => _LinkDialog(
        child: child.name,
        childColumn: childColumn,
        parent: parent.name,
        parentColumn: parentColumn,
        plan: plan,
      ),
    );
    if (!mounted || chosen == null || chosen.isEmpty) return;
    setState(() => _picked = null);
    widget.onApplyScript(chosen);
  }

  void _tapColumn(SchemaObject table, ColumnInfo column) {
    final picked = _picked;
    if (picked == null || picked.table == table.name) {
      setState(() {
        if (picked != null &&
            picked.table == table.name &&
            picked.column == column.name) {
          _picked = null;
        } else {
          _picked = _Picked(table.name, column.name);
        }
      });
      return;
    }
    final child =
        _tables.where((item) => item.name == picked.table).firstOrNull;
    if (child == null) {
      setState(() => _picked = _Picked(table.name, column.name));
      return;
    }
    _confirm(child, picked.column, table, column.name);
  }

  @override
  Widget build(BuildContext context) {
    final tables = _tables;
    _placeNew(tables);
    final rects = _rects(tables);
    final canvas = _canvas(rects);
    final edges = _edges(tables, rects);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              Text(
                'Graph',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF14211C),
                    ),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('graph-new-table'),
                onPressed: () async {
                  final sql = await showCreateTable(context);
                  if (!context.mounted || sql == null) return;
                  widget.onApply(sql);
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New table'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: tables.isEmpty
              ? const Center(child: Text('Create a table to see the graph.'))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    _view = Size(constraints.maxWidth, constraints.maxHeight);
                    return ClipRect(
                      child: SizedBox(
                        width: constraints.maxWidth,
                        height: constraints.maxHeight,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerSignal: (event) {
                                  if (event is! PointerScrollEvent) return;
                                  final zoom = HardwareKeyboard
                                          .instance.isControlPressed ||
                                      HardwareKeyboard.instance.isMetaPressed;
                                  if (zoom) {
                                    final factor =
                                        event.scrollDelta.dy > 0 ? 0.9 : 1.1;
                                    _zoomTo(
                                      _scale * factor,
                                      event.localPosition,
                                      canvas,
                                    );
                                    return;
                                  }
                                  _pan(
                                    Offset(
                                      -event.scrollDelta.dx,
                                      -event.scrollDelta.dy,
                                    ),
                                    canvas,
                                  );
                                },
                                onPointerPanZoomUpdate: (event) {
                                  if (_cardDrag != null) return;
                                  _pan(event.panDelta, canvas);
                                },
                                onPointerDown: (event) {
                                  _pointers[event.pointer] =
                                      event.localPosition;
                                  if (_pointers.length == 2) {
                                    _pinchDistance = _pointerSpan();
                                    _pinchScale = _scale;
                                  }
                                },
                                onPointerMove: (event) {
                                  _pointers[event.pointer] =
                                      event.localPosition;
                                  if (_pointers.length >= 2 &&
                                      _pinchDistance >= 1) {
                                    _zoomTo(
                                      _pinchScale *
                                          _pointerSpan() /
                                          _pinchDistance,
                                      _pointerCenter(),
                                      canvas,
                                    );
                                    return;
                                  }
                                  if (_cardDrag != null) return;
                                  _pan(event.delta, canvas);
                                },
                                onPointerUp: (event) =>
                                    _pointers.remove(event.pointer),
                                onPointerCancel: (event) =>
                                    _pointers.remove(event.pointer),
                                child: Stack(
                                  children: [
                                    Positioned(
                                      key: const Key('graph-board'),
                                      left: _origin.dx,
                                      top: _origin.dy,
                                      width: canvas.width * _scale,
                                      height: canvas.height * _scale,
                                      child: FittedBox(
                                        alignment: Alignment.topLeft,
                                        fit: BoxFit.fill,
                                        child: SizedBox(
                                          width: canvas.width,
                                          height: canvas.height,
                                          child: DecoratedBox(
                                            decoration: const BoxDecoration(
                                              color: Color(0xFFE7EEEA),
                                            ),
                                            child: CustomPaint(
                                              painter: _BoardPainter(),
                                              child: Stack(
                                                children: [
                                                  Positioned.fill(
                                                    child: CustomPaint(
                                                      painter:
                                                          _EdgePainter(edges),
                                                    ),
                                                  ),
                                                  for (final table in tables)
                                                    Positioned(
                                                      key: Key(
                                                        'graph-table-${table.name}',
                                                      ),
                                                      left: rects[table.name]!
                                                          .left,
                                                      top: rects[table.name]!
                                                          .top,
                                                      width: rects[table.name]!
                                                          .width,
                                                      height: rects[table.name]!
                                                          .height,
                                                      child: _card(table),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              right: 12,
                              bottom: 12,
                              child: Column(
                                children: [
                                  _zoomButton(
                                    Icons.add,
                                    const Key('graph-zoom-in'),
                                    () => _zoomStep(1.25, canvas),
                                  ),
                                  const SizedBox(height: 8),
                                  _zoomButton(
                                    Icons.remove,
                                    const Key('graph-zoom-out'),
                                    () => _zoomStep(0.8, canvas),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _zoomButton(IconData icon, Key key, VoidCallback onPressed) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shadowColor: const Color(0x3314221C),
      shape: const CircleBorder(
        side: BorderSide(color: Color(0xFFD5E2DB)),
      ),
      child: InkWell(
        key: key,
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: const Color(0xFF0E7C66)),
        ),
      ),
    );
  }

  Widget _card(SchemaObject table) {
    final picked = _picked;
    final armed = picked?.table == table.name;
    return Listener(
      onPointerDown: (_) => _cardDrag = table.name,
      onPointerMove: (event) {
        if (_cardDrag != table.name || _pointers.length > 1) return;
        setState(() {
          final current = _positions[table.name] ?? Offset.zero;
          final next = current + event.localDelta;
          _positions[table.name] = Offset(
            math.max(8, next.dx),
            math.max(8, next.dy),
          );
        });
      },
      onPointerUp: (_) {
        if (_cardDrag != table.name) return;
        _cardDrag = null;
        _persist();
      },
      onPointerCancel: (_) {
        if (_cardDrag != table.name) return;
        _cardDrag = null;
        _persist();
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: armed ? const Color(0xFF0E7C66) : const Color(0xFFD5E2DB),
            width: armed ? 2 : 1,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1414221C),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onTap: () => widget.onOpen(table),
              child: Container(
                height: _header,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: const BoxDecoration(
                  color: Color(0xFF14211C),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(15)),
                ),
                alignment: Alignment.centerLeft,
                child: Text(
                  table.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFF4F7F5),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            for (final column in table.columns) _column(table, column),
          ],
        ),
      ),
    );
  }

  bool _available(SchemaObject table, ColumnInfo column) {
    final picked = _picked;
    if (picked == null) return true;
    if (picked.table == table.name && picked.column == column.name) {
      return true;
    }
    if (picked.table.toLowerCase() == table.name.toLowerCase()) return false;
    final child =
        _tables.where((item) => item.name == picked.table).firstOrNull;
    if (child == null || !columnCanReference(child, picked.column)) {
      return false;
    }
    return columnAcceptsReference(table, column.name, widget.objects);
  }

  Widget _column(SchemaObject table, ColumnInfo column) {
    final links = [
      for (final key in table.foreignKeys)
        if (key.from.toLowerCase() == column.name.toLowerCase()) _fkLabel(key),
    ];
    final picked = _picked;
    final selected = picked != null &&
        picked.table == table.name &&
        picked.column == column.name;
    final available = _available(table, column);
    final offered = available && picked != null && !selected;
    final quiet = picked != null && !available;
    final ink = selected
        ? const Color(0xFF14211C)
        : offered
            ? const Color(0xFF0E7C66)
            : quiet
                ? const Color(0xFFB7C4BE)
                : const Color(0xFF14211C);
    return InkWell(
      key: Key('graph-column-${table.name}-${column.name}'),
      onTap: available ? () => _tapColumn(table, column) : null,
      child: Container(
        height: _row,
        padding: EdgeInsets.only(left: offered ? 9 : 12, right: 12),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFD6EBE4)
              : offered
                  ? const Color(0xFFD8F3EA)
                  : null,
          border: offered
              ? const Border(
                  left: BorderSide(color: Color(0xFF0E7C66), width: 3),
                )
              : null,
        ),
        child: Row(
          children: [
            if (column.primaryKey)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(
                  Icons.key,
                  size: 14,
                  color:
                      quiet ? const Color(0xFFB7C4BE) : const Color(0xFF8A6A12),
                ),
              ),
            Expanded(
              child: Text(
                column.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink,
                  fontWeight:
                      selected || offered ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            if (offered)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.link, size: 16, color: Color(0xFF0E7C66)),
              ),
            if (links.isNotEmpty)
              Flexible(
                child: Text(
                  links.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: quiet
                        ? const Color(0xFFB7C4BE)
                        : const Color(0xFF0E7C66),
                  ),
                ),
              )
            else
              Text(
                column.type,
                style: TextStyle(
                  fontSize: 11,
                  color:
                      quiet ? const Color(0xFFB7C4BE) : const Color(0xFF5E736B),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LinkDialog extends StatelessWidget {
  const _LinkDialog({
    required this.child,
    required this.childColumn,
    required this.parent,
    required this.parentColumn,
    required this.plan,
  });

  final String child;
  final String childColumn;
  final String parent;
  final String parentColumn;
  final ColumnLink plan;

  @override
  Widget build(BuildContext context) {
    final refusal = plan.refusal;
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: MediaQuery.sizeOf(context).width < 468
            ? MediaQuery.sizeOf(context).width - 48
            : 440,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Confirm relationship',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                '$child.$childColumn → $parent.$parentColumn',
                key: const Key('link-column-name'),
                style: const TextStyle(
                  color: Color(0xFF14211C),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                refusal ??
                    'The existing column keeps its rows and gains this foreign key. Indexes and triggers on $child are kept. Nothing is written until you confirm.',
                style: const TextStyle(color: Color(0xFF5E736B)),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('link-save'),
                    onPressed: plan.allowed
                        ? () => Navigator.of(context).pop(plan.statements)
                        : null,
                    child: const Text('Confirm'),
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

const _cardWidth = 220.0;
const _header = 48.0;
const _row = 32.0;
const _gap = 56.0;

class _Layout {
  _Layout(this.rects);

  final Map<String, Rect> rects;
}

_Layout _layout(List<SchemaObject> tables, double viewport) {
  final width = viewport.isFinite && viewport > 480 ? viewport : 720.0;
  final rects = <String, Rect>{};
  var x = 24.0;
  var y = 24.0;
  var rowHeight = 0.0;
  for (final table in tables) {
    final height = _header + table.columns.length * _row;
    if (x > 24 && x + _cardWidth > width - 24) {
      x = 24;
      y += rowHeight + _gap;
      rowHeight = 0;
    }
    rects[table.name] = Rect.fromLTWH(x, y, _cardWidth, height);
    if (height > rowHeight) rowHeight = height;
    x += _cardWidth + _gap;
  }
  return _Layout(rects);
}

List<(Offset, Offset)> _edges(
  List<SchemaObject> tables,
  Map<String, Rect> rects,
) {
  final edges = <(Offset, Offset)>[];
  for (final table in tables) {
    final from = rects[table.name];
    if (from == null) continue;
    for (final key in table.foreignKeys) {
      final parent = rects[key.table];
      if (parent == null) continue;
      final childIndex = table.columns.indexWhere(
        (column) => column.name.toLowerCase() == key.from.toLowerCase(),
      );
      if (childIndex < 0) continue;
      final parentTable =
          tables.where((item) => item.name == key.table).firstOrNull;
      final parentIndex = parentTable?.columns.indexWhere(
            (column) =>
                column.name.toLowerCase() == (key.to ?? '').toLowerCase(),
          ) ??
          -1;
      final fromY = from.top + _header + (childIndex * _row) + _row / 2;
      final toY = parent.top +
          _header +
          ((parentIndex < 0 ? 0 : parentIndex) * _row) +
          _row / 2;
      final forward = from.center.dx <= parent.center.dx;
      edges.add((
        Offset(forward ? from.right : from.left, fromY),
        Offset(forward ? parent.left : parent.right, toY),
      ));
    }
  }
  return edges;
}

String _fkLabel(ForeignKeyInfo key) {
  if (key.to == null || key.to!.isEmpty) return '→ ${key.table}';
  return '→ ${key.table}.${key.to}';
}

class _BoardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFD5E2DB);
    const step = 28.0;
    for (var x = step; x < size.width; x += step) {
      for (var y = step; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.edges);

  final List<(Offset, Offset)> edges;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF0E7C66)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final edge in edges) {
      final start = edge.$1;
      final end = edge.$2;
      final path = Path()..moveTo(start.dx, start.dy);
      final mid = (start.dx + end.dx) / 2;
      path.cubicTo(mid, start.dy, mid, end.dy, end.dx, end.dy);
      canvas.drawPath(path, paint);
      canvas.drawCircle(end, 4, Paint()..color = const Color(0xFF0E7C66));
    }
  }

  @override
  bool shouldRepaint(_EdgePainter oldDelegate) => oldDelegate.edges != edges;
}
