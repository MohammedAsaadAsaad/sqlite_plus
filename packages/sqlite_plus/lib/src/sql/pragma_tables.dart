part of 'database.dart';

/// IN/OR constraints are expanded into SQLite-style ordered, distinct scans.
final class _PragmaArgumentOptions extends Expr {
  _PragmaArgumentOptions(this.values);
  final List<Expr> values;
  @override
  Iterable<Expr> get children => values;
  @override
  void validate(Set<String> columns) {
    for (final value in values) {
      value.validate(columns);
    }
  }

  @override
  Object? evaluate(EvalContext context) {
    final options = [for (final value in values) value.evaluate(context)]
      ..removeWhere((value) => value == null)
      ..sort((a, b) => compareValues(a, b, context.encoding));
    return [
      for (var i = 0; i < options.length; i++)
        if (i == 0 ||
            compareValues(options[i - 1], options[i], context.encoding) != 0)
          options[i]
    ];
  }
}

extension _PragmaTableQueries on SqliteDatabase {
  bool _isPragmaTableSource(QuerySource source) {
    if (source.table == null) return false;
    final name = asciiLower(source.table!);
    if (!pragmaTableColumns.containsKey(name)) return false;
    final physical = catalog.entries.any((entry) =>
        asciiLower(entry.name) == name &&
        (entry.type == 'table' || entry.type == 'view'));
    if (physical && source.pragmaArguments != null) {
      throw SqlException('${source.table} is not a table-valued function');
    }
    return !physical;
  }

  CatalogTable _pragmaSourceTable(QuerySource source) {
    final name = asciiLower(source.table!);
    return CatalogTable(name, -1, [
      for (final name in pragmaTableColumns[name]!)
        CatalogColumn(name, '', affinityOverride: 'none'),
      if (pragmaTableHasArgument(name)) ...[
        CatalogColumn('arg', '', affinityOverride: 'none', hidden: true),
        CatalogColumn('schema', '', affinityOverride: 'none', hidden: true)
      ]
    ]);
  }

  (List<Expr>, Set<Expr>) _pragmaSourceArguments(
      QuerySource source, SelectStatement statement, Set<String> preceding) {
    final inputs = [...?source.pragmaArguments];
    final consumed = <Expr>{};
    if (!pragmaTableHasArgument(source.table!)) return (inputs, consumed);
    final alias = asciiLower(source.alias ?? source.table!);
    bool matches(Expr value, String field) =>
        value is ColumnExpr &&
        {field, '$alias.$field', 'main.$alias.$field'}.contains(value.key) &&
        !(value.key == field && preceding.contains(field));
    final ownFields = {
      ...pragmaTableColumns[asciiLower(source.table!)]!,
      'arg',
      'schema',
      'rowid',
      '_rowid_',
      'oid'
    };
    bool usable(Expr expression) =>
        expression.unaggregatedColumns.every((key) =>
            !key.startsWith('$alias.') &&
            !key.startsWith('main.$alias.') &&
            (!ownFields.contains(key) || preceding.contains(key)));
    List<Expr>? alternatives(Expr expression, String field) {
      if (expression is! BinaryExpr) return null;
      if (expression.op == 'OR') {
        final left = alternatives(expression.left, field);
        final right = alternatives(expression.right, field);
        return left == null || right == null ? null : [...left, ...right];
      }
      if (expression.op != '=' && expression.op != '==') return null;
      if (matches(expression.left, field) && usable(expression.right)) {
        return [expression.right];
      }
      if (matches(expression.right, field) && usable(expression.left)) {
        return [expression.left];
      }
      return null;
    }

    Expr? constraint(Expr? expression, String field) {
      if (expression is InExpr &&
          !expression.negate &&
          matches(expression.operand, field) &&
          expression.values.every(usable)) {
        consumed.add(expression);
        return _PragmaArgumentOptions(expression.values);
      }
      if (expression is! BinaryExpr) return null;
      if (expression.op == 'AND') {
        return constraint(expression.left, field) ??
            constraint(expression.right, field);
      }
      final values = alternatives(expression, field);
      if (values == null) return null;
      consumed.add(expression);
      return expression.op == 'OR'
          ? _PragmaArgumentOptions(values)
          : values.single;
    }

    for (final field in ['arg', 'schema'].skip(inputs.length)) {
      final expression =
          constraint(statement.where, field) ?? constraint(source.on, field);
      inputs.add(expression ?? Literal(null));
    }
    return (inputs, consumed);
  }

