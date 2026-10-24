import '../btree/btree_reader.dart';
import '../pager/read_only_pager.dart';
import 'parser.dart';
import 'tokenizer.dart';
import 'values.dart';
import 'expressions.dart';
import 'schema_expressions.dart';

final class CatalogColumn {
  CatalogColumn(this.name, this.declaredType,
      {this.generatedExpression,
      this.generatedStored = false,
      this.notNullPolicy = 'ABORT',
      this.primaryKey = 0,
      this.defaultValue,
      this.defaultExpression,
      this.notNull = false,
      this.defaultSql,
      this.unique = false,
      this.collation = 'binary',
      this.autoIncrement = false,
      this.checks = const [],
      this.primaryDescending = false});
  final String name;
  final String declaredType;
  final Expr? generatedExpression;
  final bool generatedStored;
  int primaryKey;
  final Object? defaultValue;
  final Expr? defaultExpression;
  final bool notNull;
  final String notNullPolicy;
  final String? defaultSql;
  final bool unique, autoIncrement, primaryDescending;
  bool strict = false;
  final String collation;
  final List<Expr> checks;
  String get affinity => strict && declaredType.toUpperCase() == 'ANY'
      ? 'none'
      : affinityFor(declaredType);
}

final class CatalogTable {
  CatalogTable(this.name, this.rootPage, List<CatalogColumn> columns,
      {this.withoutRowid = false, this.rowidAlias})
      : columns = List.unmodifiable(columns);
  final String name;
  final int rootPage;
  final List<CatalogColumn> columns;
  final bool withoutRowid;
  final String? rowidAlias;
  final List<List<String>> uniqueKeys = [];
  final List<List<String>> autoIndexKeys = [];
  final List<String> autoIndexPolicies = [];
  String primaryPolicy = 'ABORT';
  final List<Expr> checks = [];
  final List<ForeignKey> foreignKeys = [];
  final List<CatalogColumn> generatedOrder = [];

  void evaluateGenerated(RowValues row, int encoding,
      {bool recomputeStored = false}) {
    final context = EvalContext(row,
        {for (final c in columns) asciiLower(c.name): c.affinity}, [], encoding)
      ..schemaExpression = true
      ..collations = {for (final c in columns) asciiLower(c.name): c.collation};
    for (final column in generatedOrder) {
      if (column.generatedStored && !recomputeStored) continue;
      var value = applyAffinity(
          column.generatedExpression!.evaluate(context), column.affinity);
      if (column.affinity == 'numeric' &&
          value is double &&
          value.isFinite &&
          value == value.truncateToDouble() &&
          value >= -(BigInt.one << 63).toDouble() &&
          value < (BigInt.one << 63).toDouble()) {
        value = BigInt.from(value);
      }
      if (value is BigInt &&
          !column.declaredType.toUpperCase().contains('INT') &&
          ['REAL', 'FLOA', 'DOUB']
              .any(column.declaredType.toUpperCase().contains)) {
        value = value.toDouble();
      }
      row[asciiLower(column.name)] = sqlValue(value);
    }
  }

  List<CatalogColumn> get storageColumns {
    final stored = columns
        .where((c) => c.generatedExpression == null || c.generatedStored)
        .toList();
    if (!withoutRowid) return stored;
    final keys = columns.where((c) => c.primaryKey != 0).toList()
      ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
    return [...keys, ...stored.where((c) => c.primaryKey == 0)];
  }
}

final class ForeignKey {
  ForeignKey(this.columns, this.table, this.targetColumns,
      {this.onDelete = 'NO ACTION',
      this.onUpdate = 'NO ACTION',
      this.deferred = false});
  final List<String> columns, targetColumns;
  final String table;
  final String onDelete, onUpdate;
  final bool deferred;
}

final class CatalogEntry {
  CatalogEntry(this.type, this.name, this.tableName, this.rootPage, this.sql);
  final String type;
  final String name;
  final String tableName;
  final int rootPage;
  final String? sql;
}

