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

/// Collects one column for a table that already exists.
Future<String?> showAddColumn(
  BuildContext context,
  List<SchemaObject> tables, {
  String? initialTable,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _AddColumnDialog(
      tables: tables,
      initialTable: initialTable,
    ),
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
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Columns',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '${_columns.length}',
                    style: const TextStyle(color: Color(0xFF5C6560)),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Key sets the primary key. Block sets NOT NULL.',
                style: TextStyle(color: Color(0xFF5C6560), fontSize: 12),
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
                  label: const Text('Column'),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FAF8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD9E2DC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: Color(0xFF5C6560),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: TextField(
                  key: Key('create-column-name-$index'),
                  controller: column.name,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'name',
                  ),
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
          Row(
            children: [
              const SizedBox(width: 22),
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
                    style: const TextStyle(fontWeight: FontWeight.w700),
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
            ],
          ),
        ],
      ),
    );
  }
}

class _AddColumnDialog extends StatefulWidget {
  const _AddColumnDialog({required this.tables, this.initialTable});

  final List<SchemaObject> tables;
  final String? initialTable;

  @override
  State<_AddColumnDialog> createState() => _AddColumnDialogState();
}

class _AddColumnDialogState extends State<_AddColumnDialog> {
  final _name = TextEditingController();
  final _defaultValue = TextEditingController();
  final _length = TextEditingController();
  final _digits = TextEditingController();
  final _places = TextEditingController();
  late String? _table = _initialTable();
  var _type = 'TEXT';
  var _notNull = false;
  var _referenceTable = '';
  var _referenceColumn = '';

  String? _initialTable() {
    final named = widget.initialTable;
    for (final table in widget.tables) {
      if (table.name == named) return table.name;
    }
    if (widget.tables.isEmpty) return null;
    return widget.tables.first.name;
  }

  @override
  void initState() {
    super.initState();
    _name.addListener(_refresh);
    _defaultValue.addListener(_refresh);
    _length.addListener(_refresh);
    _digits.addListener(_refresh);
    _places.addListener(_refresh);
  }

