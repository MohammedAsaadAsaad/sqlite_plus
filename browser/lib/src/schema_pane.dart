import 'package:flutter/material.dart';

import 'session.dart';

/// Tables, with their columns and indexes, plus views and triggers.
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
        if (object.type == 'table') object,
    ];
    final views = [
      for (final object in objects)
        if (object.type == 'view') object,
    ];
    final triggers = [
      for (final object in objects)
        if (object.type == 'trigger') object,
    ];
    final indexes = [
      for (final object in objects)
        if (object.type == 'index') object,
    ];
    return ListView(
      key: const Key('schema-list'),
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Text(
            'Schema',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        if (objects.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              'No tables yet. Run CREATE TABLE in SQL, or add the sample rows.',
            ),
          ),
        if (tables.isNotEmpty)
          _section(
            context,
            'Tables',
            tables.length,
            [
              for (final table in tables)
                _relation(context, table, indexes, nested: true),
            ],
          ),
        if (views.isNotEmpty)
          _section(
            context,
            'Views',
            views.length,
            [
              for (final view in views)
                _relation(context, view, const [], nested: true),
            ],
          ),
        if (triggers.isNotEmpty)
          _section(
            context,
            'Triggers',
            triggers.length,
            [for (final trigger in triggers) _leaf(context, trigger)],
          ),
        if (indexes
            .any((index) => !tables.any((table) => table.name == index.table)))
          _section(
            context,
            'Indexes',
            indexes.length,
            [for (final index in indexes) _leaf(context, index)],
          ),
      ],
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    int count,
    List<Widget> children,
  ) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$count',
                  style: TextStyle(color: color, fontSize: 11),
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
    BuildContext context,
    SchemaObject object,
    List<SchemaObject> indexes, {
    required bool nested,
  }) {
    final owned = [
      for (final index in indexes)
        if (index.table == object.name) index,
    ];
    final active =
        selected?.name == object.name && selected?.type == object.type;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: active
            ? Theme.of(context).colorScheme.secondaryContainer
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: Key('schema-${object.type}-${object.name}'),
              borderRadius: BorderRadius.circular(10),
              onTap: () => onSelect(object),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
                child: Row(
                  children: [
                    Icon(
                      object.type == 'view'
                          ? Icons.visibility_outlined
                          : Icons.table_chart_outlined,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        object.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            for (final column in object.columns)
              _column(context, object, column),
            if (nested)
              for (final index in owned)
                _child(context, index, Icons.key_outlined),
          ],
        ),
      ),
    );
  }

  Widget _column(BuildContext context, SchemaObject owner, ColumnInfo column) {
    final marks = [
      if (column.primaryKey) 'PK',
      if (column.notNull && !column.primaryKey) 'NOT NULL',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 2, 8, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              column.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          if (column.type.isNotEmpty)
            Text(
              column.type,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).hintColor,
              ),
            ),
          if (marks.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              marks.join(' '),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _child(BuildContext context, SchemaObject object, IconData icon) {
    final active =
        selected?.name == object.name && selected?.type == object.type;
    return InkWell(
      key: Key('schema-${object.type}-${object.name}'),
      onTap: () => onSelect(object),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(34, 4, 8, 4),
        child: Row(
          children: [
            Icon(icon, size: 14, color: Theme.of(context).hintColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                object.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _leaf(BuildContext context, SchemaObject object) {
    return _child(context, object, Icons.bolt_outlined);
  }
}