  Expr _omitPragmaConstraints(Expr expression, Set<Expr> consumed) {
    if (consumed.contains(expression)) return Literal(BigInt.one);
    if (expression is BinaryExpr && expression.op == 'AND') {
      return BinaryExpr(
          'AND',
          _omitPragmaConstraints(expression.left, consumed),
          _omitPragmaConstraints(expression.right, consumed));
    }
    return expression;
  }

  List<RowValues> _pragmaSourceRows(
      QuerySource source, List<Expr> arguments, EvalContext context) {
    List<Object?> options(Expr expression) =>
        expression is _PragmaArgumentOptions
            ? expression.evaluate(context) as List<Object?>
            : [expression.evaluate(context)];
    if (arguments.isEmpty) return _pragmaSourceScan(source, const [], context);
    return [
      for (final argument in options(arguments[0]))
        if (arguments.length == 1)
          ..._pragmaSourceScan(source, [argument], context)
        else
          for (final schema in options(arguments[1]))
            ..._pragmaSourceScan(source, [argument, schema], context)
    ];
  }

  List<RowValues> _pragmaSourceScan(
      QuerySource source, List<Object?> values, EvalContext context) {
    final name = asciiLower(source.table!);
    final argument = values.isNotEmpty && values[0] != null
        ? stringify(values[0]!, context.encoding)
        : null;
    final schema = values.length > 1 && values[1] != null
        ? stringify(values[1]!, context.encoding)
        : null;
    if ((!pragmaTableHasArgument(name) || argument != null) &&
        schema != null &&
        !['main', 'temp'].contains(asciiLower(schema))) {
      throw SqlException('Unknown database: $schema');
    }
    final result = schema != null && asciiLower(schema) == 'temp' ||
            pragmaTableHasArgument(name) && argument == null
        ? QueryResult(pragmaTableColumns[name]!, [])
        : _readMetadataPragma(name.substring(7), argument)!;
    return [
      for (var i = 0; i < result.rows.length; i++)
        {
          for (var j = 0; j < result.columns.length; j++)
            asciiLower(result.columns[j]): result.rows[i][j],
          if (pragmaTableHasArgument(name)) ...{
            'arg': values.isNotEmpty ? values[0] : null,
            'schema': values.length > 1 ? values[1] : null
          },
          for (final key in ['rowid', '_rowid_', 'oid']) key: BigInt.from(i + 1)
        }
    ];
  }