/// sqlite_schema metadata. CREATE definitions are parsed only when a table is used.
final class DatabaseCatalog {
  DatabaseCatalog._(this.entries);
  final List<CatalogEntry> entries;
  static Future<DatabaseCatalog> read(ReadOnlyPager pager) async {
    final entries = <CatalogEntry>[];
    await for (final record in BtreeReader(pager).scanTable(1)) {
      final v = record.values;
      if (v.length != 5 ||
          v[0] is! String ||
          v[1] is! String ||
          v[2] is! String ||
          v[3] is! BigInt ||
          v[4] != null && v[4] is! String) {
        throw const FormatException('Invalid sqlite_schema record');
      }
      final root = v[3] as BigInt;
      if (root < BigInt.zero || root > BigInt.from(pager.pageCount)) {
        throw const FormatException('Invalid catalog root page');
      }
      final name = v[1] as String;
      if (entries.any((entry) =>
          asciiLower(entry.name) == asciiLower(name) &&
          (entry.type == 'trigger') == (v[0] == 'trigger'))) {
        throw const FormatException('Duplicate catalog object');
      }
      entries.add(CatalogEntry(
          v[0] as String, name, v[2] as String, root.toInt(), v[4] as String?));
    }
    return DatabaseCatalog._(List.unmodifiable(entries));
  }

  CatalogTable table(String name) {
    if (['sqlite_schema', 'sqlite_master'].contains(asciiLower(name))) {
      return CatalogTable('sqlite_schema', 1, [
        CatalogColumn('type', 'TEXT'),
        CatalogColumn('name', 'TEXT'),
        CatalogColumn('tbl_name', 'TEXT'),
        CatalogColumn('rootpage', 'INT'),
        CatalogColumn('sql', 'TEXT'),
      ]);
    }
    final matches = entries.where(
        (e) => e.type != 'trigger' && asciiLower(e.name) == asciiLower(name));
    if (matches.isEmpty) throw SqlException('No such table: $name');
    final entry = matches.single;
    if (entry.type != 'table' || entry.sql == null || entry.rootPage == 0) {
      throw SqlException('Unsupported table or view: $name');
    }
    return parseTable(entry.sql!, entry.rootPage);
  }

