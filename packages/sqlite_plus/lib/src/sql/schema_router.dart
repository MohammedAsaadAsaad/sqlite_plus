import 'dart:async';

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
  if (_referencesOtherSchema(sql, target.schema, names)) {
    if (insertSelectParts(sql) != null) {
      return StatementRoute('cross-insert', target.sql, schema: target.schema);
    }
    if (_isUpdateOrDelete(sql) || statementInsertsRows(sql)) {
      return StatementRoute('cross-write', sql, schema: target.schema);
    }
    throw const SqlException('cross-database statement is not supported');
  }
  return StatementRoute('single', target.sql, schema: target.schema);
}

bool _isUpdateOrDelete(String sql) {
  final cursor = _Cursor(sql);
  _skipWith(cursor);
  if (cursor.take('UPDATE')) return true;
  if (!cursor.take('DELETE')) return false;
  return true;
}

/// `INSERT` or `REPLACE`, including a leading `WITH`.
bool statementInsertsRows(String sql) {
  final cursor = _Cursor(sql);
  _skipWith(cursor);
  return cursor.take('INSERT') || cursor.take('REPLACE');
}

/// The pieces of an `INSERT ... SELECT`. Null for any other statement.
final class InsertSelect {
  InsertSelect(this.head, this.selectSql, this.tail);
  final String head;
  final String selectSql;
  final String tail;
}

InsertSelect? insertSelectParts(String sql) {
  final tokens = SqlTokenizer.tokenize(sql);
  var index = 0;
  var depth = 0;
  var insertAt = -1;
  while (index < tokens.length && tokens[index].kind != SqlTokenKind.end) {
    final token = tokens[index];
    if (token.text == '(') {
      depth++;
    } else if (token.text == ')') {
      depth--;
    } else if (depth == 0 &&
        (token.keyword == 'INSERT' || token.keyword == 'REPLACE')) {
      insertAt = index;
      break;
    }
    index++;
  }
  if (insertAt < 0) return null;
  final ctePrefix =
      insertAt == 0 ? '' : sql.substring(0, tokens[insertAt].offset);
  index = insertAt + 1;
  bool take(String word) {
    if (index < tokens.length && tokens[index].keyword == word) {
      index++;
      return true;
    }
    return false;
  }

  if (tokens[insertAt].keyword == 'INSERT' && take('OR')) {
    if (index >= tokens.length ||
        tokens[index].kind != SqlTokenKind.identifier) {
      return null;
    }
    index++;
  }
  if (!take('INTO')) return null;
  if (index >= tokens.length || tokens[index].kind != SqlTokenKind.identifier) {
    return null;
  }
  index++;
  if (take('.')) {
    if (index >= tokens.length ||
        tokens[index].kind != SqlTokenKind.identifier) {
      return null;
    }
    index++;
  }
  if (take('AS')) {
    if (index >= tokens.length ||
        tokens[index].kind != SqlTokenKind.identifier) {
      return null;
    }
    index++;
  }
  if (index < tokens.length && tokens[index].text == '(') {
    var columnDepth = 0;
    while (index < tokens.length && tokens[index].kind != SqlTokenKind.end) {
      if (tokens[index].text == '(') columnDepth++;
      if (tokens[index].text == ')') columnDepth--;
      index++;
      if (columnDepth == 0) break;
    }
  }
  if (index >= tokens.length) return null;
  final source = tokens[index];
  if (source.keyword != 'SELECT' && source.keyword != 'WITH') return null;
  var sourceEnd = sql.length;
  var sourceDepth = 0;
  for (var i = index; i < tokens.length; i++) {
    final token = tokens[i];
    if (token.kind == SqlTokenKind.end ||
        sourceDepth == 0 && token.text == ';') {
      sourceEnd = token.offset;
      break;
    }
    if (token.text == '(') {
      sourceDepth++;
    } else if (token.text == ')') {
      sourceDepth--;
    } else if (sourceDepth == 0 &&
        (token.keyword == 'RETURNING' ||
            token.keyword == 'ON' &&
                i + 1 < tokens.length &&
                tokens[i + 1].keyword == 'CONFLICT')) {
      sourceEnd = token.offset;
      break;
    }
  }
  return InsertSelect(
      sql.substring(tokens[insertAt].offset, source.offset),
      '$ctePrefix${sql.substring(source.offset, sourceEnd)}',
      sql.substring(sourceEnd));
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
    if (cursor.current.kind == SqlTokenKind.identifier &&
        cursor.current.keyword != 'INTO') {
      final token = cursor.identifier();
      final schema = asciiLower(token.text);
      if (!names.order.contains(schema)) {
        throw SqlException('Unknown database: $schema');
      }
      if (cursor.current.keyword == 'INTO') {
        if (schema == 'temp') {
          // SQLite parses `VACUUM temp` and then skips it. The schema token
          // stays so the image parser can do the same without writing a file.
          return _Target(schema, cursor.sql);
        }
        // The image parser sees `VACUUM INTO ...`. The schema name already
        // selected this image, including an attached database.
        final sql =
            _splice(cursor.sql, [(token.offset, cursor.current.offset, '')]);
        return _Target(schema, sql);
      }
      cursor.finish();
      return _Target(schema, imageSql(cursor.sql, schema));
    }
    if (cursor.current.keyword == 'INTO') {
      return _Target('main', cursor.sql);
    }
    cursor.finish();
    return _Target('main', cursor.sql);
  }
  throw SqlException('Unsupported statement', cursor.current.offset);
}

