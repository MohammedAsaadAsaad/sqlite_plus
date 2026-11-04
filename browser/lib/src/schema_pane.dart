import 'package:flutter/material.dart';

import 'format.dart';
import 'object_dialogs.dart';
import 'session.dart';

const _nameWidth = 220.0;
const _typeWidth = 120.0;
const _schemaWidth = 360.0;
const _line = Color(0xFFE4E4E4);
const _header = Color(0xFFF0F0F0);
const _selected = Color(0xFFD6E8F8);
const _ink = Color(0xFF1C1C1C);
const _muted = Color(0xFF5C6560);

/// Name, type, and schema text, in the shape of a database structure tree.
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

  bool _isOpen(String key, {required bool fallback}) => _open[key] ?? fallback;

  void _toggle(String key, {required bool fallback}) {
    setState(() => _open[key] = !_isOpen(key, fallback: fallback));
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
    return ColoredBox(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = _nameWidth + _typeWidth + _schemaWidth;
                return Scrollbar(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: width < constraints.maxWidth
                          ? constraints.maxWidth
                          : width,
                      height: constraints.maxHeight,
                      child: Column(
                        children: [
                          _cells(
                            name: 'Name',
                            type: 'Type',
                            schema: 'Schema',
                            header: true,
                            leading: const SizedBox(width: 18),
                          ),
                          Expanded(
                            child: ListView(
                              key: const Key('schema-list'),
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
                                  open:
                                      _isOpen('folder-tables', fallback: true),
                                  onAdd: _createTable,
                                  addKey: const Key('schema-add-table'),
                                  addTooltip: 'Create table',
                                  children: [
                                    for (final table in tables)
                                      _relation(table),
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
                                    for (final trigger in triggers)
                                      _objectRow(trigger),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
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
          type: object.type,
          schema: _oneLine(object.sql),
          active: active,
          itemKey: Key('schema-${object.type}-${object.name}'),
          action: object.type == 'table'
              ? _plus(
                  () => _addColumn(object.name),
                  key: Key('schema-add-column-${object.name}'),
                  tooltip: 'Add column',
                )
              : null,
          onTap: () {
            widget.onSelect(object);
            if (!open) _toggle(key, fallback: true);
          },
          onExpand: () => _toggle(key, fallback: true),
        ),
        if (open)
          for (final column in object.columns)
            _entry(
              indent: 48,
              icon: Icons.view_week_outlined,
              name: column.name,
              type: column.type,
              schema: columnDefinition(column, object.foreignKeys),
              mark: column.primaryKey ? 'PK' : null,
            ),
      ],
    );
  }

  Widget _index(SchemaObject object) {
    final columns = object.indexColumns.join(', ');
    final sql =
        _oneLine(object.sql).isNotEmpty ? _oneLine(object.sql) : columns;
    final entries = object.entries;
    final size = object.byteSize;
    final facts = entries == null
        ? ''
        : '$entries entries · ${formatBytes(size ?? 0)} · ';
    return _entry(
      indent: 16,
      icon: Icons.key_outlined,
      name: object.name,
      type: object.unique ? 'unique' : 'index',
      schema: '$facts$sql',
      active: widget.selected?.name == object.name &&
          widget.selected?.type == object.type,
      itemKey: Key('schema-${object.type}-${object.name}'),
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
      type: object.type,
      schema: _oneLine(object.sql),
      active: widget.selected?.name == object.name &&
          widget.selected?.type == object.type,
      itemKey: Key('schema-${object.type}-${object.name}'),
      onTap: () => widget.onSelect(object),
    );
  }

  Widget _entry({
    required double indent,
    required IconData icon,
    IconData? second,
    required String name,
    String type = '',
    String schema = '',
    String? mark,
    bool active = false,
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
    final row = _cells(
      indent: indent,
      leading: leading,
      name: name,
      type: type,
      schema: schema,
      mark: mark,
      active: active,
      action: action,
    );
    if (onTap == null) return row;
    return InkWell(key: itemKey, onTap: onTap, child: row);
  }

  Widget _cells({
    double indent = 0,
    Widget? leading,
    required String name,
    required String type,
    required String schema,
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
        child: Row(
          children: [
            SizedBox(
              width: _nameWidth,
              child: Padding(
                padding: EdgeInsets.only(left: 8 + indent, right: 8),
                child: Row(
                  children: [
                    if (leading != null) leading,
                    if (leading != null) const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    if (action != null) action,
                  ],
                ),
              ),
            ),
            SizedBox(
              width: _typeWidth,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        type,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style.copyWith(
                          color: header ? _ink : _muted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
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
                  ],
                ),
              ),
            ),
            SizedBox(
              width: _schemaWidth,
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  schema,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style.copyWith(
                    fontFamily: header ? null : 'monospace',
                    fontSize: header ? 12 : 12,
                    fontWeight: FontWeight.w400,
                    color: header ? _ink : const Color(0xFF24312C),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Column text for the schema column: name, type, key, default, and actions.
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

String _oneLine(String? sql) {
  if (sql == null || sql.isEmpty) return '';
  return sql.replaceAll(RegExp(r'\s+'), ' ').trim();
}
