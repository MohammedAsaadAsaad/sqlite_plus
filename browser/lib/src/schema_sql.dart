import 'format.dart';
import 'session.dart';

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

/// True when [column] on [child] can gain one foreign key.
///
/// A column that already references another table cannot gain a second one,
/// and a column missing from the stored `CREATE TABLE` cannot either.
bool columnCanReference(SchemaObject child, String column) {
  if (child.type != 'table') return false;
  final from = _namedColumn(child, column);
  if (from == null) return false;
  if (child.foreignKeys.any(
    (key) => key.from.toLowerCase() == from.name.toLowerCase(),
  )) {
    return false;
  }
  final sql = child.sql;
  if (sql == null || sql.trim().isEmpty) return false;
  return rewriteTableForeignKey(
        sql: sql,
        column: from.name,
        parent: 'parent',
        parentColumn: 'id',
        newName: child.name,
      ) !=
      null;
}

/// True when [column] can be the parent side of a foreign key.
///
/// That column is the table's only primary key, a one-column `UNIQUE` index,
/// or `UNIQUE` on that column in the stored definition.
bool columnAcceptsReference(
  SchemaObject parent,
  String column,
  List<SchemaObject> catalog,
) {
  if (parent.type != 'table') return false;
  final to = _namedColumn(parent, column);
  if (to == null) return false;
  return _parentIsKey(parent, to.name, catalog);
}

/// A direct foreign key from an existing child column to a parent column.
///
/// sqlite_plus has no `ALTER TABLE` that adds a foreign key to a column that
/// already exists. The statements below save the table again with that column
/// referencing the parent, copy the rows, and put the indexes and triggers
/// back. [ColumnLink.refusal] is set when that link is not allowed, and
/// [ColumnLink.statements] stays empty so nothing can be run by mistake.
ColumnLink planColumnLink({
  required SchemaObject child,
  required String childColumn,
  required SchemaObject parent,
  required String parentColumn,
  required List<SchemaObject> catalog,
}) {
  if (child.type != 'table' || parent.type != 'table') {
    return const ColumnLink(
      statements: [],
      refusal: 'A foreign key connects two tables.',
    );
  }
  if (child.name.toLowerCase() == parent.name.toLowerCase()) {
    return const ColumnLink(
      statements: [],
      refusal: 'Pick a column on another table.',
    );
  }
  final from = _namedColumn(child, childColumn);
  final to = _namedColumn(parent, parentColumn);
  if (from == null || to == null) {
    return const ColumnLink(
      statements: [],
      refusal: 'That column is not on the table.',
    );
  }
  if (child.foreignKeys.any(
    (key) => key.from.toLowerCase() == from.name.toLowerCase(),
  )) {
    return ColumnLink(
      statements: const [],
      refusal: '${child.name}.${from.name} already has a foreign key.',
    );
  }
  if (!_parentIsKey(parent, to.name, catalog)) {
    return ColumnLink(
      statements: const [],
      refusal:
          '${parent.name}.${to.name} is not a primary key or a unique column.',
    );
  }
  final sql = child.sql;
  if (sql == null || sql.trim().isEmpty) {
    return const ColumnLink(
      statements: [],
      refusal: 'This table has no stored definition to update.',
    );
  }
  final temp = _tempTableName(child.name, catalog);
  final create = rewriteTableForeignKey(
    sql: sql,
    column: from.name,
    parent: parent.name,
    parentColumn: to.name,
    newName: temp,
  );
  if (create == null) {
    return ColumnLink(
      statements: const [],
      refusal:
          '${child.name}.${from.name} cannot take a foreign key in the stored definition.',
    );
  }
  final statements = <String>[
    create,
    _copyRows(child, temp),
    'DROP TABLE ${quoteIdent(child.name)}',
    'ALTER TABLE ${quoteIdent(temp)} RENAME TO ${quoteIdent(child.name)}',
  ];
  for (final object in catalog) {
    final onChild = object.table.toLowerCase() == child.name.toLowerCase();
    final stored = object.sql;
    if (!onChild || stored == null || stored.trim().isEmpty) continue;
    if (object.type == 'index' && !object.name.startsWith('sqlite_')) {
      statements.add(stored);
    } else if (object.type == 'trigger') {
      statements.add(stored);
    }
  }
  return ColumnLink(statements: statements);
}