_Target _tableTarget(_Cursor cursor, SchemaNames names) {
  final named = _qualified(cursor, names, dml: true);
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
    _Cursor cursor, SchemaNames names,
    {bool dml = false}) {
  final first = cursor.identifier();
  if (!cursor.take('.')) return (schema: null, name: first, schemaToken: null);
  final schema = asciiLower(first.text);
  if (!names.order.contains(schema)) {
    if (dml) {
      final table = cursor.identifier();
      throw SqlException('no such table: ${first.text}.${table.text}');
    }
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

bool _referencesOtherSchema(String sql, String target, SchemaNames names) {
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
        return true;
      }
      i += 2;
      continue;
    }
    final previous = i == 0 ? '' : tokens[i - 1].keyword;
    if (starters.contains(previous)) {
      final resolved = names.tableSchema(token.text);
      if (resolved != null && resolved != target) return true;
    }
  }
  return false;
}

/// One foreign table copied into the target schema for a cross-schema write.
final class CrossCopy {
  CrossCopy(this.schema, this.table, this.helper);
  final String schema;
  final String table;
  final String helper;
}

/// An `UPDATE`, `DELETE`, or `INSERT` rewritten so the target image can run it.
final class CrossWritePlan {
  CrossWritePlan(this.sql, this.copies);
  final String sql;
  final List<CrossCopy> copies;
}

/// Copies every foreign table the statement reads and rewrites those names
/// when the target schema already uses them.
CrossWritePlan planCrossWrite(
    String sql, SchemaNames names, String targetSchema) {
  return runZoned(() => _planCrossWrite(sql, names, targetSchema), zoneValues: {
    schemaNamesKey: {for (final name in names.order) name}
  });
}

