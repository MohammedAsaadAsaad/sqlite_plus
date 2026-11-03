import 'package:flutter/material.dart';

import 'schema_sql.dart';
import 'session.dart';

const _types = ['INTEGER', 'TEXT', 'REAL', 'NUMERIC', 'BLOB'];

/// Collects a table name and its columns, then returns one CREATE TABLE statement.
Future<String?> showCreateTable(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => const _CreateTableDialog(),
  );
}

/// Collects an index name, table, and columns, then returns one CREATE INDEX statement.
Future<String?> showCreateIndex(
    BuildContext context, List<SchemaObject> tables) {
  return showDialog<String>(
    context: context,
    builder: (context) => _CreateIndexDialog(tables: tables),
  );
}

class _ColumnField {
  _ColumnField({
    required String name,
    required this.type,
    this.primaryKey = false,
  }) : name = TextEditingController(text: name);

  final TextEditingController name;
  String type;
  bool primaryKey;
  bool notNull = false;

  void dispose() => name.dispose();
}

class _CreateTableDialog extends StatefulWidget {
  const _CreateTableDialog();

  @override
  State<_CreateTableDialog> createState() => _CreateTableDialogState();
}

class _CreateTableDialogState extends State<_CreateTableDialog> {
  final _name = TextEditingController();
  late final List<_ColumnField> _columns = [
    _ColumnField(name: 'id', type: 'INTEGER', primaryKey: true),
    _ColumnField(name: 'title', type: 'TEXT'),
  ];

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
    for (final column in _columns) {
      column.name.addListener(_refresh);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final column in _columns) {
      column.dispose();
    }
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String? get _sql => createTableSql(_name.text, [
        for (final column in _columns)
          ColumnDraft(
            name: column.name.text,
            type: column.type,
            primaryKey: column.primaryKey,
            notNull: column.notNull,
          ),
      ]);

  void _addColumn() {
    final column = _ColumnField(name: '', type: 'TEXT');
    column.name.addListener(_refresh);
    setState(() => _columns.add(column));
  }

  void _remove(int index) {
    if (_columns.length == 1) return;
    final removed = _columns.removeAt(index);
    removed.name.removeListener(_refresh);
    removed.dispose();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: _dialogWidth(context, 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'New table',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('create-table-name'),
                controller: _name,
                autofocus: true,
                textCapitalization: TextCapitalization.none,
                decoration: const InputDecoration(
                  labelText: 'Table name',
                  hintText: 'events',
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Columns',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              for (var index = 0; index < _columns.length; index++)
                _columnRow(index),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('create-column-add'),
                  onPressed: _addColumn,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add column'),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('create-table-save'),
                    onPressed: _sql == null
                        ? null
                        : () => Navigator.of(context).pop(_sql),
                    child: const Text('Create'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _columnRow(int index) {
    final column = _columns[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: Key('create-column-name-$index'),
            controller: column.name,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'name',
            ),
          ),
          Row(
            children: [
              PopupMenuButton<String>(
                key: Key('create-column-type-$index'),
                initialValue: column.type,
                onSelected: (value) => setState(() => column.type = value),
                itemBuilder: (context) => [
                  for (final type in _types)
                    PopupMenuItem(value: type, child: Text(type)),
                ],
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Text(
                    column.type,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                key: Key('create-column-pk-$index'),
                tooltip: 'Primary key',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 36, height: 36),
                onPressed: () =>
                    setState(() => column.primaryKey = !column.primaryKey),
                icon: Icon(
                  Icons.key,
                  color: column.primaryKey
                      ? const Color(0xFF8A6A12)
                      : const Color(0xFFB7C4BE),
                ),
              ),
              IconButton(
                key: Key('create-column-null-$index'),
                tooltip: 'NOT NULL',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 36, height: 36),
                onPressed: () =>
                    setState(() => column.notNull = !column.notNull),
                icon: Icon(
                  Icons.block,
                  color: column.notNull
                      ? const Color(0xFF0E7C66)
                      : const Color(0xFFB7C4BE),
                ),
              ),
              IconButton(
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 36, height: 36),
                onPressed: _columns.length == 1 ? null : () => _remove(index),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

double _dialogWidth(BuildContext context, double preferred) {
  final available = MediaQuery.sizeOf(context).width - 48;
  if (available < preferred) return available < 240 ? 240 : available;
  return preferred;
}

class _CreateIndexDialog extends StatefulWidget {
  const _CreateIndexDialog({required this.tables});

  final List<SchemaObject> tables;

  @override
  State<_CreateIndexDialog> createState() => _CreateIndexDialogState();
}

class _CreateIndexDialogState extends State<_CreateIndexDialog> {
  final _name = TextEditingController();
  late String? _table = widget.tables.isEmpty ? null : widget.tables.first.name;
  final _checked = <String>{};
  var _unique = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  SchemaObject? get _selected {
    for (final table in widget.tables) {
      if (table.name == _table) return table;
    }
    return null;
  }

  String? get _sql {
    final table = _selected;
    if (table == null) return null;
    return createIndexSql(
      table: table.name,
      columns: [
        for (final column in table.columns)
          if (_checked.contains(column.name)) column.name
      ],
      name: _name.text,
      unique: _unique,
    );
  }

  @override
  Widget build(BuildContext context) {
    final table = _selected;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: SizedBox(
        width: _dialogWidth(context, 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'New index',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              if (widget.tables.isEmpty)
                const Text('Create a table first.')
              else ...[
                TextField(
                  key: const Key('create-index-name'),
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Index name',
                    hintText: 'Leave blank to name it from the columns',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('create-index-table'),
                  initialValue: _table,
                  decoration: const InputDecoration(labelText: 'Table'),
                  items: [
                    for (final item in widget.tables)
                      DropdownMenuItem(
                          value: item.name, child: Text(item.name)),
                  ],
                  onChanged: (value) => setState(() {
                    _table = value;
                    _checked.clear();
                  }),
                ),
                const SizedBox(height: 8),
                if (table != null)
                  for (final column in table.columns)
                    CheckboxListTile(
                      key: Key('create-index-column-${column.name}'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(column.name),
                      value: _checked.contains(column.name),
                      onChanged: (checked) => setState(() {
                        if (checked ?? false) {
                          _checked.add(column.name);
                        } else {
                          _checked.remove(column.name);
                        }
                      }),
                    ),
                SwitchListTile(
                  key: const Key('create-index-unique'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Unique'),
                  value: _unique,
                  onChanged: (value) => setState(() => _unique = value),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('create-index-save'),
                    onPressed: _sql == null
                        ? null
                        : () => Navigator.of(context).pop(_sql),
                    child: const Text('Create'),
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