  // The metadata-only dispatcher is shared by statements and table sources.
  QueryResult? _readMetadataPragma(String name, String? argument) {
    if (name == 'collation_list') {
      return QueryResult([
        'seq',
        'name'
      ], [
        [BigInt.zero, 'RTRIM'],
        [BigInt.one, 'NOCASE'],
        [BigInt.two, 'BINARY']
      ]);
    }
    if (name == 'database_list') {
      // StorageBackend images have no SQL attachment or filename identity.
      return QueryResult([
        'seq',
        'name',
        'file'
      ], [
        [BigInt.zero, 'main', '']
      ]);
    }
    if (name == 'pragma_list') {
      return QueryResult([
        'name'
      ], [
        for (final name in SqliteDatabase._pragmaNames) [name]
      ]);
    }
    if (name == 'function_list') return _pragmaFunctions();
    if (name == 'foreign_key_list' && argument != null) {
      final cols = [
        'id',
        'seq',
        'table',
        'from',
        'to',
        'on_update',
        'on_delete',
        'match'
      ];
      final entry = catalog.entries
          .where((e) =>
              e.type == 'table' && asciiLower(e.name) == asciiLower(argument))
          .firstOrNull;
      if (entry == null) return QueryResult(cols, []);
      final keys = catalog.table(argument).foreignKeys.reversed.toList();
      return QueryResult(cols, [
        for (var i = 0; i < keys.length; i++)
          for (var j = 0; j < keys[i].columns.length; j++)
            [
              BigInt.from(i),
              BigInt.from(j),
              keys[i].table,
              keys[i].columns[j],
              keys[i].targetColumns.isEmpty ? null : keys[i].targetColumns[j],
              keys[i].onUpdate,
              keys[i].onDelete,
              'NONE'
            ]
      ]);
    }
    if (name == 'index_list' && argument != null) {
      final cols = ['seq', 'name', 'unique', 'origin', 'partial'];
      final tableEntry = catalog.entries
          .where((e) =>
              e.type == 'table' && asciiLower(e.name) == asciiLower(argument))
          .firstOrNull;
      if (tableEntry == null) return QueryResult(cols, []);
      final table = catalog.table(argument);
      final entries = catalog.entries
          .where((e) =>
              e.type == 'index' &&
              asciiLower(e.tableName) == asciiLower(argument))
          .toList();
      if (table.withoutRowid) {
        final ordinal = table.autoIndexPrimary.indexOf(true);
        entries.add(CatalogEntry(
            'index',
            'sqlite_autoindex_${table.name}_${ordinal + 1}',
            table.name,
            table.rootPage,
            null));
        entries.sort((a, b) => a.sql == null && b.sql == null
            ? int.parse(a.name.split('_').last)
                .compareTo(int.parse(b.name.split('_').last))
            : catalog.entries.indexOf(a).compareTo(catalog.entries.indexOf(b)));
      }
      final reversed = entries.reversed.toList();
      return QueryResult(cols, [
        for (var i = 0; i < reversed.length; i++)
          [
            BigInt.from(i),
            reversed[i].name,
            boolean(_indexDefinition(reversed[i]).$5),
            _indexDefinition(reversed[i]).$4,
            boolean(reversed[i].sql != null &&
                SqlParser(reversed[i].sql!)
                    .tokens
                    .any((t) => t.keyword == 'WHERE'))
          ]
      ]);
    }
    if (['index_info', 'index_xinfo'].contains(name) && argument != null) {
      final extended = name == 'index_xinfo';
      final cols = [
        'seqno',
        'cid',
        'name',
        if (extended) ...['desc', 'coll', 'key']
      ];
      var entry = catalog.entries
          .where((e) =>
              e.type == 'index' && asciiLower(e.name) == asciiLower(argument))
          .firstOrNull;
      if (entry == null) {
        for (final tableEntry
            in catalog.entries.where((e) => e.type == 'table')) {
          final table = catalog.table(tableEntry.name);
          if (!table.withoutRowid) continue;
          final primary = table.autoIndexPrimary.indexOf(true);
          if (asciiLower(argument) == asciiLower(table.name) ||
              asciiLower(argument) ==
                  asciiLower('sqlite_autoindex_${table.name}_${primary + 1}')) {
            entry = CatalogEntry(
                'index',
                'sqlite_autoindex_${table.name}_${primary + 1}',
                table.name,
                table.rootPage,
                null);
            break;
          }
        }
      }
      if (entry == null) return QueryResult(cols, []);
      final definition = _indexDefinition(entry);
      final table = catalog.table(entry.tableName);
      final keys = definition.$1.toList();
      final descending = definition.$2.toList();
      final collations = definition.$3.toList();
      final keyCount = keys.length;
      final expressions = entry.sql == null
          ? <int>{}
          : {
              for (var i = 0; i < keyCount; i++)
                if (IndexDefinition.parse(entry.sql!, table)
                        .terms[i]
                        .columnName ==
                    null)
                  i
            };
      if (extended) {
        if (!table.withoutRowid) {
          keys.add('');
          descending.add(false);
          collations.add('binary');
        } else {
          final pk = table.columns.where((c) => c.primaryKey != 0).toList()
            ..sort((a, b) => a.primaryKey.compareTo(b.primaryKey));
          for (final col in pk) {
            if (!List.generate(
                    keyCount,
                    (i) =>
                        !expressions.contains(i) &&
                        asciiLower(keys[i]) == asciiLower(col.name) &&
                        collations[i] ==
                            table.primaryKeyCollations[col.primaryKey - 1])
                .any((v) => v)) {
              keys.add(col.name);
              descending.add(entry.sql != null &&
                  table.primaryKeyDescending[col.primaryKey - 1]);
              collations.add(table.primaryKeyCollations[col.primaryKey - 1]);
            }
          }
          if (definition.$4 == 'pk') {
            for (final column in table.storageColumns
                .where((column) => column.primaryKey == 0)) {
              keys.add(column.name);
              descending.add(false);
              collations.add(column.collation);
            }
          }
        }
      }
      return QueryResult(cols, [
        for (var i = 0; i < keys.length; i++)
          [
            BigInt.from(i),
            BigInt.from(expressions.contains(i)
                ? -2
                : i >= keyCount && !table.withoutRowid
                    ? -1
                    : table.columns.indexWhere(
                        (c) => asciiLower(c.name) == asciiLower(keys[i]))),
            expressions.contains(i) || i >= keyCount && !table.withoutRowid
                ? null
                : keys[i],
            if (extended) ...[
              boolean(descending[i]),
              collations[i].toUpperCase(),
              boolean(i < keyCount)
            ]
          ]
      ]);
    }
    if (['table_info', 'table_xinfo'].contains(name) && argument != null) {
      final cols = [
        'cid',
        'name',
        'type',
        'notnull',
        'dflt_value',
        'pk',
        if (name == 'table_xinfo') 'hidden'
      ];
      final exists =
          ['sqlite_schema', 'sqlite_master'].contains(asciiLower(argument)) ||
              pragmaTableColumns.containsKey(asciiLower(argument)) ||
              catalog.entries.any((entry) =>
                  asciiLower(entry.name) == asciiLower(argument) &&
                  ['table', 'view'].contains(entry.type));
      if (!exists) return QueryResult(cols, []);
      final view = catalog.entries.any((entry) =>
          entry.type == 'view' &&
          asciiLower(entry.name) == asciiLower(argument));
      final synthetic = pragmaTableColumns.containsKey(asciiLower(argument)) &&
          !catalog.entries
              .any((entry) => asciiLower(entry.name) == asciiLower(argument));
      final table =
          view || synthetic ? _pragmaTable(argument) : catalog.table(argument);
      final visible = table.columns
          .where((c) =>
              name == 'table_xinfo' ||
              c.generatedExpression == null && !c.hidden)
          .toList();
      return QueryResult(cols, [
        for (var i = 0; i < visible.length; i++)
          [
            BigInt.from(i),
            visible[i].name,
            visible[i].declaredType,
            boolean(visible[i].notNull ||
                (table.withoutRowid ||
                        visible[i].strict &&
                            visible[i].name != table.rowidAlias) &&
                    visible[i].primaryKey != 0),
            visible[i].defaultSql,
            BigInt.from(visible[i].primaryKey),
            if (name == 'table_xinfo')
              BigInt.from(visible[i].generatedExpression == null
                  ? visible[i].hidden
                      ? 1
                      : 0
                  : visible[i].generatedStored
                      ? 3
                      : 2)
          ]
      ]);
    }
    return null;
  }
}
