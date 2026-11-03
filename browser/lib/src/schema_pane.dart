import 'package:flutter/material.dart';

import 'session.dart';

const _rail = Color(0xFF17241F);
const _railText = Color(0xFFE7F3EE);
const _muted = Color(0xFF93A89F);
const _accent = Color(0xFF7DDBB6);
const _gold = Color(0xFFF0D78C);
const _selected = Color(0xFF243832);

/// Tables, columns, keys, indexes, views, and triggers.
class SchemaPane extends StatelessWidget {
  const SchemaPane({
    super.key,
    required this.objects,
    required this.selected,
    required this.onSelect,
  });

  final List<SchemaObject> objects;
  final SchemaObject? selected;
  final ValueChanged<SchemaObject> onSelect;

  @override
  Widget build(BuildContext context) {
    final tables = [
      for (final object in objects)
        if (object.type == 'table') object
    ];
    final views = [
      for (final object in objects)
        if (object.type == 'view') object
    ];
    final triggers = [
      for (final object in objects)
        if (object.type == 'trigger') object,
    ];
    final indexes = [
      for (final object in objects)
        if (object.type == 'index') object
    ];
    return ColoredBox(
      color: _rail,
      child: ListView(
        key: const Key('schema-list'),
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 28),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Text(
              'Schema',
              style: TextStyle(
                color: _railText,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, 12),
            child: Text(
              'Tables, keys, indexes, views, triggers',
              style: TextStyle(color: _muted, fontSize: 12),
            ),
          ),
          if (objects.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'No tables yet. Run CREATE TABLE in SQL, or add the sample rows.',
                style: TextStyle(color: _muted, height: 1.4),
              ),
            ),
          if (tables.isNotEmpty)
            _group('Tables', tables.length, [
              for (final table in tables) _relation(table, indexes, triggers),
            ]),
          if (indexes.isNotEmpty)
            _group('Indexes', indexes.length, [
              for (final index in indexes) _indexLine(index, keyed: false),
            ]),
          if (views.isNotEmpty)
            _group('Views', views.length, [
              for (final view in views) _relation(view, const [], const []),
            ]),
          if (triggers.isNotEmpty)
            _group('Triggers', triggers.length, [
              for (final trigger in triggers) _leaf(trigger),
            ]),
        ],
      ),
    );
  }

  Widget _group(String title, int count, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    color: _accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$count',
                  style: const TextStyle(color: _accent, fontSize: 11),
                ),
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _relation(
    SchemaObject object,
    List<SchemaObject> indexes,
    List<SchemaObject> triggers,
  ) {
    final ownedIndexes = [
      for (final index in indexes)
        if (index.table == object.name) index,
    ];
    final ownedTriggers = [
      for (final trigger in triggers)
        if (trigger.table == object.name) trigger,
    ];
    final active =
        selected?.name == object.name && selected?.type == object.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active ? _selected : const Color(0xFF1E2C27),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: active ? _gold : const Color(0xFF2C3C36),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: Key('schema-${object.type}-${object.name}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => onSelect(object),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
                child: Row(
                  children: [
                    Icon(
                      object.type == 'view'
                          ? Icons.visibility_outlined
                          : Icons.table_chart_outlined,
                      size: 18,
                      color: _accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        object.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _railText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${object.columns.length}',
                      style: const TextStyle(color: _muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            for (final column in object.columns) _column(column),
            for (final key in object.foreignKeys) _foreignKey(key),
            for (final index in ownedIndexes) _indexLine(index, keyed: true),
            for (final trigger in ownedTriggers)
              _metaRow(
                icon: Icons.bolt_outlined,
                title: trigger.name,
                detail: 'trigger',
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _column(ColumnInfo column) {
    final marks = <String>[
      if (column.primaryKey) 'PK',
      if (column.notNull && !column.primaryKey) 'NOT NULL',
    ];
    final fallback = column.defaultValue;
    return Padding(
      padding: const EdgeInsets.fromLTRB(36, 3, 10, 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              column.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _railText, fontSize: 13),
            ),
          ),
          if (column.type.isNotEmpty)
            Text(
              column.type,
              style: const TextStyle(color: _muted, fontSize: 11),
            ),
          if (fallback != null && fallback.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                fallback,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _gold, fontSize: 11),
              ),
            ),
          ],
          if (marks.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              marks.join(' '),
              style: const TextStyle(
                color: _gold,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _foreignKey(ForeignKeyInfo key) {
    final target = key.to == null || key.to!.isEmpty
        ? key.table
        : '${key.table}.${key.to}';
    final actions = <String>[
      if (key.onUpdate.isNotEmpty && key.onUpdate.toUpperCase() != 'NO ACTION')
        'ON UPDATE ${key.onUpdate}',
      if (key.onDelete.isNotEmpty && key.onDelete.toUpperCase() != 'NO ACTION')
        'ON DELETE ${key.onDelete}',
    ];
    return _metaRow(
      icon: Icons.link,
      title: '${key.from} → $target',
      detail: actions.join(' · '),
    );
  }

  Widget _indexLine(SchemaObject index, {required bool keyed}) {
    final columns = index.indexColumns.join(', ');
    final detail = [
      if (index.unique) 'UNIQUE',
      if (columns.isNotEmpty) columns,
    ].join(' · ');
    return _metaRow(
      icon: Icons.key_outlined,
      title: index.name,
      detail: detail,
      onTap: () => onSelect(index),
      itemKey: keyed ? Key('schema-${index.type}-${index.name}') : null,
      active: selected?.name == index.name && selected?.type == index.type,
    );
  }

  Widget _leaf(SchemaObject object) {
    return _metaRow(
      icon: Icons.bolt_outlined,
      title: object.name,
      detail: object.table,
      onTap: () => onSelect(object),
      itemKey: Key('schema-${object.type}-${object.name}'),
      active: selected?.name == object.name && selected?.type == object.type,
    );
  }

  Widget _metaRow({
    required IconData icon,
    required String title,
    required String detail,
    VoidCallback? onTap,
    Key? itemKey,
    bool active = false,
  }) {
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(36, 3, 10, 3),
      child: Row(
        children: [
          Icon(icon, size: 14, color: active ? _gold : _muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: _railText,
                fontSize: 12,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          if (detail.isNotEmpty) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: const TextStyle(color: _gold, fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(key: itemKey, onTap: onTap, child: row);
  }
}