/// `CREATE TABLE` with [column] referencing [parentColumn], under [newName].
///
/// Null when the column cannot be found or it already has `REFERENCES`.
String? rewriteTableForeignKey({
  required String sql,
  required String column,
  required String parent,
  required String parentColumn,
  required String newName,
}) {
  final name = _tableNameSpan(sql);
  final open = name == null ? null : _listOpen(sql, name.end);
  final close = open == null ? null : _matchingParen(sql, open);
  if (name == null || open == null || close == null) return null;
  final parts = _splitCommas(sql, open + 1, close);
  final target = column.toLowerCase();
  _Span? part;
  for (final candidate in parts) {
    final ident = _firstIdentifier(sql, candidate.start, candidate.end);
    if (ident != null && ident.text.toLowerCase() == target) {
      part = candidate;
      break;
    }
  }
  if (part == null) return null;
  if (_keywordAtDepth(sql, part.start, part.end, 'REFERENCES')) return null;
  final clause =
      ' REFERENCES ${quoteIdent(parent)} (${quoteIdent(parentColumn)})';
  return sql.substring(0, name.start) +
      quoteIdent(newName) +
      sql.substring(name.end, part.end) +
      clause +
      sql.substring(part.end);
}

/// The statements for one confirmed column link, or a reason it is refused.
class ColumnLink {
  const ColumnLink({required this.statements, this.refusal});

  final List<String> statements;
  final String? refusal;

  bool get allowed => refusal == null && statements.isNotEmpty;
}

ColumnInfo? _namedColumn(SchemaObject table, String name) {
  for (final column in table.columns) {
    if (column.name.toLowerCase() == name.toLowerCase()) return column;
  }
  return null;
}

bool _parentIsKey(
  SchemaObject parent,
  String column,
  List<SchemaObject> catalog,
) {
  final keys = [
    for (final item in parent.columns)
      if (item.primaryKey) item,
  ];
  if (!_multiColumnPrimaryKey(parent.sql) &&
      keys.length == 1 &&
      keys.single.name.toLowerCase() == column.toLowerCase()) {
    return true;
  }
  return columnDeclaredUnique(parent, column, catalog);
}

/// True when [column] is a one-column `UNIQUE` index or `UNIQUE` in the
/// stored definition. A primary key alone does not count.
bool columnDeclaredUnique(
  SchemaObject table,
  String column,
  List<SchemaObject> catalog,
) {
  for (final object in catalog) {
    if (object.type != 'index' || !object.unique) continue;
    if (object.table.toLowerCase() != table.name.toLowerCase()) continue;
    if (object.indexColumns.length == 1 &&
        object.indexColumns.single.toLowerCase() == column.toLowerCase()) {
      return true;
    }
  }
  final sql = table.sql;
  if (sql == null) return false;
  final name = _tableNameSpan(sql);
  final open = name == null ? null : _listOpen(sql, name.end);
  final close = open == null ? null : _matchingParen(sql, open);
  if (open == null || close == null) return false;
  for (final part in _splitCommas(sql, open + 1, close)) {
    final ident = _firstIdentifier(sql, part.start, part.end);
    if (ident == null || ident.text.toLowerCase() != column.toLowerCase()) {
      continue;
    }
    return _keywordAtDepth(sql, part.start, part.end, 'UNIQUE');
  }
  return false;
}

/// True when the stored definition has a table-level primary key of several
/// columns. A caller that flagged only the first key column still needs this
/// scan, because that column is not a single-column parent.
bool _multiColumnPrimaryKey(String? sql) {
  if (sql == null) return false;
  final name = _tableNameSpan(sql);
  final open = name == null ? null : _listOpen(sql, name.end);
  final close = open == null ? null : _matchingParen(sql, open);
  if (open == null || close == null) return false;
  for (final part in _splitCommas(sql, open + 1, close)) {
    final count = _tablePrimaryKeyColumns(sql, part.start, part.end);
    if (count != null && count > 1) return true;
  }
  return false;
}

int? _tablePrimaryKeyColumns(String sql, int start, int end) {
  final first = _identifierSpan(sql, start);
  if (first == null || first.end > end) return null;
  var keyFrom = first.start;
  if (_bare(sql, first, 'CONSTRAINT')) {
    final constraint = _identifierSpan(sql, first.end);
    if (constraint == null || constraint.end > end) return null;
    final primary = _identifierSpan(sql, constraint.end);
    if (primary == null ||
        primary.end > end ||
        !_bare(sql, primary, 'PRIMARY')) {
      return null;
    }
    keyFrom = primary.start;
  } else if (!_bare(sql, first, 'PRIMARY')) {
    return null;
  }
  final key = _keywordSpan(sql, keyFrom, end, 'KEY');
  if (key == null) return null;
  final list = _listOpen(sql, key.end);
  if (list == null || list >= end) return null;
  final stop = _matchingParen(sql, list);
  if (stop == null || stop > end) return null;
  var count = 0;
  for (final column in _splitCommas(sql, list + 1, stop)) {
    if (_readIdentifier(sql, column.start, column.end) != null) count++;
  }
  return count;
}