CrossWritePlan _planCrossWrite(
    String sql, SchemaNames names, String targetSchema) {
  final parser = SqlParser(sql);
  final leadingCtes = <(String, SelectStatement)>[];
  if (parser.take('WITH')) {
    parser.take('RECURSIVE');
    do {
      final name = parser.identifier();
      if (parser.take('(')) {
        do {
          parser.identifier();
        } while (parser.take(','));
        parser.require(')');
      }
      parser.require('AS');
      if (parser.take('NOT')) parser.require('MATERIALIZED');
      parser.take('MATERIALIZED');
      parser.require('(');
      leadingCtes.add((name, parser.select(nested: true)));
      parser.require(')');
    } while (parser.take(','));
  }
  final replace = parser.take('REPLACE');
  final insert = replace || parser.take('INSERT');
  final update = !insert && parser.take('UPDATE');
  if (!insert && !update) {
    parser.require('DELETE');
    parser.require('FROM');
  }
  if (insert && !replace && parser.take('OR')) parser.identifier();
  if (update && parser.take('OR')) parser.identifier();
  if (insert) parser.require('INTO');
  var targetName = parser.identifier();
  if (parser.take('.')) targetName = parser.identifier();
  if (parser.take('AS')) parser.identifier();
  if (!insert && parser.take('INDEXED')) {
    parser.require('BY');
    parser.identifier();
  } else if (!insert && parser.take('NOT')) {
    parser.require('INDEXED');
  }
  final owned = <Expr>[];
  final from = <QuerySource>[];
  if (insert) {
    if (parser.take('(')) _skipParens(parser);
    if (parser.take('DEFAULT')) {
      parser.require('VALUES');
    } else if (parser.current.keyword == 'SELECT' ||
        parser.current.keyword == 'WITH') {
      throw const SqlException('cross-database statement is not supported');
    } else {
      parser.require('VALUES');
      do {
        parser.require('(');
        do {
          owned.add(parser.expression());
        } while (parser.take(','));
        parser.require(')');
      } while (parser.take(','));
    }
    while (parser.take('ON')) {
      parser.require('CONFLICT');
      if (parser.take('(')) _skipParens(parser);
      if (parser.take('WHERE')) owned.add(parser.expression());
      parser.require('DO');
      if (!parser.take('NOTHING')) {
        parser.require('UPDATE');
        parser.require('SET');
        do {
          if (parser.take('(')) {
            _skipParens(parser);
          } else {
            parser.identifier();
            if (parser.take('.')) parser.identifier();
          }
          parser.require('=');
          owned.add(parser.expression());
        } while (parser.take(','));
        if (parser.take('WHERE')) owned.add(parser.expression());
      }
    }
  } else if (update) {
    parser.require('SET');
    do {
      if (parser.take('(')) {
        _skipParens(parser);
      } else {
        parser.identifier();
      }
      parser.require('=');
      owned.add(parser.expression());
    } while (parser.take(','));
    if (parser.take('FROM')) from.addAll(parser.joinedSources());
  }
  if (!insert && parser.take('WHERE')) owned.add(parser.expression());
  if (parser.take('RETURNING')) {
    do {
      if (parser.take('*')) continue;
      owned.add(parser.expression());
    } while (parser.take(','));
  }
  final hits = <_ForeignUse>[];
  final qualified = <_QualifiedColumn>[];
  final seenCtes = <String>{};
  for (final cte in leadingCtes) {
    _walkSelect(cte.$2, seenCtes, names, targetSchema, hits, qualified);
    seenCtes.add(asciiLower(cte.$1));
  }
  final scope = {...seenCtes};
  for (final source in from) {
    _walkSource(source, scope, names, targetSchema, hits, qualified);
  }
  for (final expr in owned) {
    _walkExpr(expr, scope, names, targetSchema, hits, qualified);
  }
  final groups = <String, List<_ForeignUse>>{};
  for (final hit in hits) {
    groups
        .putIfAbsent('${hit.schema}.${asciiLower(hit.table)}', () => [])
        .add(hit);
  }
  final occupied = <String>{
    ...?names.tables[targetSchema],
    asciiLower(targetName),
  };
  final copies = <CrossCopy>[];
  for (final group in groups.values) {
    final sample = group.first;
    final preferred = asciiLower(sample.table);
    final String helper;
    if (occupied.add(preferred)) {
      helper = sample.table;
    } else {
      helper = _freshHelper(sample.schema, sample.table, occupied);
    }
    copies.add(CrossCopy(sample.schema, sample.table, helper));
    for (final hit in group) {
      hit.helper = helper;
    }
  }
  final tokens = SqlTokenizer.tokenize(sql);
  final edits = <(int, int, String)>[];
  for (final hit in hits) {
    final index = _tokenIndexAt(tokens, hit.offset);
    final qualifiedRef = index >= 2 && tokens[index - 1].text == '.';
    final sameName = asciiLower(hit.helper) == asciiLower(hit.table);
    if (!qualifiedRef && sameName) continue;
    final start = qualifiedRef ? tokens[index - 2].offset : hit.offset;
    final end = _tokenEnd(sql, tokens, index);
    final quoted = _quoteIdent(hit.helper);
    final replacement = hit.alias == null && !sameName
        ? '$quoted AS ${_quoteIdent(hit.table)}'
        : quoted;
    edits.add((start, end, replacement));
  }
  for (final column in qualified) {
    final hit = _hitFor(hits, column.schema, column.table);
    if (hit == null) continue;
    final index = _tokenIndexAt(tokens, column.tableOffset);
    final qualifiedRef = index >= 2 && tokens[index - 1].text == '.';
    final sameName = asciiLower(hit.helper) == asciiLower(hit.table);
    if (!qualifiedRef && sameName) continue;
    final start = qualifiedRef ? tokens[index - 2].offset : column.tableOffset;
    final visible = hit.alias ?? (sameName ? hit.helper : hit.table);
    edits.add((start, column.columnOffset, '${_quoteIdent(visible)}.'));
  }
  for (var i = 0; i + 2 < tokens.length; i++) {
    final token = tokens[i];
    if (token.kind != SqlTokenKind.identifier ||
        asciiLower(token.text) != targetSchema ||
        tokens[i + 1].text != '.' ||
        tokens[i + 2].kind != SqlTokenKind.identifier) {
      continue;
    }
    edits.add((token.offset, tokens[i + 2].offset, ''));
  }
  return CrossWritePlan(_splice(sql, edits), copies);
}

void _skipParens(SqlParser parser) {
  var depth = 1;
  while (depth > 0) {
    if (parser.current.kind == SqlTokenKind.end) {
      throw const SqlException('Expected )');
    }
    if (parser.current.text == '(') depth++;
    if (parser.current.text == ')') depth--;
    parser.position++;
  }
}

String _freshHelper(String schema, String table, Set<String> occupied) {
  var name = '__cross_${schema}_$table';
  var suffix = 2;
  while (!occupied.add(asciiLower(name))) {
    name = '__cross_${schema}_${table}_$suffix';
    suffix++;
  }
  return name;
}