  static CatalogTable parseTable(String sql, int rootPage) {
    final parser = SqlParser(sql);
    parser.require('CREATE');
    parser.require('TABLE');
    if (parser.take('IF')) {
      parser.require('NOT');
      parser.require('EXISTS');
    }
    final name = parser.identifier();
    parser.require('(');
    final columns = <CatalogColumn>[];
    final primary = <String>[];
    String? alias;
    var tablePrimary = false;
    final uniqueKeys = <List<String>>[];
    final autoKeys = <(bool, List<String>, String)>[];
    var primaryPolicy = 'ABORT';
    final tableChecks = <Expr>[];
    final foreignKeys = <ForeignKey>[];
    List<String> keyColumns() {
      parser.require('(');
      final names = <String>[];
      do {
        names.add(parser.identifier());
        if (parser.take('COLLATE')) parser.identifier();
        if (!parser.take('ASC')) {
          if (parser.take('DESC')) {
            throw const SqlException(
                'Descending constraint keys require explicit index support');
          }
        }
      } while (parser.take(','));
      parser.require(')');
      return names;
    }

    String conflict() {
      if (!parser.take('ON')) return 'DEFAULT';
      parser.require('CONFLICT');
      final policy = parser.identifier().toUpperCase();
      if (!['ABORT', 'IGNORE', 'REPLACE', 'FAIL', 'ROLLBACK']
          .contains(policy)) {
        throw const SqlException('Invalid conflict policy');
      }
      return policy;
    }

    ForeignKey references(List<String> names) {
      final target = parser.identifier();
      final targetColumns =
          parser.current.text == '(' ? keyColumns() : <String>[];
      var onDelete = 'NO ACTION';
      var onUpdate = 'NO ACTION';
      var deferred = false;
      while (true) {
        if (parser.take('ON')) {
          final delete = parser.take('DELETE');
          if (!delete) parser.require('UPDATE');
          String action;
          if (parser.take('SET')) {
            if (parser.take('NULL')) {
              action = 'SET NULL';
            } else {
              parser.require('DEFAULT');
              action = 'SET DEFAULT';
            }
          } else if (parser.take('NO')) {
            parser.require('ACTION');
            action = 'NO ACTION';
          } else if (parser.take('CASCADE')) {
            action = 'CASCADE';
          } else {
            parser.require('RESTRICT');
            action = 'RESTRICT';
          }
          if (delete) {
            onDelete = action;
          } else {
            onUpdate = action;
          }
        } else if (parser.take('MATCH')) {
          parser.identifier();
        } else if (parser.take('DEFERRABLE')) {
          if (parser.take('INITIALLY')) {
            deferred = parser.take('DEFERRED');
            if (!deferred) parser.require('IMMEDIATE');
          }
        } else if (parser.current.keyword == 'NOT' &&
            parser.tokens[parser.position + 1].keyword == 'DEFERRABLE') {
          parser.position += 2;
        } else {
          break;
        }
      }
      if (targetColumns.isNotEmpty && targetColumns.length != names.length) {
        throw const SqlException('Foreign key width mismatch');
      }
      return ForeignKey(names, target, targetColumns,
          onDelete: onDelete, onUpdate: onUpdate, deferred: deferred);
    }

    do {
      if (parser.take('CONSTRAINT')) parser.identifier();
      if (parser.take('UNIQUE')) {
        final key = keyColumns();
        uniqueKeys.add(key);
        autoKeys.add((false, key, conflict()));
      } else if (parser.take('CHECK')) {
        parser.require('(');
        tableChecks.add(parser.expression());
        parser.require(')');
        conflict();
      } else if (parser.take('FOREIGN')) {
        parser.require('KEY');
        final names = keyColumns();
        parser.require('REFERENCES');
        foreignKeys.add(references(names));
      } else if (parser.take('PRIMARY')) {
        if (tablePrimary || primary.isNotEmpty) {
          throw const SqlException('Multiple primary keys');
        }
        tablePrimary = true;
        parser.require('KEY');
        primary.addAll(keyColumns());
        primaryPolicy = conflict();
        autoKeys.add((true, List.of(primary), primaryPolicy));
      } else {
        final columnName = parser.identifier();
        if (['CONSTRAINT', 'FOREIGN', 'UNIQUE', 'CHECK']
            .contains(columnName.toUpperCase())) {
          throw const SqlException('Unsupported table constraint');
        }
        if (columns.any((c) => asciiLower(c.name) == asciiLower(columnName))) {
          throw const SqlException('Duplicate column');
        }
        final type = <String>[];
        final declaredStart = parser.current.offset;
        var quotedType = false;
        while (parser.current.kind == SqlTokenKind.identifier &&
            ![
              'PRIMARY',
              'NOT',
              'NULL',
              'DEFAULT',
              'COLLATE',
              'UNIQUE',
              'CHECK',
              'REFERENCES',
              'GENERATED',
              'AS',
              'CONSTRAINT'
            ].contains(parser.current.keyword)) {
          quotedType = quotedType || parser.current.quoted;
          type.add(parser.identifier());
        }
        var declaredType = type.join(' ');
        if (parser.take('(')) {
          final sizes = <String>[];
          if (parser.current.kind != SqlTokenKind.number) {
            throw const SqlException('Invalid type size');
          }
          sizes.add(parser.current.text);
          parser.position++;
          if (parser.take(',')) {
            if (parser.current.kind != SqlTokenKind.number) {
              throw const SqlException('Invalid type size');
            }
            sizes.add(parser.current.text);
            parser.position++;
          }
          parser.require(')');
          declaredType += '(${sizes.join(',')})';
        }
        if (!quotedType) {
          declaredType =
              sql.substring(declaredStart, parser.current.offset).trim();
        }
        if (['ANY', 'BLOB', 'INT', 'INTEGER', 'REAL', 'TEXT']
            .contains(declaredType.toUpperCase())) {
          declaredType = declaredType.toUpperCase();
        }
        var columnPrimary = false;
        var unique = false;
        var autoIncrement = false;
        var collation = 'binary';
        final columnChecks = <Expr>[];
        var notNull = false;
        var notNullPolicy = 'ABORT';
        String? defaultSql;
        var descending = false;
        Object? defaultValue;
        Expr? defaultExpression;
        Expr? generatedExpression;
        var generatedStored = false;
        while (parser.current.text != ',' && parser.current.text != ')') {
          if (parser.take('CONSTRAINT')) {
            parser.identifier();
            continue;
          }
          if (parser.take('PRIMARY')) {
            parser.require('KEY');
            columnPrimary = true;
            descending = parser.take('DESC');
            if (!descending) parser.take('ASC');
            primaryPolicy = conflict();
            autoKeys.add((true, [columnName], primaryPolicy));
            autoIncrement = parser.take('AUTOINCREMENT');
          } else if (parser.take('NOT')) {
            parser.require('NULL');
            notNull = true;
            notNullPolicy = conflict();
          } else if (parser.take('UNIQUE')) {
            unique = true;
            autoKeys.add((false, [columnName], conflict()));
          } else if (parser.take('CHECK')) {
            parser.require('(');
            columnChecks.add(parser.expression());
            parser.require(')');
          } else if (parser.take('REFERENCES')) {
            foreignKeys.add(references([columnName]));
          } else if (parser.take('NULL')) {
          } else if (parser.take('DEFAULT')) {
            final start = parser.current.offset;
            final expr = parser.expression();
            defaultSql = sql.substring(start, parser.current.offset).trim();
            if (defaultSql.startsWith('(') && defaultSql.endsWith(')')) {
              defaultSql =
                  defaultSql.substring(1, defaultSql.length - 1).trim();
            }
            if (parser.parameterCount != 0) {
              throw const SqlException(
                  'Parameters not allowed in schema defaults');
            }
            expr.validate({});
            defaultExpression = expr;
            if (expr is Literal || expr is UnaryExpr) {
              defaultValue = expr.evaluate(EvalContext({}, {}, []));
            }
          } else if (parser.current.keyword == 'GENERATED' ||
              parser.current.keyword == 'AS') {
            if (generatedExpression != null) {
              throw const SqlException('Multiple generated expressions');
            }
            if (parser.take('GENERATED')) parser.take('ALWAYS');
            parser.require('AS');
            parser.require('(');
            generatedExpression = parser.expression();
            parser.require(')');
            generatedStored = parser.take('STORED');
            if (!generatedStored) parser.take('VIRTUAL');
          } else if (parser.take('COLLATE')) {
            collation = asciiLower(parser.identifier());
            if (!['binary', 'nocase', 'rtrim'].contains(collation)) {
              throw const SqlException('Unknown collation');
            }
          } else {
            throw SqlException(
                'Unsupported column constraint', parser.current.offset);
          }
        }
        if (columnPrimary) {
          if (tablePrimary || primary.isNotEmpty) {
            throw const SqlException('Multiple primary keys');
          }
          primary.add(columnName);
          if (declaredType.toUpperCase() == 'INTEGER' && !descending) {
            alias = columnName;
          }
        }
        columns.add(CatalogColumn(columnName, declaredType,
            generatedExpression: generatedExpression,
            generatedStored: generatedStored,
            defaultValue: defaultValue,
            defaultExpression: defaultExpression,
            notNull: notNull,
            notNullPolicy: notNullPolicy == 'DEFAULT' ? 'ABORT' : notNullPolicy,
            defaultSql: defaultSql,
            unique: unique,
            collation: collation,
            autoIncrement: autoIncrement,
            checks: columnChecks,
            primaryDescending: descending));
      }
    } while (parser.take(','));
    parser.require(')');
    var withoutRowid = false;
    if (parser.take('WITHOUT')) {
      parser.require('ROWID');
      withoutRowid = true;
    }
    final strict = parser.take('STRICT');
    for (final column in columns) {
      column.strict = strict;
      if (strict &&
          !['INT', 'INTEGER', 'REAL', 'TEXT', 'BLOB', 'ANY']
              .contains(column.declaredType.toUpperCase())) {
        throw const SqlException('Invalid STRICT column type');
      }
    }
    if (columns
        .any((c) => c.autoIncrement && (withoutRowid || c.name != alias))) {
      throw const SqlException('Invalid AUTOINCREMENT column');
    }
    parser.finish();
    for (var i = 0; i < primary.length; i++) {
      final matches =
          columns.where((c) => asciiLower(c.name) == asciiLower(primary[i]));
      if (matches.isEmpty) {
        throw const SqlException('Unknown primary key column');
      }
      matches.single.primaryKey = i + 1;
    }
    if (withoutRowid && primary.isEmpty) {
      throw const SqlException('Missing WITHOUT ROWID primary key');
    }
    if (tablePrimary && primary.length == 1) {
      final column = columns.firstWhere((c) => c.primaryKey == 1);
      if (column.declaredType.toUpperCase() == 'INTEGER') alias = column.name;
    }
    final result = CatalogTable(name, rootPage, columns,
        withoutRowid: withoutRowid, rowidAlias: withoutRowid ? null : alias)
      ..primaryPolicy = primaryPolicy == 'DEFAULT' ? 'ABORT' : primaryPolicy
      ..uniqueKeys.addAll(uniqueKeys)
      ..checks.addAll(tableChecks)
      ..foreignKeys.addAll(foreignKeys);
    final generated =
        columns.where((c) => c.generatedExpression != null).toList();
    if (generated.length == columns.length) {
      throw const SqlException('At least one ordinary column required');
    }
    final names = columns.map((c) => asciiLower(c.name)).toSet();
    for (final column in generated) {
      if (column.primaryKey != 0 || column.defaultSql != null) {
        throw const SqlException(
            'Generated columns cannot have defaults or primary keys');
      }
      validateSchemaExpression(column.generatedExpression!, names);
    }
    final visiting = <String>{}, visited = <String>{};
    void visit(CatalogColumn column) {
      final key = asciiLower(column.name);
      if (visited.contains(key)) return;
      if (!visiting.add(key)) {
        throw const SqlException('Generated column dependency cycle');
      }
      for (final ref in column.generatedExpression!.unaggregatedColumns) {
        final dependency =
            generated.where((c) => asciiLower(c.name) == ref).firstOrNull;
        if (dependency != null) visit(dependency);
      }
      visiting.remove(key);
      visited.add(key);
      result.generatedOrder.add(column);
    }

    for (final column in generated) {
      visit(column);
    }
    final seenKeys = <String, int>{};
    for (final key in autoKeys) {
      if (key.$1 && alias != null && !withoutRowid) continue;
      final identity = key.$2.map(asciiLower).join('\u0000');
      final existing = seenKeys[identity];
      if (existing == null) {
        seenKeys[identity] = result.autoIndexKeys.length;
        result.autoIndexKeys.add(key.$2);
        result.autoIndexPolicies.add(key.$3);
      } else if (key.$3 != 'DEFAULT') {
        final previous = result.autoIndexPolicies[existing];
        if (previous != 'DEFAULT' && previous != key.$3) {
          throw const SqlException('Conflicting ON CONFLICT clauses');
        }
        result.autoIndexPolicies[existing] = key.$3;
      }
    }
    for (var i = 0; i < result.autoIndexPolicies.length; i++) {
      if (result.autoIndexPolicies[i] == 'DEFAULT') {
        result.autoIndexPolicies[i] = 'ABORT';
      }
    }
    final declaredNames = columns.map((c) => asciiLower(c.name)).toSet();
    for (final fk in foreignKeys) {
      if (fk.columns.any((c) => !declaredNames.contains(asciiLower(c)))) {
        throw const SqlException('Unknown local foreign key column');
      }
    }
    bool invalidCheck(Expr expr) =>
        expr is SubqueryExpr ||
        expr is InSelectExpr ||
        expr.containsAggregate ||
        expr.containsWindow ||
        expr.children.any(invalidCheck);
    for (final check in [
      ...tableChecks,
      ...columns.expand((column) => column.checks)
    ]) {
      if (invalidCheck(check)) {
        throw const SqlException(
            'Subqueries/aggregates are prohibited in CHECK');
      }
      check.validate(columns.map((c) => asciiLower(c.name)).toSet());
    }
    return result;
  }
}
