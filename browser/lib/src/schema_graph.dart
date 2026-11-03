import 'package:flutter/material.dart';

import 'object_dialogs.dart';
import 'schema_sql.dart';
import 'session.dart';

/// Tables as cards, with lines for foreign keys and a tap path that adds one.
class SchemaGraph extends StatefulWidget {
  const SchemaGraph({
    super.key,
    required this.objects,
    required this.onOpen,
    required this.onApply,
  });

  final List<SchemaObject> objects;
  final ValueChanged<SchemaObject> onOpen;
  final Future<void> Function(String sql) onApply;

  @override
  State<SchemaGraph> createState() => _SchemaGraphState();
}

class _SchemaGraphState extends State<SchemaGraph> {
  String? _linking;

  List<SchemaObject> get _tables => [
        for (final object in widget.objects)
          if (object.type == 'table') object,
      ];

  Future<void> _link(
      SchemaObject child, SchemaObject parent, ColumnInfo column) async {
    final existing =
        child.columns.map((item) => item.name.toLowerCase()).toSet();
    var name = '${parent.name}_${column.name}';
    var suffix = 2;
    while (existing.contains(name.toLowerCase())) {
      name = '${parent.name}_${column.name}_$suffix';
      suffix++;
    }
    final type = column.type.trim().isEmpty ? 'INTEGER' : column.type.trim();
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => _LinkDialog(
        child: child.name,
        parent: parent.name,
        parentColumn: column.name,
        column: name,
        type: type,
      ),
    );
    if (!mounted || chosen == null) return;
    setState(() => _linking = null);
    widget.onApply(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final tables = _tables;
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
                      fontWeight: FontWeight.w700,
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
        if (_linking != null)
          Material(
            color: const Color(0xFFD6EBE4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        'Tap a column in another table. $_linking will reference it.'),
                  ),
                  TextButton(
                    key: const Key('graph-link-cancel'),
                    onPressed: () => setState(() => _linking = null),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'Tap Link, then a column in another table, to add a foreign key.',
              style: TextStyle(color: Color(0xFF5E736B)),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: tables.isEmpty
              ? const Center(child: Text('Create a table to see the graph.'))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final layout = _layout(tables, constraints.maxWidth);
                    return Scrollbar(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SingleChildScrollView(
                          child: SizedBox(
                            width: layout.size.width,
                            height: layout.size.height,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _EdgePainter(layout.edges),
                                  ),
                                ),
                                for (final table in tables)
                                  Positioned(
                                    key: Key('graph-table-${table.name}'),
                                    left: layout.rects[table.name]!.left,
                                    top: layout.rects[table.name]!.top,
                                    width: layout.rects[table.name]!.width,
                                    height: layout.rects[table.name]!.height,
                                    child: _card(table),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _card(SchemaObject table) {
    final armed = _linking == table.name;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: armed ? const Color(0xFF0E7C66) : const Color(0xFFD5E2DB),
          width: armed ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => widget.onOpen(table),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(13)),
            child: Container(
              height: _header,
              padding: const EdgeInsets.only(left: 12, right: 4),
              decoration: const BoxDecoration(
                color: Color(0xFFE6F0EA),
                borderRadius: BorderRadius.vertical(top: Radius.circular(13)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      table.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    key: Key('graph-link-${table.name}'),
                    tooltip: 'Link',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 36, height: 36),
                    onPressed: () => setState(() => _linking = table.name),
                    icon: const Icon(Icons.link, size: 18),
                    color: const Color(0xFF0E7C66),
                  ),
                ],
              ),
            ),
          ),
          for (final column in table.columns) _column(table, column),
        ],
      ),
    );
  }

  Widget _column(SchemaObject table, ColumnInfo column) {
    final links = [
      for (final key in table.foreignKeys)
        if (key.from.toLowerCase() == column.name.toLowerCase()) _fkLabel(key),
    ];
    final target = _linking != null && _linking != table.name;
    return InkWell(
      key: Key('graph-column-${table.name}-${column.name}'),
      onTap: () {
        if (_linking == null || _linking == table.name) return;
        final child =
            _tables.where((item) => item.name == _linking).firstOrNull;
        if (child == null) return;
        _link(child, table, column);
      },
      child: Container(
        height: _row,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        color: target ? const Color(0xFFF3FAF7) : null,
        child: Row(
          children: [
            if (column.primaryKey)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.key, size: 14, color: Color(0xFF8A6A12)),
              ),
            Expanded(
              child: Text(
                column.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (links.isNotEmpty)
              Flexible(
                child: Text(
                  links.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 11, color: Color(0xFF0E7C66)),
                ),
              )
            else
              Text(
                column.type,
                style: const TextStyle(fontSize: 11, color: Color(0xFF5E736B)),
              ),
          ],
        ),
      ),
    );
  }
}

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({
    required this.child,
    required this.parent,
    required this.parentColumn,
    required this.column,
    required this.type,
  });

  final String child;
  final String parent;
  final String parentColumn;
  final String column;
  final String type;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.column);
  late String _type = _types.contains(widget.type) ? widget.type : 'INTEGER';

  @override
  void initState() {
    super.initState();
    _name.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sql = linkColumnSql(
      child: widget.child,
      column: _name.text,
      type: _type,
      parent: widget.parent,
      parentColumn: widget.parentColumn,
    );
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: MediaQuery.sizeOf(context).width < 468
            ? MediaQuery.sizeOf(context).width - 48
            : 420,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'New relationship',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                '${widget.child} references ${widget.parent}.${widget.parentColumn}',
                style: const TextStyle(color: Color(0xFF5E736B)),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('link-column-name'),
                controller: _name,
                decoration: const InputDecoration(
                    labelText: 'New column on the child table'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('link-column-type'),
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final type in _types)
                    DropdownMenuItem(value: type, child: Text(type)),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _type = value);
                },
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
                    onPressed: sql == null
                        ? null
                        : () => Navigator.of(context).pop(sql),
                    child: const Text('Create link'),
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

const _types = ['INTEGER', 'TEXT', 'REAL', 'NUMERIC', 'BLOB'];
const _cardWidth = 220.0;
const _header = 48.0;
const _row = 32.0;
const _gap = 56.0;

class _Layout {
  _Layout(this.size, this.rects, this.edges);

  final Size size;
  final Map<String, Rect> rects;
  final List<(Offset, Offset)> edges;
}

_Layout _layout(List<SchemaObject> tables, double viewport) {
  final width = viewport.isFinite && viewport > 480 ? viewport : 720.0;
  final rects = <String, Rect>{};
  var x = 24.0;
  var y = 24.0;
  var rowHeight = 0.0;
  var maxX = width;
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
    if (x > maxX) maxX = x;
  }
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
  return _Layout(Size(maxX, y + rowHeight + 24), rects, edges);
}

String _fkLabel(ForeignKeyInfo key) {
  if (key.to == null || key.to!.isEmpty) return '→ ${key.table}';
  return '→ ${key.table}.${key.to}';
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