_ForeignUse? _hitFor(List<_ForeignUse> hits, String schema, String table) {
  for (final hit in hits) {
    if (hit.schema == schema && asciiLower(hit.table) == asciiLower(table)) {
      return hit;
    }
  }
  return null;
}

void _walkSelect(
    SelectStatement statement,
    Set<String> outerCtes,
    SchemaNames names,
    String targetSchema,
    List<_ForeignUse> hits,
    List<_QualifiedColumn> qualified) {
  final scope = {...outerCtes, ...statement.ctes.keys};
  for (final source in statement.sources) {
    _walkSource(source, scope, names, targetSchema, hits, qualified);
  }
  void walk(Expr? expr) {
    if (expr != null) {
      _walkExpr(expr, scope, names, targetSchema, hits, qualified);
    }
  }

  for (final item in statement.items) {
    walk(item.expression);
  }
  walk(statement.where);
  walk(statement.having);
  for (final term in statement.groupBy) {
    walk(term);
  }
  for (final term in statement.order) {
    walk(term.expression);
  }
  walk(statement.limit);
  walk(statement.offset);
  var previous = outerCtes;
  for (final cte in statement.ctes.entries) {
    _walkSelect(cte.value.$2, previous, names, targetSchema, hits, qualified);
    previous = {...previous, cte.key};
  }
  for (final part in statement.compounds) {
    _walkSelect(part.$2, outerCtes, names, targetSchema, hits, qualified);
  }
}

void _walkSource(
    QuerySource source,
    Set<String> ctes,
    SchemaNames names,
    String targetSchema,
    List<_ForeignUse> hits,
    List<_QualifiedColumn> qualified) {
  if (source.query != null) {
    _walkSelect(source.query!, ctes, names, targetSchema, hits, qualified);
  }
  for (final child in source.group) {
    _walkSource(child, ctes, names, targetSchema, hits, qualified);
  }
  if (source.on != null) {
    _walkExpr(source.on!, ctes, names, targetSchema, hits, qualified);
  }
  final table = source.table;
  final offset = source.tableOffset;
  if (table == null || offset == null) return;
  final key = asciiLower(table);
  if (source.schema == null &&
      (ctes.contains(key) || pragmaTableColumns.containsKey(key))) {
    return;
  }
  final schema = source.schema ?? names.tableSchema(table);
  if (schema == null || schema == targetSchema) return;
  if (names.tables[schema]?.contains(key) != true) return;
  hits.add(_ForeignUse(schema, table, offset, source.alias));
}

void _walkExpr(
    Expr expr,
    Set<String> ctes,
    SchemaNames names,
    String targetSchema,
    List<_ForeignUse> hits,
    List<_QualifiedColumn> qualified) {
  if (expr is SubqueryExpr) {
    _walkSelect(expr.statement, ctes, names, targetSchema, hits, qualified);
  } else if (expr is InSelectExpr) {
    _walkSelect(expr.statement, ctes, names, targetSchema, hits, qualified);
  } else if (expr is ColumnExpr && expr.qualifier != null) {
    final parts = expr.qualifier!.split('.');
    if (parts.length == 2 && expr.columnOffset != null) {
      qualified.add(_QualifiedColumn(
          asciiLower(parts[0]), parts[1], expr.offset!, expr.columnOffset!));
    }
  }
  for (final child in expr.children) {
    _walkExpr(child, ctes, names, targetSchema, hits, qualified);
  }
}

int _tokenIndexAt(List<SqlToken> tokens, int offset) {
  final index = tokens.indexWhere((token) => token.offset == offset);
  if (index < 0) {
    throw const SqlException('cross-database statement is not supported');
  }
  return index;
}

int _tokenEnd(String sql, List<SqlToken> tokens, int index) {
  final token = tokens[index];
  if (!token.quoted) return token.offset + token.text.length;
  final next =
      index + 1 < tokens.length ? tokens[index + 1].offset : sql.length;
  var end = next;
  while (end > token.offset) {
    final unit = sql.codeUnitAt(end - 1);
    if (unit != 9 && unit != 10 && unit != 13 && unit != 32) break;
    end--;
  }
  return end;
}

String _quoteIdent(String name) => '"${name.replaceAll('"', '""')}"';

final class _ForeignUse {
  _ForeignUse(this.schema, this.table, this.offset, this.alias);
  final String schema;
  final String table;
  final int offset;
  final String? alias;
  String helper = '';
}

final class _QualifiedColumn {
  _QualifiedColumn(
      this.schema, this.table, this.tableOffset, this.columnOffset);
  final String schema;
  final String table;
  final int tableOffset;
  final int columnOffset;
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