bool _bare(String sql, _Span span, String word) {
  final char = sql[span.start];
  if (char == '"' || char == '`' || char == '[') return false;
  return sql.substring(span.start, span.end).toUpperCase() == word;
}

String _tempTableName(String table, List<SchemaObject> catalog) {
  final taken = {
    for (final object in catalog) object.name.toLowerCase(),
  };
  var name = '${table}__link';
  var suffix = 2;
  while (taken.contains(name.toLowerCase())) {
    name = '${table}__link$suffix';
    suffix++;
  }
  return name;
}

String _copyRows(SchemaObject child, String temp) {
  final columns =
      child.columns.map((column) => quoteIdent(column.name)).join(', ');
  final source = quoteIdent(child.name);
  final target = quoteIdent(temp);
  final withoutRowid = _containsKeyword(child.sql ?? '', 'WITHOUT') &&
      _containsKeyword(child.sql ?? '', 'ROWID');
  final keys = [
    for (final column in child.columns)
      if (column.primaryKey) column,
  ];
  final rowidAlias =
      keys.length == 1 && keys.single.type.trim().toUpperCase() == 'INTEGER';
  if (withoutRowid || rowidAlias || columns.isEmpty) {
    return 'INSERT INTO $target ($columns) SELECT $columns FROM $source';
  }
  return 'INSERT INTO $target (rowid, $columns) SELECT rowid, $columns FROM $source';
}

bool _containsKeyword(String sql, String word) {
  final upper = word.toUpperCase();
  String? quote;
  var i = 0;
  while (i < sql.length) {
    final char = sql[i];
    if (quote != null) {
      if (char == quote) {
        final doubled =
            i + 1 < sql.length && sql[i + 1] == quote && quote != ']';
        if (doubled) {
          i += 2;
          continue;
        }
        quote = null;
      }
      i++;
      continue;
    }
    if (char == "'" || char == '"' || char == '`') {
      quote = char;
      i++;
      continue;
    }
    if (char == '[') {
      quote = ']';
      i++;
      continue;
    }
    if (_startsKeyword(sql, i, upper)) return true;
    i++;
  }
  return false;
}

bool _startsKeyword(String sql, int index, String word) {
  if (index > 0 && _identChar(sql.codeUnitAt(index - 1))) return false;
  if (index + word.length > sql.length) return false;
  if (sql.substring(index, index + word.length).toUpperCase() != word) {
    return false;
  }
  final after = index + word.length;
  if (after < sql.length && _identChar(sql.codeUnitAt(after))) return false;
  return true;
}

bool _identChar(int unit) {
  return (unit >= 65 && unit <= 90) ||
      (unit >= 97 && unit <= 122) ||
      (unit >= 48 && unit <= 57) ||
      unit == 95;
}

class _Span {
  const _Span(this.start, this.end);
  final int start;
  final int end;
}

class _Ident {
  const _Ident(this.text, this.quoted);
  final String text;
  final bool quoted;
}

_Span? _tableNameSpan(String sql) {
  final create = _keywordSpan(sql, 0, sql.length, 'CREATE');
  if (create == null) return null;
  final table = _keywordSpan(sql, create.end, sql.length, 'TABLE');
  if (table == null) return null;
  var cursor = table.end;
  final ifWord = _keywordSpan(sql, cursor, sql.length, 'IF');
  if (ifWord != null) {
    final notWord = _keywordSpan(sql, ifWord.end, sql.length, 'NOT');
    final exists = notWord == null
        ? null
        : _keywordSpan(sql, notWord.end, sql.length, 'EXISTS');
    if (exists != null) cursor = exists.end;
  }
  return _identifierSpan(sql, cursor);
}

int? _listOpen(String sql, int from) {
  String? quote;
  for (var i = from; i < sql.length; i++) {
    final char = sql[i];
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == "'" || char == '"' || char == '`' || char == '[') {
      quote = char == '[' ? ']' : char;
      continue;
    }
    if (char == '(') return i;
  }
  return null;
}

