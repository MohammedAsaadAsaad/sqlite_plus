import 'expressions.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';

/// Names visible in one connection. [order] is the unqualified search order.
final class SchemaNames {
  SchemaNames(this.tables, this.objects, this.order);
  final Map<String, Set<String>> tables;
  final Map<String, Set<String>> objects;
  final List<String> order;

  String? tableSchema(String name) {
    final key = asciiLower(name);
    for (final schema in order) {
      if (tables[schema]?.contains(key) ?? false) return schema;
    }
    return null;
  }

  String? objectSchema(String name) {
    final key = asciiLower(name);
    for (final schema in order) {
      if (objects[schema]?.contains(key) ?? false) return schema;
    }
    return null;
  }
}

final class TableUse {
  TableUse(this.schema, this.table);
  final String schema;
  final String table;
}

/// A statement routed at one schema, or a read that must be assembled.
final class StatementRoute {
  StatementRoute(this.kind, this.sql,
      {this.schema, this.uses = const [], this.argument, this.name});
  final String kind;
  final String sql;
  final String? schema;
  final List<TableUse> uses;
  final String? argument;
  final String? name;
  bool get cross => kind == 'cross';
}

StatementRoute routeQuery(String sql, SchemaNames names) {
  final statement = SqlParser(sql).select();
  final uses = <TableUse>[];
  _collect(statement, const {}, uses, names);
  final schemas = uses.map((use) => use.schema).toSet();
  if (schemas.length <= 1) {
    final schema = schemas.isEmpty ? 'main' : schemas.single;
    return StatementRoute('query', imageSql(sql, schema),
        schema: schema, uses: uses);
  }
  return StatementRoute('cross', sql, uses: uses);
}

StatementRoute routeMutation(String sql, SchemaNames names) {
  final cursor = _Cursor(sql);
  if (cursor.take('ATTACH')) {
    cursor.take('DATABASE');
    if (cursor.current.kind != SqlTokenKind.string) {
      throw SqlException('Expected string', cursor.current.offset);
    }
    final path = cursor.current.text;
    cursor.index++;
    cursor.require('AS');
    final name = asciiLower(cursor.identifier().text);
    cursor.finish();
    if (name.isEmpty || name.contains('\u0000')) {
      throw const SqlException('Invalid database name');
    }
    return StatementRoute('attach', sql, argument: path, name: name);
  }
  if (cursor.take('DETACH')) {
    cursor.take('DATABASE');
    final name = asciiLower(cursor.identifier().text);
    cursor.finish();
    return StatementRoute('detach', sql, name: name);
  }
  final target = _mutationTarget(cursor, names);
  _rejectCrossDatabase(sql, target.schema, names);
  return StatementRoute('single', target.sql, schema: target.schema);
}

/// SQL for one image. `main` qualifiers stay, because the image parser uses
/// them to bypass a CTE. Another schema's image has no second schema, so its
/// qualifier is removed.
String imageSql(String sql, String schema) =>
    schema == 'main' ? sql : stripSchema(sql, schema);

String stripSchema(String sql, String schema) {
  final tokens = SqlTokenizer.tokenize(sql);
  final edits = <(int, int, String)>[];
  for (var i = 0; i + 2 < tokens.length; i++) {
    final token = tokens[i];
    if (token.kind != SqlTokenKind.identifier ||
        asciiLower(token.text) != schema ||
        tokens[i + 1].text != '.' ||
        tokens[i + 2].kind != SqlTokenKind.identifier) {
      continue;
    }
    edits.add((token.offset, tokens[i + 2].offset, ''));
    i += 2;
  }
  return _splice(sql, edits);
}

