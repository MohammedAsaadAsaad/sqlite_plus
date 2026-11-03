import 'package:flutter/material.dart';

import 'session.dart';

/// Tables, views, indexes, and triggers in the open image.
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
    final groups = <String, List<SchemaObject>>{};
    for (final object in objects) {
      groups.putIfAbsent(object.type, () => []).add(object);
    }
    final order = ['table', 'view', 'index', 'trigger'];
    final types = [
      ...order.where(groups.containsKey),
      ...groups.keys.where((type) => !order.contains(type)),
    ];
    return ListView(
      key: const Key('schema-list'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Text(
            'Schema',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1B2421),
            ),
          ),
        ),
        if (objects.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
                'No tables yet. Run CREATE TABLE in SQL, or add the sample rows.'),
          ),
        for (final type in types) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              type,
              style: const TextStyle(
                color: Color(0xFF1F6B4A),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          for (final object in groups[type]!)
            ListTile(
              key: Key('schema-${object.type}-${object.name}'),
              selected: selected?.name == object.name &&
                  selected?.type == object.type,
              title: Text(object.name),
              subtitle: object.type == 'index' ? Text(object.table) : null,
              onTap: () => onSelect(object),
            ),
        ],
      ],
    );
  }
}
