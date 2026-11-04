import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'format.dart';
import 'object_dialogs.dart';
import 'session.dart';

const _line = Color(0xFFD9E2DC);
const _header = Color(0xFFE7F2EC);
const _selected = Color(0xFFD3EBE3);
const _ink = Color(0xFF14211C);
const _muted = Color(0xFF5C6560);

/// The structure tree. A column shows a type symbol and its text length.
class SchemaPane extends StatefulWidget {
  const SchemaPane({
    super.key,
    required this.objects,
    required this.selected,
    required this.onSelect,
    required this.onApply,
  });

  final List<SchemaObject> objects;
  final SchemaObject? selected;
  final ValueChanged<SchemaObject> onSelect;
  final Future<void> Function(String sql) onApply;

  @override
  State<SchemaPane> createState() => _SchemaPaneState();
}

class _SchemaPaneState extends State<SchemaPane> {
  final _open = <String, bool>{};
  final _schemaScroll = ScrollController();
  final _selectedAnchor = GlobalKey();
  var _revealTries = 0;

  @override
  void initState() {
    super.initState();
    _openSelectedPath();
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(SchemaPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.selected;
    final previous = oldWidget.selected;
    if (next?.name != previous?.name || next?.type != previous?.type) {
      _openSelectedPath();
      _scheduleReveal();
    }
  }

  @override
  void dispose() {
    _schemaScroll.dispose();
    super.dispose();
  }

  bool _isOpen(String key, {required bool fallback}) => _open[key] ?? fallback;

  void _toggle(String key, {required bool fallback}) {
    setState(() => _open[key] = !_isOpen(key, fallback: fallback));
  }

  void _openSelectedPath() {
    final selected = widget.selected;
    if (selected == null) return;
    final folder = switch (selected.type) {
      'table' => 'folder-tables',
      'index' => 'folder-indices',
      'view' => 'folder-views',
      'trigger' => 'folder-triggers',
      _ => null,
    };
    if (folder != null) _open[folder] = true;
  }

  void _scheduleReveal() {
    _revealTries = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
  }

  void _revealSelected() {
    if (!mounted || widget.selected == null) return;
    final target = _selectedAnchor.currentContext;
    final object = target?.findRenderObject();
    final scrollable = target == null ? null : Scrollable.maybeOf(target);
    final position = scrollable?.position;
    if (target == null ||
        object == null ||
        !object.attached ||
        position == null ||
        !position.hasContentDimensions) {
      if (_revealTries++ < 8) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
      }
      return;
    }
    final viewport = RenderAbstractViewport.maybeOf(object);
    if (viewport == null) return;
    final lead = viewport
        .getOffsetToReveal(object, 0.0, axis: position.axis)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    final trail = viewport
        .getOffsetToReveal(object, 1.0, axis: position.axis)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    final visible = lead >= trail &&
        position.pixels >= trail - 1 &&
        position.pixels <= lead + 1;
    if (!visible && (lead - position.pixels).abs() > 1) {
      position.jumpTo(lead);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tables = [
      for (final object in widget.objects)
        if (object.type == 'table') object,
    ];
    final views = [
      for (final object in widget.objects)
        if (object.type == 'view') object,
    ];
    final triggers = [
      for (final object in widget.objects)
        if (object.type == 'trigger') object,
    ];
    final indexes = [
      for (final object in widget.objects)
        if (object.type == 'index') object,
    ];
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: _line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(
            name: 'Name',
            header: true,
            leading: const SizedBox(width: 18),
          ),
          Expanded(
            child: Scrollbar(
              controller: _schemaScroll,
              child: SingleChildScrollView(
                key: const Key('schema-list'),
                controller: _schemaScroll,
                primary: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (widget.objects.isEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 12, 12, 4),
                        child: Text(
                          'No tables yet. Create one, or add the sample rows.',
                          style: TextStyle(color: _muted),
                        ),
                      ),
                    _folder(
                      label: 'Tables (${tables.length})',
                      store: 'folder-tables',
                      open: _isOpen('folder-tables', fallback: true),
                      onAdd: _createTable,
                      addKey: const Key('schema-add-table'),
                      addTooltip: 'Create table',
                      children: [
                        for (final table in tables) _relation(table),
                      ],
                    ),
                    _folder(
                      label: 'Indices (${indexes.length})',
                      store: 'folder-indices',
                      open: _isOpen(
                        'folder-indices',
                        fallback: indexes.isNotEmpty,
                      ),
                      onAdd: _createIndex,
                      addKey: const Key('schema-add-index'),
                      addTooltip: 'Create index',
                      children: [
                        for (final index in indexes) _index(index),
                      ],
                    ),
                    _folder(
                      label: 'Views (${views.length})',
                      store: 'folder-views',
                      open: _isOpen(
                        'folder-views',
                        fallback: views.isNotEmpty,
                      ),
                      children: [
                        for (final view in views) _relation(view),
                      ],
                    ),
                    _folder(
                      label: 'Triggers (${triggers.length})',
                      store: 'folder-triggers',
                      open: _isOpen(
                        'folder-triggers',
                        fallback: triggers.isNotEmpty,
                      ),
                      children: [
                        for (final trigger in triggers) _objectRow(trigger),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createTable() async {
    final sql = await showCreateTable(context);
    if (!mounted || sql == null) return;
    widget.onApply(sql);
  }

  Future<void> _createIndex() async {
    final tables = [
      for (final object in widget.objects)
        if (object.type == 'table') object,
    ];
    final sql = await showCreateIndex(context, tables);
    if (!mounted || sql == null) return;
    widget.onApply(sql);
  }

  Future<void> _addColumn(String table) async {
    final tables = [
      for (final object in widget.objects)
        if (object.type == 'table') object,
    ];
    final sql = await showAddColumn(context, tables, initialTable: table);
    if (!mounted || sql == null) return;
    widget.onApply(sql);
  }

  Widget _folder({
    required String label,
    required String store,
    required bool open,
    required List<Widget> children,
    VoidCallback? onAdd,
    Key? addKey,
    String? addTooltip,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _entry(
          indent: 0,
          icon: open ? Icons.expand_more : Icons.chevron_right,
          name: label,
          onTap: () => _toggle(store, fallback: open),
          action: onAdd == null
              ? null
              : _plus(onAdd, key: addKey, tooltip: addTooltip),
        ),
        if (open) ...children,
      ],
    );
  }

  Widget _relation(SchemaObject object) {
    final key = 'open-${object.type}-${object.name}';
    final open = _isOpen(key, fallback: true);
    final active = widget.selected?.name == object.name &&
        widget.selected?.type == object.type;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _entry(
          indent: 16,
          icon: open ? Icons.expand_more : Icons.chevron_right,
          second: object.type == 'view'
              ? Icons.visibility_outlined
              : Icons.table_chart_outlined,
          name: object.name,
          active: active,
          itemKey: Key('schema-${object.type}-${object.name}'),
          action: object.type == 'table'
              ? _plus(
                  () => _addColumn(object.name),
                  key: Key('schema-add-column-${object.name}'),
                  tooltip: 'Add column',
                )
              : null,
          anchor: active,
          onTap: () {
            widget.onSelect(object);
            if (!open) _toggle(key, fallback: true);
          },
          onExpand: () => _toggle(key, fallback: true),
        ),
        if (open)
          for (final column in object.columns) ...[
            _entry(
              indent: 48,
              icon: Icons.view_week_outlined,
              name: column.name,
              trailing: _columnMarks(column, object.foreignKeys),
              mark: column.primaryKey ? 'PK' : null,
            ),
            for (final key in object.foreignKeys)
              if (key.from == column.name)
                _entry(
                  indent: 72,
                  icon: Icons.link,
                  name: _referenceText(key),
                  itemKey: Key(
                    'schema-link-${object.name}-${column.name}-${key.constraint}',
                  ),
                ),
          ],
      ],
    );
  }

  Widget _index(SchemaObject object) {
    return _entry(
      indent: 16,
      icon: Icons.key_outlined,
      name: object.name,
      trailing: object.indexColumns.isEmpty
          ? null
          : Text(
              '(${object.indexColumns.join(', ')})',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
      mark: object.unique ? 'unique' : null,
      active: widget.selected?.name == object.name &&
          widget.selected?.type == object.type,
      itemKey: Key('schema-${object.type}-${object.name}'),
      anchor: widget.selected?.name == object.name &&
          widget.selected?.type == object.type,
      onTap: () => widget.onSelect(object),
    );
  }

  Widget _objectRow(SchemaObject object) {
    final icon = object.type == 'trigger'
        ? Icons.bolt_outlined
        : Icons.visibility_outlined;
    return _entry(
      indent: 16,
      icon: icon,
      name: object.name,
      active: widget.selected?.name == object.name &&
          widget.selected?.type == object.type,
      itemKey: Key('schema-${object.type}-${object.name}'),
      anchor: widget.selected?.name == object.name &&
          widget.selected?.type == object.type,
      onTap: () => widget.onSelect(object),
    );
  }

  Widget _entry({
    required double indent,
    required IconData icon,
    IconData? second,
    required String name,
    Widget? trailing,
    String? mark,
    bool active = false,
    bool anchor = false,
    Key? itemKey,
    Widget? action,
    VoidCallback? onTap,
    VoidCallback? onExpand,
  }) {
    final leading = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (onExpand == null)
          Icon(icon, size: 16, color: _muted)
        else
          InkWell(
            onTap: onExpand,
            child: Icon(icon, size: 16, color: _muted),
          ),
        if (second != null) ...[
          const SizedBox(width: 4),
          Icon(second, size: 16, color: const Color(0xFF0E7C66)),
        ],
      ],
    );
    final row = _row(
      indent: indent,
      leading: leading,
      name: name,
      trailing: trailing,
      mark: mark,
      active: active,
      action: action,
    );
    final tappable = onTap == null ? row : InkWell(onTap: onTap, child: row);
    final keyed = itemKey == null
        ? tappable
        : KeyedSubtree(key: itemKey, child: tappable);
    if (!anchor) return keyed;
    return KeyedSubtree(key: _selectedAnchor, child: keyed);
  }

  Widget _row({
    double indent = 0,
    Widget? leading,
    required String name,
    Widget? trailing,
    String? mark,
    bool header = false,
    bool active = false,
    Widget? action,
  }) {
    final style = TextStyle(
      color: _ink,
      fontSize: header ? 12 : 13,
      fontWeight: header ? FontWeight.w700 : FontWeight.w500,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: header
            ? _header
            : active
                ? _selected
                : Colors.white,
        border: const Border(bottom: BorderSide(color: _line)),
      ),
      child: SizedBox(
        height: header ? 32 : 34,
        child: Padding(
          padding: EdgeInsets.only(left: 8 + indent, right: 8),
          child: Row(
            children: [
              if (leading != null) leading,
              if (leading != null) const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 6),
                Flexible(child: trailing),
              ],
              if (mark != null) ...[
                const SizedBox(width: 6),
                Text(
                  mark,
                  style: const TextStyle(
                    color: Color(0xFF8A6A12),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
              if (action != null) action,
            ],
          ),
        ),
      ),
    );
  }
}

Widget _columnMarks(ColumnInfo column, List<ForeignKeyInfo> keys) {
  final badge = _typeBadge(column.type);
  final linked = keys.any((key) => key.from == column.name);
  final marks = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(badge.icon, size: 15, color: _muted),
      if (badge.size != null) ...[
        const SizedBox(width: 2),
        Text(
          badge.size!,
          style: const TextStyle(
            color: _ink,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
      if (linked) ...[
        const SizedBox(width: 4),
        const Icon(Icons.link, size: 14, color: Color(0xFF0E7C66)),
      ],
    ],
  );
  final tip = columnDefinition(column, keys);
  return Tooltip(message: tip, child: marks);
}

class _TypeBadge {
  const _TypeBadge(this.icon, this.size);

  final IconData icon;
  final String? size;
}

_TypeBadge _typeBadge(String declared) {
  final type = declared.trim();
  final upper = type.toUpperCase();
  final size = _declaredSize(type);
  if (upper.contains('BLOB')) return _TypeBadge(Icons.attach_file, size);
  if (upper.contains('BOOL')) {
    return _TypeBadge(Icons.toggle_on_outlined, size);
  }
  if (upper.contains('DATETIME') || upper.contains('TIMESTAMP')) {
    return _TypeBadge(Icons.event_outlined, size);
  }
  if (upper.contains('DATE')) {
    return _TypeBadge(Icons.calendar_today_outlined, size);
  }
  if (RegExp(r'(^|[^A-Z])TIME([^A-Z]|$)').hasMatch(upper)) {
    return _TypeBadge(Icons.schedule, size);
  }
  if (upper.contains('INT')) return _TypeBadge(Icons.numbers, size);
  if (upper.contains('REAL') ||
      upper.contains('FLOA') ||
      upper.contains('DOUB') ||
      upper.contains('DEC') ||
      upper.contains('NUM')) {
    return _TypeBadge(Icons.exposure_outlined, size);
  }
  return _TypeBadge(Icons.abc, size);
}

String _referenceText(ForeignKeyInfo key) {
  final target =
      key.to == null || key.to!.isEmpty ? key.table : '${key.table}.${key.to}';
  final actions = <String>[
    if (key.onUpdate.isNotEmpty && key.onUpdate.toUpperCase() != 'NO ACTION')
      'ON UPDATE ${key.onUpdate}',
    if (key.onDelete.isNotEmpty && key.onDelete.toUpperCase() != 'NO ACTION')
      'ON DELETE ${key.onDelete}',
  ];
  final action = actions.isEmpty ? '' : ' · ${actions.join(' · ')}';
  return '→ $target$action';
}

String? _declaredSize(String declared) {
  final match = RegExp(r'\(([^)]*)\)').firstMatch(declared);
  if (match == null) return null;
  final inside = match.group(1)!.replaceAll(' ', '');
  if (inside.isEmpty) return null;
  return inside;
}

/// Column definition shown from the type symbol: name, type, key, and actions.
String columnDefinition(ColumnInfo column, List<ForeignKeyInfo> keys) {
  final buffer = StringBuffer(quoteIdent(column.name));
  if (column.type.isNotEmpty) buffer.write(' ${column.type}');
  if (column.primaryKey) buffer.write(' PRIMARY KEY');
  if (column.notNull && !column.primaryKey) buffer.write(' NOT NULL');
  final fallback = column.defaultValue;
  if (fallback != null && fallback.isNotEmpty) {
    buffer.write(' DEFAULT $fallback');
  }
  for (final key in keys) {
    if (key.from != column.name) continue;
    final target = key.to == null || key.to!.isEmpty
        ? key.table
        : '${key.table}(${key.to})';
    buffer.write(' REFERENCES $target');
    if (key.onUpdate.isNotEmpty && key.onUpdate.toUpperCase() != 'NO ACTION') {
      buffer.write(' ON UPDATE ${key.onUpdate}');
    }
    if (key.onDelete.isNotEmpty && key.onDelete.toUpperCase() != 'NO ACTION') {
      buffer.write(' ON DELETE ${key.onDelete}');
    }
  }
  return buffer.toString();
}

Widget _plus(VoidCallback onPressed, {Key? key, String? tooltip}) {
  return IconButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    icon: const Icon(Icons.add, size: 18, color: Color(0xFF0E7C66)),
    style: IconButton.styleFrom(
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      minimumSize: const Size(28, 28),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    ),
  );
}
