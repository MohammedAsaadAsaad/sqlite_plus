import 'format.dart';

/// One column collected from the create-table form.
class ColumnDraft {
  const ColumnDraft({
    required this.name,
    required this.type,
    this.primaryKey = false,
    this.notNull = false,
  });

  final String name;
  final String type;
  final bool primaryKey;
  final bool notNull;
}

/// `CREATE TABLE` for the columns the user entered. Null when the form is incomplete.
String? createTableSql(String name, List<ColumnDraft> columns) {
  final table = name.trim();
  if (table.isEmpty) return null;
  final usable = [
    for (final column in columns)
      if (column.name.trim().isNotEmpty) column,
  ];
  if (usable.isEmpty) return null;
  final seen = <String>{};
  for (final column in usable) {
    if (!seen.add(column.name.trim().toLowerCase())) return null;
  }
  final keys = [
    for (final column in usable)
      if (column.primaryKey) column
  ];
  final lines = <String>[];
  for (final column in usable) {
    final parts = <String>[quoteIdent(column.name.trim())];
    if (column.type.trim().isNotEmpty) parts.add(column.type.trim());
    if (keys.length == 1 && column.primaryKey) parts.add('PRIMARY KEY');
    if (column.notNull) parts.add('NOT NULL');
    lines.add('  ${parts.join(' ')}');
  }
  if (keys.length > 1) {
    final listed =
        keys.map((column) => quoteIdent(column.name.trim())).join(', ');
    lines.add('  PRIMARY KEY ($listed)');
  }
  return 'CREATE TABLE ${quoteIdent(table)} (\n${lines.join(',\n')}\n)';
}

/// `CREATE INDEX` for the checked columns. The name is generated when blank.
String? createIndexSql({
  required String table,
  required List<String> columns,
  String name = '',
  bool unique = false,
}) {
  final target = table.trim();
  final fields = [
    for (final column in columns)
      if (column.trim().isNotEmpty) column.trim()
  ];
  if (target.isEmpty || fields.isEmpty) return null;
  final index =
      name.trim().isEmpty ? 'idx_${target}_${fields.join('_')}' : name.trim();
  final kind = unique ? 'UNIQUE INDEX' : 'INDEX';
  final listed = fields.map(quoteIdent).join(', ');
  return 'CREATE $kind ${quoteIdent(index)} ON ${quoteIdent(target)} ($listed)';
}

/// `ALTER TABLE ... ADD COLUMN` for one column on a table that already exists.
///
/// A `NOT NULL` column needs a default, because the rows already stored receive
/// that value. A reference keeps those rows null, so it takes no other default.
String? addColumnSql({
  required String table,
  required String name,
  required String type,
  List<String> existing = const [],
  bool notNull = false,
  String defaultText = '',
  String referenceTable = '',
  String referenceColumn = '',
}) {
  final target = table.trim();
  final column = name.trim();
  if (target.isEmpty || column.isEmpty) return null;
  if (existing.any((item) => item.toLowerCase() == column.toLowerCase())) {
    return null;
  }
  final fallback = defaultText.trim();
  final refTable = referenceTable.trim();
  final refColumn = referenceColumn.trim();
  final hasReference = refTable.isNotEmpty || refColumn.isNotEmpty;
  if (hasReference && (refTable.isEmpty || refColumn.isEmpty)) return null;
  if (notNull && fallback.isEmpty) return null;
  if (hasReference && fallback.isNotEmpty && fallback.toUpperCase() != 'NULL') {
    return null;
  }
  final parts = <String>[quoteIdent(column)];
  if (type.trim().isNotEmpty) parts.add(type.trim());
  if (notNull) parts.add('NOT NULL');
  if (fallback.isNotEmpty) {
    final literal = _defaultLiteral(fallback, type);
    if (literal == null) return null;
    parts.add('DEFAULT $literal');
  }
  final referenced = hasReference
      ? ' REFERENCES ${quoteIdent(refTable)} (${quoteIdent(refColumn)})'
      : '';
  return 'ALTER TABLE ${quoteIdent(target)} ADD COLUMN ${parts.join(' ')}$referenced';
}

String? _defaultLiteral(String raw, String type) {
  if (raw.toUpperCase() == 'NULL') return 'NULL';
  final numeric = RegExp(r'^[+-]?\d+(\.\d+)?$').hasMatch(raw);
  final kind = type.trim().toUpperCase();
  const numbers = {'INTEGER', 'REAL', 'NUMERIC', 'FLOAT', 'DOUBLE', 'DECIMAL'};
  if (numeric &&
      (kind.isEmpty || numbers.contains(kind) || kind.startsWith('INT'))) {
    return raw;
  }
  return "'${raw.replaceAll("'", "''")}'";
}

/// A new child column that references a parent column.
String? linkColumnSql({
  required String child,
  required String column,
  required String type,
  required String parent,
  required String parentColumn,
}) {
  final parts = [child, column, parent, parentColumn];
  if (parts.any((part) => part.trim().isEmpty)) return null;
  final declared = type.trim().isEmpty ? '' : ' ${type.trim()}';
  return 'ALTER TABLE ${quoteIdent(child.trim())} ADD COLUMN '
      '${quoteIdent(column.trim())}$declared REFERENCES '
      '${quoteIdent(parent.trim())} (${quoteIdent(parentColumn.trim())})';
}