/// Rewrites `schema.table` references to scratch names. Keys are `schema.table`
/// in lower case.
String rewriteSchemaTables(String sql, Map<String, String> names) {
  final tokens = SqlTokenizer.tokenize(sql);
  final edits = <(int, int, String)>[];
  for (var i = 0; i + 2 < tokens.length; i++) {
    final token = tokens[i];
    if (token.kind != SqlTokenKind.identifier ||
        tokens[i + 1].text != '.' ||
        tokens[i + 2].kind != SqlTokenKind.identifier) {
      continue;
    }
    final key = '${asciiLower(token.text)}.${asciiLower(tokens[i + 2].text)}';
    final scratch = names[key];
    if (scratch == null) continue;
    final end = tokens[i + 2].offset + tokens[i + 2].text.length;
    edits.add((token.offset, end, '"${scratch.replaceAll('"', '""')}"'));
    i += 2;
  }
  return _splice(sql, edits);
}

void _collect(SelectStatement statement, Set<String> outer, List<TableUse> uses,
    SchemaNames names) {
  final scope = {...outer, ...statement.ctes.keys};
  for (final source in statement.leafSources) {
    if (source.query != null) {
      _collect(source.query!, scope, uses, names);
      continue;
    }
    if (source.table == null) continue;
    final table = source.table!;
    final key = asciiLower(table);
    if (source.schema == null &&
        (scope.contains(key) || pragmaTableColumns.containsKey(key))) {
      continue;
    }
    final schema = source.schema ?? names.tableSchema(table) ?? 'main';
    if (!names.order.contains(schema)) {
      throw SqlException('Unknown database: $schema');
    }
    uses.add(TableUse(schema, table));
  }
  void expression(Expr expr) {
    if (expr is SubqueryExpr) _collect(expr.statement, scope, uses, names);
    if (expr is InSelectExpr) _collect(expr.statement, scope, uses, names);
    for (final child in expr.children) {
      expression(child);
    }
  }

  for (final item in statement.items) {
    if (item.expression != null) expression(item.expression!);
  }
  if (statement.where != null) expression(statement.where!);
  if (statement.having != null) expression(statement.having!);
  for (final term in statement.groupBy) {
    expression(term);
  }
  for (final term in statement.order) {
    expression(term.expression);
  }
  for (final window in statement.windowDefinitions.values) {
    expression(window);
  }
  for (final part in statement.compounds) {
    _collect(part.$2, scope, uses, names);
  }
  for (final cte in statement.ctes.values) {
    _collect(cte.$2, scope, uses, names);
  }
}

final class _Target {
  _Target(this.schema, this.sql);
  final String schema;
  final String sql;
}

_Target _mutationTarget(_Cursor cursor, SchemaNames names) {
  _skipWith(cursor);
  if (cursor.take('CREATE')) {
    final temporary = cursor.take('TEMP') || cursor.take('TEMPORARY');
    return _create(cursor, names, temporary);
  }
  if (cursor.take('DROP')) return _drop(cursor, names);
  if (cursor.take('ALTER')) {
    cursor.require('TABLE');
    final named = _qualified(cursor, names);
    final schema = named.schema ?? names.tableSchema(named.name.text) ?? 'main';
    return _Target(schema, imageSql(cursor.sql, schema));
  }
  if (cursor.take('INSERT') || cursor.take('REPLACE')) {
    if (cursor.take('OR')) cursor.identifier();
    cursor.require('INTO');
    return _tableTarget(cursor, names);
  }
  if (cursor.take('UPDATE')) {
    if (cursor.take('OR')) cursor.identifier();
    return _tableTarget(cursor, names);
  }
  if (cursor.take('DELETE')) {
    cursor.require('FROM');
    return _tableTarget(cursor, names);
  }
  if (cursor.take('REINDEX') || cursor.take('ANALYZE')) {
    if (cursor.current.kind == SqlTokenKind.identifier) {
      final named = _qualified(cursor, names);
      cursor.finish();
      final schema =
          named.schema ?? names.objectSchema(named.name.text) ?? 'main';
      return _Target(schema, imageSql(cursor.sql, schema));
    }
    cursor.finish();
    return _Target('main', cursor.sql);
  }
  if (cursor.take('VACUUM')) {
    if (cursor.current.kind == SqlTokenKind.identifier) {
      final schema = asciiLower(cursor.identifier().text);
      if (!names.order.contains(schema)) {
        throw SqlException('Unknown database: $schema');
      }
      cursor.finish();
      return _Target(schema, imageSql(cursor.sql, schema));
    }
    cursor.finish();
    return _Target('main', cursor.sql);
  }
  throw SqlException('Unsupported statement', cursor.current.offset);
}

_Target _tableTarget(_Cursor cursor, SchemaNames names) {
  final named = _qualified(cursor, names);
  final schema = named.schema ?? names.tableSchema(named.name.text) ?? 'main';
  return _Target(schema, imageSql(cursor.sql, schema));
}

_Target _create(_Cursor cursor, SchemaNames names, bool temporary) {
  cursor.take('UNIQUE');
  final virtual = cursor.take('VIRTUAL');
  final kind = cursor.current.keyword;
  if (!const {'TABLE', 'INDEX', 'VIEW', 'TRIGGER'}.contains(kind)) {
    throw const SqlException('Unsupported CREATE statement');
  }
  cursor.index++;
  if (cursor.take('IF')) {
    cursor.require('NOT');
    cursor.require('EXISTS');
  }
  final named = _qualified(cursor, names);
  if (temporary && named.schema != null && named.schema != 'temp') {
    throw const SqlException('TEMP object schema must be temp');
  }
  String schema = named.schema ?? (temporary ? 'temp' : 'main');
  if (kind == 'INDEX' || kind == 'TRIGGER') {
    final table = _onTable(cursor, names);
    if (table.schema != null &&
        named.schema != null &&
        table.schema != named.schema) {
      throw const SqlException('Object and table use different databases');
    }
    schema = named.schema ??
        table.schema ??
        names.tableSchema(table.name.text) ??
        'main';
    if (temporary) schema = 'temp';
  } else if (virtual) {
    schema = temporary ? 'temp' : (named.schema ?? 'main');
  }
  final edits = <(int, int, String)>[];
  if (temporary) {
    final tokens = cursor.tokens;
    final marker = tokens.firstWhere(
        (token) => token.keyword == 'TEMP' || token.keyword == 'TEMPORARY');
    final next = tokens[tokens.indexOf(marker) + 1];
    edits.add((marker.offset, next.offset, ''));
  }
  if (named.schema != null) {
    edits.add((named.schemaToken!.offset, named.name.offset, ''));
  }
  var sql = _splice(cursor.sql, edits);
  return _Target(schema, imageSql(sql, schema));
}

_Target _drop(_Cursor cursor, SchemaNames names) {
  final temporary = cursor.take('TEMP') || cursor.take('TEMPORARY');
  final kind = cursor.current.keyword;
  if (!const {'TABLE', 'INDEX', 'VIEW', 'TRIGGER'}.contains(kind)) {
    throw const SqlException('Unsupported DROP statement');
  }
  cursor.index++;
  final ifExists = cursor.take('IF') && cursor.take('EXISTS');
  if (!ifExists && cursor.tokens.any((token) => token.keyword == 'EXISTS')) {
    throw const SqlException('Expected EXISTS');
  }
  final named = _qualified(cursor, names);
  cursor.finish();
  if (temporary && named.schema != null && named.schema != 'temp') {
    throw const SqlException('TEMP object schema must be temp');
  }
  final schema = temporary
      ? 'temp'
      : named.schema ??
          (kind == 'TABLE' || kind == 'VIEW'
              ? names.tableSchema(named.name.text)
              : names.objectSchema(named.name.text)) ??
          'main';
  return _Target(schema, imageSql(cursor.sql, schema));
}

({String? schema, SqlToken name, SqlToken? schemaToken}) _qualified(
    _Cursor cursor, SchemaNames names) {
  final first = cursor.identifier();
  if (!cursor.take('.')) return (schema: null, name: first, schemaToken: null);
  final schema = asciiLower(first.text);
  if (!names.order.contains(schema)) {
    throw SqlException('Unknown database: ${first.text}');
  }
  return (schema: schema, name: cursor.identifier(), schemaToken: first);
}

({String? schema, SqlToken name}) _onTable(_Cursor cursor, SchemaNames names) {
  final saved = cursor.index;
  while (!cursor.done) {
    if (cursor.take('ON')) {
      final named = _qualified(cursor, names);
      return (schema: named.schema, name: named.name);
    }
    cursor.index++;
  }
  cursor.index = saved;
  throw const SqlException('Expected ON');
}

void _skipWith(_Cursor cursor) {
  if (!cursor.take('WITH')) return;
  cursor.take('RECURSIVE');
  var depth = 0;
  while (!cursor.done) {
    final keyword = cursor.current.keyword;
    if (depth == 0 &&
        const {'INSERT', 'REPLACE', 'UPDATE', 'DELETE'}.contains(keyword)) {
      return;
    }
    if (cursor.current.text == '(') {
      depth++;
    } else if (cursor.current.text == ')') {
      depth--;
    }
    cursor.index++;
  }
}

void _rejectCrossDatabase(String sql, String target, SchemaNames names) {
  final tokens = SqlTokenizer.tokenize(sql);
  const starters = {'FROM', 'JOIN', 'INTO', 'UPDATE'};
  for (var i = 0; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.kind != SqlTokenKind.identifier) continue;
    final lower = asciiLower(token.text);
    if (names.order.contains(lower) &&
        i + 2 < tokens.length &&
        tokens[i + 1].text == '.' &&
        tokens[i + 2].kind == SqlTokenKind.identifier) {
      final table = asciiLower(tokens[i + 2].text);
      final schemaTable = table == 'sqlite_schema' || table == 'sqlite_master';
      if (lower != target &&
          (schemaTable || names.tables[lower]?.contains(table) == true)) {
        throw const SqlException('cross-database statement is not supported');
      }
      i += 2;
      continue;
    }
    final previous = i == 0 ? '' : tokens[i - 1].keyword;
    if (starters.contains(previous)) {
      final resolved = names.tableSchema(token.text);
      if (resolved != null && resolved != target) {
        throw const SqlException('cross-database statement is not supported');
      }
    }
  }
}

final class _Cursor {
  _Cursor(this.sql) : tokens = SqlTokenizer.tokenize(sql);
  final String sql;
  final List<SqlToken> tokens;
  int index = 0;
  SqlToken get current => tokens[index];
  bool get done => current.kind == SqlTokenKind.end;
  bool take(String text) {
    if (current.keyword == text ||
        current.kind == SqlTokenKind.symbol && current.text == text) {
      index++;
      return true;
    }
    return false;
  }

  void require(String text) {
    if (!take(text)) throw SqlException('Expected $text', current.offset);
  }

  SqlToken identifier() {
    if (current.kind != SqlTokenKind.identifier) {
      throw SqlException('Expected identifier', current.offset);
    }
    return tokens[index++];
  }

  void finish() {
    take(';');
    if (!done) {
      throw SqlException('Unsupported or trailing SQL', current.offset);
    }
  }
}

String _splice(String sql, List<(int, int, String)> edits) {
  final ordered = [...edits]..sort((a, b) => b.$1.compareTo(a.$1));
  var result = sql;
  for (final edit in ordered) {
    result = result.replaceRange(edit.$1, edit.$2, edit.$3);
  }
  return result;
}