  @override
  void dispose() {
    _name.dispose();
    _defaultValue.dispose();
    _length.dispose();
    _digits.dispose();
    _places.dispose();
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

  SchemaObject? get _parent {
    if (_referenceTable.isEmpty) return null;
    for (final table in widget.tables) {
      if (table.name == _referenceTable) return table;
    }
    return null;
  }

  bool get _textLike => _type == 'TEXT' || _type == 'BLOB';

  bool get _numeric =>
      _type == 'INTEGER' || _type == 'REAL' || _type == 'NUMERIC';

  String? get _typeSql => columnTypeSql(
        base: _type,
        length: _textLike ? _length.text : '',
        digits: _numeric ? _digits.text : '',
        places: _type == 'REAL' || _type == 'NUMERIC' ? _places.text : '',
      );

  String? get _sql {
    final table = _selected;
    final type = _typeSql;
    if (table == null || type == null) return null;
    return addColumnSql(
      table: table.name,
      name: _name.text,
      type: type,
      existing: [for (final column in table.columns) column.name],
      notNull: _notNull,
      defaultText: _defaultValue.text,
      referenceTable: _referenceTable,
      referenceColumn: _referenceColumn,
    );
  }

  void _chooseReference(String? value) {
    final name = value ?? '';
    String column = '';
    if (name.isNotEmpty) {
      for (final table in widget.tables) {
        if (table.name == name && table.columns.isNotEmpty) {
          column = table.columns.first.name;
          break;
        }
      }
    }
    setState(() {
      _referenceTable = name;
      _referenceColumn = column;
    });
  }

  @override
  Widget build(BuildContext context) {
    final parent = _parent;
    final needsDefault = _notNull && _defaultValue.text.trim().isEmpty;
    final type = _typeSql;
    final height = MediaQuery.sizeOf(context).height;
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _dialogWidth(context, 440),
          maxHeight: height * 0.88,
        ),
        child: SizedBox(
          width: _dialogWidth(context, 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Row(
                        children: [
                          _FormMark(icon: Icons.view_week_outlined),
                          SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'New column',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Add one column to a table that already exists.',
                                  style: TextStyle(
                                    color: Color(0xFF5C6560),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      if (widget.tables.isEmpty)
                        const Text('Create a table first.')
                      else ...[
                        _section(
                          label: 'Column',
                          children: [
                            DropdownButtonFormField<String>(
                              key: const Key('add-column-table'),
                              initialValue: _table,
                              isExpanded: true,
                              decoration: _field('Table'),
                              items: [
                                for (final item in widget.tables)
                                  DropdownMenuItem(
                                    value: item.name,
                                    child: Text(item.name),
                                  ),
                              ],
                              onChanged: (value) =>
                                  setState(() => _table = value),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              key: const Key('add-column-name'),
                              controller: _name,
                              autofocus: true,
                              textCapitalization: TextCapitalization.none,
                              decoration: _field('Column name', hint: 'note'),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Type',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF5C6560),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Wrap(
                              children: [
                                for (final type in _types) _kind(type),
                              ],
                            ),
                            _sizeFields(),
                          ],
                        ),
                        _section(
                          label: 'Rules',
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'NOT NULL',
                                    style:
                                        TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                Switch(
                                  key: const Key('add-column-null'),
                                  value: _notNull,
                                  onChanged: (value) =>
                                      setState(() => _notNull = value),
                                ),
                              ],
                            ),
                            TextField(
                              key: const Key('add-column-default'),
                              controller: _defaultValue,
                              decoration: _field(
                                'Default',
                                hint: 'Empty leaves existing rows null',
                              ),
                            ),
                            if (needsDefault)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text(
                                  'Existing rows need a default.',
                                  style: TextStyle(color: Color(0xFF8A6A12)),
                                ),
                              ),
                          ],
                        ),
                        _section(
                          label: 'Reference',
                          children: [
                            DropdownButtonFormField<String>(
                              key: const Key('add-column-reference-table'),
                              initialValue: _referenceTable,
                              isExpanded: true,
                              decoration: _field('References'),
                              items: [
                                const DropdownMenuItem(
                                  value: '',
                                  child: Text('None'),
                                ),
                                for (final item in widget.tables)
                                  DropdownMenuItem(
                                    value: item.name,
                                    child: Text(item.name),
                                  ),
                              ],
                              onChanged: _chooseReference,
                            ),
                            if (parent != null &&
                                parent.columns.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              DropdownButtonFormField<String>(
                                key: Key(
                                    'add-column-reference-column-${parent.name}'),
                                initialValue: _referenceColumn,
                                isExpanded: true,
                                decoration: _field('Referenced column'),
                                items: [
                                  for (final column in parent.columns)
                                    DropdownMenuItem(
                                      value: column.name,
                                      child: Text(column.name),
                                    ),
                                ],
                                onChanged: (value) {
                                  if (value == null) return;
                                  setState(() => _referenceColumn = value);
                                },
                              ),
                            ],
                            if (_referenceTable.isNotEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 6),
                                child: Text(
                                  'Existing rows stay null, so this column has no other default.',
                                  style: TextStyle(
                                    color: Color(0xFF5E736B),
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        Container(
                          key: const Key('add-column-preview'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF14211C),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            type ?? 'Size needs a whole number.',
                            style: const TextStyle(
                              color: Color(0xFFE7F6F1),
                              fontFamily: 'JetBrainsMono',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('add-column-save'),
                      onPressed: _sql == null
                          ? null
                          : () => Navigator.of(context).pop(_sql),
                      child: const Text('Add'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sizeFields() {
    if (_textLike) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: TextField(
          key: const Key('add-column-length'),
          controller: _length,
          keyboardType: TextInputType.number,
          decoration: _field(
            _type == 'BLOB' ? 'Blob length' : 'Text length',
            hint: 'Empty keeps $_type',
          ),
          style: const TextStyle(fontFamily: 'JetBrainsMono'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const Key('add-column-digits'),
              controller: _digits,
              keyboardType: TextInputType.number,
              decoration: _field(
                'Digits',
                hint: 'Optional',
              ),
              style: const TextStyle(fontFamily: 'JetBrainsMono'),
            ),
          ),
          if (_type == 'REAL' || _type == 'NUMERIC') ...[
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const Key('add-column-places'),
                controller: _places,
                keyboardType: TextInputType.number,
                decoration: _field('Decimal places', hint: 'Optional'),
                style: const TextStyle(fontFamily: 'JetBrainsMono'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _kind(String type) {
    final selected = _type == type;
    return Padding(
      padding: const EdgeInsets.only(right: 6, bottom: 6),
      child: Material(
        color: selected ? const Color(0xFF0E7C66) : Colors.white,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          key: Key('add-column-kind-$type'),
          borderRadius: BorderRadius.circular(999),
          onTap: () => setState(() => _type = type),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? const Color(0xFF0E7C66)
                    : const Color(0xFFD9E2DC),
              ),
            ),
            child: Text(
              type,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : const Color(0xFF14211C),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _section({required String label, required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF7FBF9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD9E2DC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: Color(0xFF5C6560),
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _FormMark extends StatelessWidget {
  const _FormMark({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFD6EBE4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, size: 18, color: const Color(0xFF0E7C66)),
    );
  }
}

InputDecoration _field(String label, {String? hint}) {
  const line = Color(0xFFD9E2DC);
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: const BorderSide(color: line),
  );
  return InputDecoration(
    labelText: label,
    hintText: hint,
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    border: border,
    enabledBorder: border,
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xFF0E7C66), width: 1.5),
    ),
  );
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