int? _matchingParen(String sql, int open) {
  var depth = 0;
  String? quote;
  for (var i = open; i < sql.length; i++) {
    final char = sql[i];
    if (quote != null) {
      if (char == quote) {
        final doubled = i + 1 < sql.length &&
            sql[i + 1] == quote &&
            (quote == '"' || quote == "'" || quote == '`');
        if (doubled) {
          i++;
        } else {
          quote = null;
        }
      }
      continue;
    }
    if (char == "'" || char == '"' || char == '`') {
      quote = char;
      continue;
    }
    if (char == '[') {
      quote = ']';
      continue;
    }
    if (char == '-' && i + 1 < sql.length && sql[i + 1] == '-') {
      final end = sql.indexOf('\n', i);
      i = end < 0 ? sql.length - 1 : end;
      continue;
    }
    if (char == '(') depth++;
    if (char == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

List<_Span> _splitCommas(String sql, int start, int end) {
  final parts = <_Span>[];
  var depth = 0;
  String? quote;
  var part = start;
  for (var i = start; i < end; i++) {
    final char = sql[i];
    if (quote != null) {
      if (char == quote) {
        final doubled = i + 1 < end &&
            sql[i + 1] == quote &&
            (quote == '"' || quote == "'" || quote == '`');
        if (doubled) {
          i++;
        } else {
          quote = null;
        }
      }
      continue;
    }
    if (char == "'" || char == '"' || char == '`') {
      quote = char;
      continue;
    }
    if (char == '[') {
      quote = ']';
      continue;
    }
    if (char == '(') depth++;
    if (char == ')') {
      if (depth > 0) depth--;
      continue;
    }
    if (char == ',' && depth == 0) {
      parts.add(_Span(part, i));
      part = i + 1;
    }
  }
  parts.add(_Span(part, end));
  return parts;
}

_Ident? _firstIdentifier(String sql, int start, int end) {
  final ident = _readIdentifier(sql, start, end);
  if (ident == null) return null;
  if (!ident.quoted) {
    const constraints = {'CONSTRAINT', 'PRIMARY', 'UNIQUE', 'CHECK', 'FOREIGN'};
    if (constraints.contains(ident.text.toUpperCase())) return null;
  }
  return ident;
}

bool _keywordAtDepth(String sql, int start, int end, String word) {
  var depth = 0;
  String? quote;
  for (var i = start; i < end; i++) {
    final char = sql[i];
    if (quote != null) {
      if (char == quote) {
        final doubled = i + 1 < end &&
            sql[i + 1] == quote &&
            (quote == '"' || quote == "'" || quote == '`');
        if (doubled) {
          i++;
        } else {
          quote = null;
        }
      }
      continue;
    }
    if (char == "'" || char == '"' || char == '`') {
      quote = char;
      continue;
    }
    if (char == '[') {
      quote = ']';
      continue;
    }
    if (char == '(') {
      depth++;
      continue;
    }
    if (char == ')') {
      if (depth > 0) depth--;
      continue;
    }
    if (depth == 0 && _startsKeyword(sql, i, word)) return true;
  }
  return false;
}

_Span? _keywordSpan(String sql, int start, int end, String word) {
  String? quote;
  for (var i = start; i < end; i++) {
    final char = sql[i];
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == "'" || char == '"' || char == '`' || char == '[') {
      quote = char == '[' ? ']' : char;
      continue;
    }
    if (_startsKeyword(sql, i, word)) return _Span(i, i + word.length);
  }
  return null;
}

_Span? _identifierSpan(String sql, int start) {
  var i = start;
  while (i < sql.length && ' \t\r\n'.contains(sql[i])) {
    i++;
  }
  if (i >= sql.length) return null;
  final char = sql[i];
  if (char == '"' || char == '`' || char == '[') {
    final closer = char == '[' ? ']' : char;
    final end = sql.indexOf(closer, i + 1);
    if (end < 0) return null;
    return _Span(i, end + 1);
  }
  if (!_identChar(sql.codeUnitAt(i)) ||
      (sql.codeUnitAt(i) >= 48 && sql.codeUnitAt(i) <= 57)) {
    return null;
  }
  var end = i + 1;
  while (end < sql.length && _identChar(sql.codeUnitAt(end))) {
    end++;
  }
  return _Span(i, end);
}

_Ident? _readIdentifier(String sql, int start, int end) {
  var i = start;
  while (i < end && ' \t\r\n'.contains(sql[i])) {
    i++;
  }
  if (i >= end) return null;
  final char = sql[i];
  if (char == '"' || char == '`' || char == '[') {
    final closer = char == '[' ? ']' : char;
    final stop = sql.indexOf(closer, i + 1);
    if (stop < 0 || stop >= end) return null;
    return _Ident(
        sql.substring(i + 1, stop).replaceAll('$closer$closer', closer), true);
  }
  if (!_identChar(sql.codeUnitAt(i)) ||
      (sql.codeUnitAt(i) >= 48 && sql.codeUnitAt(i) <= 57)) {
    return null;
  }
  var stop = i + 1;
  while (stop < end && _identChar(sql.codeUnitAt(stop))) {
    stop++;
  }
  return _Ident(sql.substring(i, stop), false);
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
