part of '../sqlite_plus_orm.dart';

/// Whether an operation can run without a reviewed approval.
enum MigrationSafety { safe, reviewRequired }

/// Kind of one step in a schema plan.
enum MigrationKind {
  createTable,
  addColumn,
  createIndex,
  dropIndex,
  manualSql,
  reviewPlan,
  retainTable,
  requiresMigration,
  recordModel,
}

/// One immutable, reviewable action. Application-authored SQL always needs
/// approval for the exact plan containing it.
final class MigrationOperation {
  MigrationOperation._(this.kind, this.description, this.sql, this.safety,
      [List<Object?> parameters = const [], this._retainedTable])
      : _parameters = List.unmodifiable(parameters.map(copyOrmValue));

  /// One application-authored statement. It always requires approval.
  factory MigrationOperation.sql(String sql,
      {String reason = 'Explicit application migration SQL',
      List<Object?> parameters = const []}) {
    final head = _migrationSqlTokens(sql).firstOrNull?.value.toUpperCase();
    if (![
      'CREATE',
      'ALTER',
      'DROP',
      'INSERT',
      'UPDATE',
      'DELETE',
      'REPLACE',
      'WITH',
      'REINDEX',
      'ANALYZE'
    ].contains(head)) {
      throw const OrmMappingException(
          'Migration SQL must be one schema/data statement without transaction or PRAGMA control');
    }
    if (reason.trim().isEmpty) {
      throw const OrmMappingException('Migration SQL needs a review reason');
    }
    return MigrationOperation._(MigrationKind.manualSql, reason, sql,
        MigrationSafety.reviewRequired, parameters);
  }

  /// Explicitly retain a previously managed table as an unmanaged table.
  factory MigrationOperation.retainTable(String tableName) {
    _ormValidateName(tableName);
    return MigrationOperation._(
        MigrationKind.retainTable,
        'Retain unmapped table $tableName and its data',
        null,
        MigrationSafety.reviewRequired,
        const [],
        _ormAsciiLower(tableName));
  }

  /// What this step does.
  final MigrationKind kind;

  /// Review text shown with the step.
  final String description;

  /// SQL to run, or null for a bookkeeping step.
  final String? sql;

  /// Whether the step can run inside [SchemaMigrator.applySafe].
  final MigrationSafety safety;
  final List<Object?> _parameters;
  final String? _retainedTable;

  /// A fresh copy of the statement parameters.
  List<Object?> get parameters =>
      List.unmodifiable(_parameters.map(copyOrmValue));

  /// Whether [SchemaMigrator.apply] must receive approval for the plan.
  bool get requiresApproval => safety == MigrationSafety.reviewRequired;
}

/// A snapshot of the live schema, the desired model and the exact actions.
/// A new plan is required whenever any schema object or the model changes.
final class SchemaPlan {
  SchemaPlan._(this.baselineSchema, this.targetSchema,
      List<MigrationOperation> operations, this._nextVersion,
      {required bool catalogAbsent})
      : _catalogAbsent = catalogAbsent,
        operations = List.unmodifiable(operations);

  /// Canonical text of the schema that was read.
  final String baselineSchema;

  /// Canonical text of the schema the model wants.
  final String targetSchema;

  /// Steps that turn [baselineSchema] into [targetSchema].
  final List<MigrationOperation> operations;
  final BigInt _nextVersion;
  final bool _catalogAbsent;

  /// Whether the plan has no steps.
  bool get isEmpty => operations.isEmpty;

  /// Whether any step needs [MigrationApproval].
  bool get requiresApproval => operations.any((op) => op.requiresApproval);

  /// Whether every step is expressible by the migrator.
  bool get canApply =>
      !operations.any((op) => op.kind == MigrationKind.requiresMigration);

  /// Replace proposed actions with explicitly supplied steps, for example a
  /// reviewed table rebuild with an INSERT SELECT column mapping. The model
  /// and baseline remain bound to this new immutable plan.
  SchemaPlan withOperations(Iterable<MigrationOperation> replacement) {
    final actions = replacement
        .where((operation) =>
            operation.kind != MigrationKind.recordModel &&
            operation.kind != MigrationKind.reviewPlan)
        .toList();
    actions.add(MigrationOperation._(
        MigrationKind.reviewPlan,
        'Review explicit replacement migration actions',
        null,
        MigrationSafety.reviewRequired));
    if (actions.isNotEmpty || !isEmpty) {
      actions.add(_recordModelOperation(_nextVersion));
    }
    return SchemaPlan._(baselineSchema, targetSchema, actions, _nextVersion,
        catalogAbsent: _catalogAbsent);
  }
}

/// Approval cannot be reused for another plan, including a modified copy.
final class MigrationApproval {
  /// Approves this exact [plan]. A copied or newer plan needs a new approval.
  MigrationApproval.forPlan(SchemaPlan plan) : _plan = plan;
  final SchemaPlan _plan;
}

/// Schema changes through public SQL metadata and the public connection only.
final class SchemaMigrator {
  /// Plans and applies schema changes for [model] on [connection].
  SchemaMigrator(this.connection, this.model, {OrmOperationRunner? serialize})
      : _serialize = serialize {
    if (model.entities.any((entity) =>
        _ormAsciiLower(entity.tableName) == _migrationCatalogName)) {
      throw const OrmMappingException(
          'The ORM metadata table name is reserved');
    }
  }

  /// Connection that owns the migration transaction.
  final OrmConnection connection;

  /// Model the target schema is built from.
  final DbModel model;
  final OrmOperationRunner? _serialize;
  bool _failed = false;
  Future<void> _tail = Future.value();

  Future<R> _run<R>(Future<R> Function() action) {
    if (_serialize != null) return _serialize(action);
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  /// Diffs the live schema against [model].
  Future<SchemaPlan> plan() => _run(_plan);

  /// Creates the model schema when the database has no ORM catalog.
  Future<void> ensureCreated() => _run(() async {
        final proposed = await _plan();
        await _apply(proposed, safeOnly: true);
      });

  /// Applies only steps marked [MigrationSafety.safe].
  Future<void> applySafe(SchemaPlan plan) =>
      _run(() => _apply(plan, safeOnly: true));

  /// Applies [plan]. Steps that require review need [approval] for this plan.
  Future<void> apply(SchemaPlan plan, {MigrationApproval? approval}) =>
      _run(() => _apply(plan, approval: approval));

  void _checkUsable() {
    if (_failed) {
      throw const OrmStateException(
          'Migration connection has an indeterminate transaction outcome; reopen it');
    }
    if (connection.inTransaction) {
      throw const OrmStateException(
          'Migrations require ownership of the complete transaction');
    }
  }

  Future<SchemaPlan> _plan() async {
    _checkUsable();
    final live = await _inspect();
    final target = _modelSchema(model);
    final operations = <MigrationOperation>[];
    final targets = {
      for (final entity in model.entities)
        _ormAsciiLower(entity.tableName): entity
    };
    for (final entity in model.entities) {
      final name = _ormAsciiLower(entity.tableName);
      final actual = live.tables[name];
      if (actual == null) {
        if (live.objects.any((object) =>
            ['table', 'view', 'index'].contains(object.type) &&
            _ormAsciiLower(object.name) == name)) {
          operations.add(_migrationRequired(
              'Schema name ${entity.tableName} is occupied; supply an explicit migration'));
          continue;
        }
        operations.add(MigrationOperation._(
            MigrationKind.createTable,
            'Create table ${entity.tableName}',
            _createTableSql(entity, model),
            MigrationSafety.safe));
        for (final index in entity.indexes) {
          if (_indexNameOccupied(live, index.name)) {
            operations.add(_migrationRequired(
                'Index name ${index.name} is already occupied'));
          } else {
            operations.add(MigrationOperation._(
                MigrationKind.createIndex,
                'Create index ${index.name}',
                _createIndexSql(entity, index),
                MigrationSafety.safe));
          }
        }
        continue;
      }
      operations.addAll(
          _tableDifferences(entity, actual, model, allowSafeAdditions: true));
      for (final index in entity.indexes) {
        final current = actual.indexes
            .where((candidate) =>
                _ormAsciiLower(candidate.name) == _ormAsciiLower(index.name))
            .firstOrNull;
        if (current == null) {
          if (_indexNameOccupied(live, index.name)) {
            operations.add(_migrationRequired(
                'Index name ${index.name} belongs to another schema object'));
          } else {
            operations.add(MigrationOperation._(
                MigrationKind.createIndex,
                'Create ${index.unique ? 'unique ' : ''}index ${index.name}',
                _createIndexSql(entity, index),
                index.unique
                    ? MigrationSafety.reviewRequired
                    : MigrationSafety.safe));
          }
        } else if (!_indexMatches(current, index)) {
          operations.add(MigrationOperation._(
              MigrationKind.dropIndex,
              'Replace changed index ${index.name}',
              'DROP INDEX ${quoteIdentifier(current.name)}',
              MigrationSafety.reviewRequired));
          operations.add(MigrationOperation._(
              MigrationKind.createIndex,
              'Create replacement index ${index.name}',
              _createIndexSql(entity, index),
              MigrationSafety.reviewRequired));
        }
      }
    }
    final previous = live.catalog?.managed ?? const <String, dynamic>{};
    for (final entry in previous.entries) {
      if (!targets.containsKey(entry.key) &&
          live.tables.containsKey(entry.key)) {
        operations.add(_migrationRequired(
            'Previously managed table ${entry.value['name']} is no longer mapped; explicitly retain, rename or drop it'));
      }
      final entity = targets[entry.key];
      if (entity == null) continue;
      final desiredIndexes =
          entity.indexes.map((index) => _ormAsciiLower(index.name)).toSet();
      for (final index in entry.value['indexes'] as List) {
        final oldName = index['name'] as String;
        if (!desiredIndexes.contains(_ormAsciiLower(oldName)) &&
            live.objects.any((object) =>
                object.type == 'index' &&
                _ormAsciiLower(object.name) == _ormAsciiLower(oldName))) {
          operations.add(MigrationOperation._(
              MigrationKind.dropIndex,
              'Drop previously managed index $oldName',
              'DROP INDEX ${quoteIdentifier(oldName)}',
              MigrationSafety.reviewRequired));
        }
      }
    }
    final version = (live.catalog?.version ?? BigInt.zero) + BigInt.one;
    if (operations.isNotEmpty || live.catalog?.target != target) {
      operations.add(_recordModelOperation(version));
    }
    return SchemaPlan._(live.canonical, target, operations, version,
        catalogAbsent: live.catalog == null);
  }

  Future<void> _apply(SchemaPlan proposed,
      {bool safeOnly = false, MigrationApproval? approval}) async {
    _checkUsable();
    if (proposed.targetSchema != _modelSchema(model)) {
      throw const SchemaChangedException(
          'The plan belongs to a different model');
    }
    if (safeOnly && proposed.requiresApproval ||
        proposed.requiresApproval &&
            (approval == null || !identical(approval._plan, proposed))) {
      throw const MigrationApprovalRequiredException(
          'This exact migration plan requires explicit review and approval');
    }
    if (approval != null && !identical(approval._plan, proposed)) {
      throw const MigrationApprovalRequiredException(
          'Approval belongs to another migration plan');
    }
    if (!proposed.canApply) {
      throw const MigrationRequiredException(
          'Replace unresolved changes with explicit reviewed SQL or retain operations');
    }
    if (proposed.isEmpty) {
      if ((await _inspect()).canonical != proposed.baselineSchema) {
        throw const SchemaChangedException('The schema changed after planning');
      }
      return;
    }
    await connection.execute('PRAGMA foreign_keys=ON');
    final foreignKeys = await connection.query('PRAGMA foreign_keys');
    if (foreignKeys.rows.single.single != BigInt.one) {
      throw const OrmStateException(
          'Foreign key enforcement could not be enabled');
    }
    var committing = false;
    try {
      await connection.execute('BEGIN');
      if ((await _inspect()).canonical != proposed.baselineSchema) {
        throw const SchemaChangedException('The schema changed after planning');
      }
      for (final operation in proposed.operations) {
        if (operation.sql != null) {
          await connection.execute(operation.sql!, operation.parameters);
        }
      }
      final changed = await _inspect();
      final discrepancies = <MigrationOperation>[];
      for (final entity in model.entities) {
        final table = changed.tables[_ormAsciiLower(entity.tableName)];
        if (table == null) {
          discrepancies
              .add(_migrationRequired('Missing table ${entity.tableName}'));
          continue;
        }
        discrepancies.addAll(_tableDifferences(entity, table, model));
        for (final index in entity.indexes) {
          final live = table.indexes
              .where((candidate) =>
                  _ormAsciiLower(candidate.name) == _ormAsciiLower(index.name))
              .firstOrNull;
          if (live == null || !_indexMatches(live, index)) {
            discrepancies.add(
                _migrationRequired('Missing or changed index ${index.name}'));
          }
        }
      }
      if (discrepancies.isNotEmpty) {
        throw MigrationRequiredException(
            'Migration does not match the target model: ${discrepancies.first.description}');
      }
      final mappedNames = model.entities
          .map((entity) => _ormAsciiLower(entity.tableName))
          .toSet();
      for (final name in changed.catalog?.managed.keys ?? const <String>[]) {
        if (!mappedNames.contains(name) &&
            changed.tables.containsKey(name) &&
            !proposed.operations.any((operation) =>
                operation.kind == MigrationKind.retainTable &&
                operation._retainedTable == name)) {
          throw MigrationRequiredException(
              'Previously managed table $name needs an explicit retain operation');
        }
      }
      if ((await connection.query('PRAGMA foreign_key_check'))
          .rows
          .isNotEmpty) {
        throw const MigrationRequiredException(
            'Migration leaves foreign key violations');
      }
      await _recordModel(proposed, changed.catalog);
      committing = true;
      await connection.execute('COMMIT');
    } catch (error) {
      Object? cleanup;
      try {
        if (connection.inTransaction) await connection.execute('ROLLBACK');
      } catch (failure) {
        cleanup = failure;
      }
      if (committing || cleanup != null) _failed = true;
      if (cleanup != null) {
        throw OrmStateException(
            'Migration failed and rollback failed; reopen the connection',
            (original: error, rollback: cleanup));
      }
      rethrow;
    }
  }

  Future<void> _recordModel(
      SchemaPlan proposed, _MigrationCatalog? existing) async {
    if (existing == null) {
      if (!proposed._catalogAbsent) {
        throw const SchemaChangedException(
            'ORM metadata was removed by migration SQL');
      }
      await connection.execute(_migrationCatalogSql);
      await connection.execute(
          'INSERT INTO ${quoteIdentifier(_migrationCatalogName)} '
          '(id,format,schema,version) VALUES(1,?,?,?)',
          [
            _migrationCatalogFormat,
            proposed.targetSchema,
            proposed._nextVersion
          ]);
    } else {
      await connection.execute(
          'UPDATE ${quoteIdentifier(_migrationCatalogName)} '
          'SET schema=?,version=? WHERE id=1',
          [proposed.targetSchema, proposed._nextVersion]);
    }
  }

  Future<_MigrationSnapshot> _inspect() async {
    final result = await connection.query(
        'SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name');
    final objects = [
      for (final row in result.rows)
        _MigrationObject(row[0] as String, row[1] as String, row[2] as String,
            row[3] as String?)
    ];
    _MigrationCatalog? catalog;
    final reserved = objects
        .where((object) => _ormAsciiLower(object.name) == _migrationCatalogName)
        .toList();
    if (reserved.isNotEmpty) {
      if (reserved.length != 1 ||
          reserved.single.type != 'table' ||
          _migrationCanonicalSql(reserved.single.sql ?? '') !=
              _migrationCanonicalSql(_migrationCatalogSql)) {
        throw const MigrationRequiredException(
            'ORM metadata table name collision');
      }
      final rows = (await connection.query(
              'SELECT id,format,schema,version FROM ${quoteIdentifier(_migrationCatalogName)}'))
          .rows;
      if (rows.length != 1 ||
          rows.single[0] != BigInt.one ||
          rows.single[1] != _migrationCatalogFormat ||
          rows.single[2] is! String ||
          rows.single[3] is! BigInt ||
          (rows.single[3] as BigInt) < BigInt.one) {
        throw const MigrationRequiredException(
            'Invalid ORM metadata ownership record');
      }
      try {
        final target = rows.single[2] as String;
        final decoded = jsonDecode(target) as Map<String, dynamic>;
        final managed = <String, dynamic>{};
        for (final table in decoded['tables'] as List) {
          final name = table['name'] as String;
          if (table['columns'] is! List ||
              table['indexes'] is! List ||
              managed.containsKey(_ormAsciiLower(name))) {
            throw const FormatException('Invalid model record');
          }
          for (final index in table['indexes'] as List) {
            if (index['name'] is! String) throw const FormatException();
          }
          managed[_ormAsciiLower(name)] = table;
        }
        catalog = _MigrationCatalog(target, rows.single[3] as BigInt, managed);
      } catch (error) {
        throw MigrationRequiredException('Invalid stored ORM model', error);
      }
    }
    final wanted = {
      ...model.entities.map((entity) => _ormAsciiLower(entity.tableName)),
      ...?catalog?.managed.keys
    };
    final tables = <String, _MigrationTable>{};
    for (final object in objects.where((object) =>
        object.type == 'table' &&
        wanted.contains(_ormAsciiLower(object.name)))) {
      final columns = (await connection
              .query('PRAGMA table_xinfo(${_migrationString(object.name)})'))
          .rows;
      final indexes = <_MigrationIndex>[];
      for (final row in (await connection
              .query('PRAGMA index_list(${_migrationString(object.name)})'))
          .rows) {
        final name = row[1] as String;
        final terms = (await connection
                .query('PRAGMA index_xinfo(${_migrationString(name)})'))
            .rows
            .where((term) => term[5] == BigInt.one)
            .toList();
        indexes.add(_MigrationIndex(
            name,
            row[2] == BigInt.one,
            row[3] as String,
            row[4] == BigInt.one,
            [for (final term in terms) term[2] as String?],
            [for (final term in terms) term[3] == BigInt.one],
            [for (final term in terms) _ormAsciiLower(term[4] as String)]));
      }
      final foreign = (await connection.query(
              'PRAGMA foreign_key_list(${_migrationString(object.name)})'))
          .rows;
      tables[_ormAsciiLower(object.name)] = _MigrationTable(
          object.name, object.sql ?? '', columns, indexes, foreign);
    }
    final canonical = jsonEncode({
      'objects': [
        for (final object in objects)
          [object.type, object.name, object.tableName, object.sql]
      ],
      'model': catalog?.target,
      'version': catalog?.version.toString(),
    });
    return _MigrationSnapshot(objects, tables, catalog, canonical);
  }
}

const _migrationCatalogName = '_sqlite_plus_orm_model';
const _migrationCatalogFormat = 'sqlite_plus_orm:1';
const _migrationCatalogSql = 'CREATE TABLE "_sqlite_plus_orm_model" '
    '("id" INTEGER PRIMARY KEY CHECK("id"=1), "format" TEXT NOT NULL, '
    '"schema" TEXT NOT NULL, "version" INTEGER NOT NULL)';

MigrationOperation _recordModelOperation(BigInt version) =>
    MigrationOperation._(
        MigrationKind.recordModel,
        'Record verified ORM model version $version',
        null,
        MigrationSafety.safe);
MigrationOperation _migrationRequired(String reason) => MigrationOperation._(
    MigrationKind.requiresMigration,
    reason,
    null,
    MigrationSafety.reviewRequired);

String _migrationString(String value) => "'${value.replaceAll("'", "''")}'";
String _foreignAction(ForeignKeyAction action) => switch (action) {
      ForeignKeyAction.noAction => 'NO ACTION',
      ForeignKeyAction.restrict => 'RESTRICT',
      ForeignKeyAction.cascade => 'CASCADE',
      ForeignKeyAction.setNull => 'SET NULL',
      ForeignKeyAction.setDefault => 'SET DEFAULT',
    };

String _columnSql(Column<dynamic, dynamic> column, {required bool inlineKey}) =>
    [
      quoteIdentifier(column.sqlName),
      column.codec.sqlType,
      if (!_migrationColumnNullable(column)) 'NOT NULL',
      if (inlineKey) 'PRIMARY KEY',
      if (column.defaultSql != null) 'DEFAULT (${column.defaultSql})',
      if (column.unique) 'UNIQUE',
    ].join(' ');

bool _migrationColumnNullable(Column<dynamic, dynamic> column) =>
    column.nullable && (column.keyOrder == null || column.generated);

String _createTableSql(EntityType<dynamic> entity, DbModel model) {
  if (entity.virtualModule == 'fts5') {
    final columns =
        entity.columns.where((column) => column.keyOrder == null).toList();
    return 'CREATE VIRTUAL TABLE ${quoteIdentifier(entity.tableName)} '
        'USING fts5(${columns.map((column) => quoteIdentifier(column.sqlName)).join(', ')})';
  }
  if (entity.virtualModule == 'rtree') {
    return 'CREATE VIRTUAL TABLE ${quoteIdentifier(entity.tableName)} '
        'USING rtree(${entity.columns.map((column) => quoteIdentifier(column.sqlName)).join(', ')})';
  }
  final inlineKey = entity.keys.length == 1;
  final definitions = [
    for (final column in entity.columns)
      _columnSql(column,
          inlineKey: inlineKey && identical(column, entity.keys.single)),
    if (!inlineKey)
      'PRIMARY KEY (${entity.keys.map((column) => quoteIdentifier(column.sqlName)).join(',')})',
    for (final key
        in model.foreignKeys.where((key) => identical(key.child, entity)))
      'CONSTRAINT ${quoteIdentifier(key.name)} FOREIGN KEY '
          '(${key.columns.map((column) => quoteIdentifier(column.sqlName)).join(',')}) '
          'REFERENCES ${quoteIdentifier(key.parent.tableName)} '
          '(${key.targetColumns.map((column) => quoteIdentifier(column.sqlName)).join(',')}) '
          'ON UPDATE ${_foreignAction(key.onUpdate)} ON DELETE ${_foreignAction(key.onDelete)}'
          '${key.deferred ? ' DEFERRABLE INITIALLY DEFERRED' : ''}'
  ];
  return 'CREATE TABLE ${quoteIdentifier(entity.tableName)} (${definitions.join(', ')})';
}

String _createIndexSql(EntityType<dynamic> entity, OrmIndex<dynamic> index) =>
    'CREATE ${index.unique ? 'UNIQUE ' : ''}INDEX ${quoteIdentifier(index.name)} '
    'ON ${quoteIdentifier(entity.tableName)} '
    '(${index.columns.map((column) => quoteIdentifier(column.sqlName)).join(',')})';

bool _indexNameOccupied(_MigrationSnapshot schema, String name) =>
    schema.objects.any((object) =>
        ['table', 'index', 'view'].contains(object.type) &&
        _ormAsciiLower(object.name) == _ormAsciiLower(name));

bool _indexMatches(_MigrationIndex actual, OrmIndex<dynamic> desired) =>
    actual.unique == desired.unique &&
    !actual.partial &&
    actual.columns.length == desired.columns.length &&
    Iterable<int>.generate(actual.columns.length).every((index) =>
        _ormAsciiLower(actual.columns[index] ?? '') ==
            _ormAsciiLower(desired.columns[index].sqlName) &&
        !actual.descending[index] &&
        actual.collations[index] == 'binary');

List<MigrationOperation> _tableDifferences(
    EntityType<dynamic> entity, _MigrationTable actual, DbModel model,
    {bool allowSafeAdditions = false}) {
  final problems = <MigrationOperation>[];
  if (entity.virtualModule != null) {
    if (_migrationCanonicalSql(actual.sql) !=
        _migrationCanonicalSql(_createTableSql(entity, model))) {
      problems.add(_migrationRequired(
          'Virtual table ${entity.tableName} does not match ${entity.virtualModule}'));
    }
    return problems;
  }
  final columns = {
    for (final row in actual.columns) _ormAsciiLower(row[1] as String): row
  };
  final desiredNames =
      entity.columns.map((column) => _ormAsciiLower(column.sqlName)).toSet();
  for (final column in entity.columns) {
    final row = columns[_ormAsciiLower(column.sqlName)];
    if (row == null) {
      final safe = column.nullable &&
          column.keyOrder == null &&
          !column.unique &&
          !column.generated &&
          !column.version &&
          column.defaultSql == null &&
          !model.foreignKeys.any((key) =>
              identical(key.child, entity) && key.columns.contains(column));
      if (allowSafeAdditions && safe) {
        problems.add(MigrationOperation._(
            MigrationKind.addColumn,
            'Add nullable column ${entity.tableName}.${column.sqlName}',
            'ALTER TABLE ${quoteIdentifier(entity.tableName)} ADD COLUMN '
                '${_columnSql(column, inlineKey: false)}',
            MigrationSafety.safe));
      } else {
        problems.add(
            _migrationRequired('Column ${entity.tableName}.${column.sqlName} '
                'requires explicit backfill or table rebuild'));
      }
      continue;
    }
    final key = entity.keys.indexOf(column) + 1;
    final expectedKey = column.keyOrder == null ? 0 : key;
    if ((row[2] as String).trim().toUpperCase() != column.codec.sqlType ||
        row[3] !=
            (_migrationColumnNullable(column) ? BigInt.zero : BigInt.one) ||
        _migrationDefault(row[4] as String?) !=
            _migrationDefault(column.defaultSql) ||
        row[5] != BigInt.from(expectedKey) ||
        row[6] != BigInt.zero) {
      problems
          .add(_migrationRequired('Changed type, nullability, default, key or '
              'generated shape for ${entity.tableName}.${column.sqlName}'));
    }
    final unique = actual.indexes.any((index) =>
            index.unique &&
            !index.partial &&
            index.columns.length == 1 &&
            _ormAsciiLower(index.columns.single ?? '') ==
                _ormAsciiLower(column.sqlName) &&
            index.collations.single == 'binary') ||
        expectedKey > 0 && entity.keys.length == 1;
    if (column.unique && !unique) {
      problems.add(_migrationRequired('Missing unique constraint for '
          '${entity.tableName}.${column.sqlName}'));
    }
  }
  if (columns.keys.any((name) => !desiredNames.contains(name))) {
    problems.add(
        _migrationRequired('Table ${entity.tableName} has unmapped columns; '
            'removal or rename needs an explicit mapping'));
  }
  for (final index in actual.indexes.where((index) => index.origin == 'u')) {
    if (index.columns.length != 1 ||
        !entity.columns.any((column) =>
            column.unique &&
            _ormAsciiLower(column.sqlName) ==
                _ormAsciiLower(index.columns.single ?? ''))) {
      problems.add(_migrationRequired(
          'Table ${entity.tableName} has an unmapped unique constraint'));
    }
  }
  if (_unsupportedMigrationTableSql(actual.sql)) {
    problems.add(
        _migrationRequired('Table ${entity.tableName} has constraints/options '
            'outside the mapped schema; supply an explicit rebuild'));
  }
  final wantedForeign = model.foreignKeys
      .where((key) => identical(key.child, entity))
      .map(_desiredForeignSignature)
      .toList()
    ..sort();
  final liveForeign = _liveForeignSignatures(actual, model)..sort();
  if (!_migrationStringListsEqual(wantedForeign, liveForeign)) {
    problems
        .add(_migrationRequired('Foreign keys changed for ${entity.tableName}; '
            'supply an explicit rebuild'));
  }
  return problems;
}

String _modelSchema(DbModel model) => jsonEncode({
      'tables': [
        for (final entity in [...model.entities]..sort((left, right) =>
            _ormAsciiLower(left.tableName)
                .compareTo(_ormAsciiLower(right.tableName))))
          {
            'name': entity.tableName,
            if (entity.virtualModule != null) 'module': entity.virtualModule,
            'columns': [
              for (final column in entity.columns)
                {
                  'name': column.sqlName,
                  'type': column.codec.sqlType,
                  'nullable': column.nullable,
                  'key': entity.keys.indexOf(column) + 1,
                  'generated': column.generated,
                  'default': _migrationDefault(column.defaultSql),
                  'unique': column.unique,
                }
            ],
            'indexes': [
              for (final index in [...entity.indexes]..sort((left, right) =>
                  _ormAsciiLower(left.name)
                      .compareTo(_ormAsciiLower(right.name))))
                {
                  'name': index.name,
                  'unique': index.unique,
                  'columns':
                      index.columns.map((column) => column.sqlName).toList(),
                }
            ],
            'foreignKeys': (model.foreignKeys
                .where((key) => identical(key.child, entity))
                .map(_desiredForeignSignature)
                .toList()
              ..sort()),
          }
      ]
    });

String _desiredForeignSignature(ForeignKey<dynamic, dynamic> key) =>
    jsonEncode([
      _ormAsciiLower(key.parent.tableName),
      key.columns.map((column) => _ormAsciiLower(column.sqlName)).toList(),
      key.targetColumns
          .map((column) => _ormAsciiLower(column.sqlName))
          .toList(),
      _foreignAction(key.onUpdate),
      _foreignAction(key.onDelete),
      key.deferred,
    ]);

List<String> _liveForeignSignatures(_MigrationTable table, DbModel model) {
  final groups = <BigInt, List<List<Object?>>>{};
  for (final row in table.foreignKeys) {
    (groups[row[0] as BigInt] ??= []).add(row);
  }
  final declarations = _migrationForeignDeclarations(table.sql);
  return [
    for (final rows in groups.values)
      (() {
        rows.sort(
            (left, right) => (left[1] as BigInt).compareTo(right[1] as BigInt));
        final parent = _ormAsciiLower(rows.first[2] as String);
        final source =
            rows.map((row) => _ormAsciiLower(row[3] as String)).toList();
        final target = <String>[];
        final parentEntity = model.entities
            .where((entity) => _ormAsciiLower(entity.tableName) == parent)
            .firstOrNull;
        for (var index = 0; index < rows.length; index++) {
          final value = rows[index][4] as String?;
          target.add(value == null &&
                  parentEntity != null &&
                  index < parentEntity.keys.length
              ? _ormAsciiLower(parentEntity.keys[index].sqlName)
              : _ormAsciiLower(value ?? ''));
        }
        final matching = declarations
            .where((declaration) =>
                declaration.parent == parent &&
                _migrationStringListsEqual(declaration.columns, source) &&
                (declaration.target.isEmpty ||
                    _migrationStringListsEqual(declaration.target, target)))
            .lastOrNull;
        if (matching != null) declarations.remove(matching);
        return jsonEncode([
          parent,
          source,
          target,
          rows.first[5],
          rows.first[6],
          matching?.deferred ?? false
        ]);
      })()
  ];
}

bool _migrationStringListsEqual(List<String> left, List<String> right) =>
    left.length == right.length &&
    Iterable<int>.generate(left.length)
        .every((index) => left[index] == right[index]);

String? _migrationDefault(String? value) {
  if (value == null) return null;
  var tokens = _migrationSqlTokens(value);
  while (tokens.length >= 2 &&
      tokens.first.value == '(' &&
      tokens.last.value == ')') {
    var depth = 0;
    var encloses = true;
    for (var index = 0; index < tokens.length; index++) {
      if (!tokens[index].quoted && tokens[index].value == '(') depth++;
      if (!tokens[index].quoted && tokens[index].value == ')') depth--;
      if (depth == 0 && index != tokens.length - 1) {
        encloses = false;
        break;
      }
    }
    if (!encloses) break;
    tokens = tokens.sublist(1, tokens.length - 1);
  }
  return jsonEncode([
    for (final token in tokens)
      [token.quoted, token.quoted ? token.value : _ormAsciiLower(token.value)]
  ]);
}

String _migrationCanonicalSql(String value) => jsonEncode([
      for (final token in _migrationSqlTokens(value))
        [token.quoted, token.quoted ? token.value : _ormAsciiLower(token.value)]
    ]);

final class _MigrationToken {
  const _MigrationToken(this.value, [this.quoted = false]);
  final String value;
  final bool quoted;
  bool isWord(String word) => !quoted && value.toUpperCase() == word;
}

List<_MigrationToken> _migrationSqlTokens(String sql) {
  final tokens = <_MigrationToken>[];
  var index = 0;
  while (index < sql.length) {
    final char = sql[index];
    if (' \t\r\n\f\v'.contains(char)) {
      index++;
      continue;
    }
    if (sql.startsWith('--', index)) {
      final end = sql.indexOf('\n', index + 2);
      index = end < 0 ? sql.length : end + 1;
      continue;
    }
    if (sql.startsWith('/*', index)) {
      final end = sql.indexOf('*/', index + 2);
      if (end < 0) {
        throw const OrmMappingException('Unterminated migration SQL comment');
      }
      index = end + 2;
      continue;
    }
    if (['\'', '"', '`', '['].contains(char)) {
      final close = char == '[' ? ']' : char;
      final text = StringBuffer();
      index++;
      var closed = false;
      while (index < sql.length) {
        final current = sql[index++];
        if (current == close) {
          if (index < sql.length && sql[index] == close && close != ']') {
            text.write(close);
            index++;
            continue;
          }
          closed = true;
          break;
        }
        text.write(current);
      }
      if (!closed) {
        throw const OrmMappingException('Unterminated migration SQL quote');
      }
      // Keep string literals distinct from identifier quotes in defaults.
      tokens.add(_MigrationToken(
          '${char == "'" ? "'" : '"'}${text.toString()}', true));
      continue;
    }
    if ('(),.;=+-*/%<>!|&~'.contains(char)) {
      tokens.add(_MigrationToken(char));
      index++;
      continue;
    }
    final start = index++;
    while (index < sql.length &&
        !' \t\r\n\f\v\'"`[(),.;=+-*/%<>!|&~'.contains(sql[index])) {
      index++;
    }
    tokens.add(_MigrationToken(sql.substring(start, index)));
  }
  return tokens;
}

List<List<_MigrationToken>> _migrationDefinitions(String sql) {
  final tokens = _migrationSqlTokens(sql);
  final start =
      tokens.indexWhere((token) => !token.quoted && token.value == '(');
  if (start < 0) return [];
  final result = <List<_MigrationToken>>[];
  var current = <_MigrationToken>[];
  var depth = 1;
  for (final token in tokens.skip(start + 1)) {
    if (!token.quoted && token.value == '(') depth++;
    if (!token.quoted && token.value == ')') depth--;
    if (depth == 0) {
      if (current.isNotEmpty) result.add(current);
      break;
    }
    if (depth == 1 && !token.quoted && token.value == ',') {
      result.add(current);
      current = [];
      continue;
    }
    current.add(token);
  }
  return result;
}

String _migrationTokenName(_MigrationToken token) =>
    _ormAsciiLower(token.quoted ? token.value.substring(1) : token.value);

bool _unsupportedMigrationTableSql(String sql) {
  final tokens = _migrationSqlTokens(sql);
  var depth = 0;
  for (final token in tokens) {
    if (!token.quoted && token.value == '(') depth++;
    if (!token.quoted && token.value == ')') depth--;
    if (depth == 0 && (token.isWord('STRICT') || token.isWord('WITHOUT'))) {
      return true;
    }
  }
  for (final definition in _migrationDefinitions(sql)) {
    var level = 0;
    for (final token in definition) {
      if (!token.quoted && token.value == '(') level++;
      if (!token.quoted && token.value == ')') level--;
      if (level == 0 &&
          [
            'CHECK',
            'COLLATE',
            'GENERATED',
            'AUTOINCREMENT',
            'CONFLICT',
            'ASC',
            'DESC'
          ].any(token.isWord)) {
        return true;
      }
    }
    final first = definition.firstOrNull;
    if (first != null &&
        (first.isWord('PRIMARY') ||
            first.isWord('UNIQUE') ||
            first.isWord('CONSTRAINT')) &&
        definition
            .any((token) => ['COLLATE', 'ASC', 'DESC'].any(token.isWord))) {
      return true;
    }
  }
  return false;
}

final class _MigrationForeignDeclaration {
  _MigrationForeignDeclaration(
      this.parent, this.columns, this.target, this.deferred);
  final String parent;
  final List<String> columns, target;
  final bool deferred;
}

List<_MigrationForeignDeclaration> _migrationForeignDeclarations(String sql) {
  final result = <_MigrationForeignDeclaration>[];
  for (final definition in _migrationDefinitions(sql)) {
    final references =
        definition.indexWhere((token) => token.isWord('REFERENCES'));
    if (references < 0 || references + 1 >= definition.length) continue;
    final foreign = definition.indexWhere((token) => token.isWord('FOREIGN'));
    List<String> names(int start) {
      if (start >= definition.length || definition[start].value != '(') {
        return [];
      }
      final found = <String>[];
      for (final token in definition.skip(start + 1)) {
        if (!token.quoted && token.value == ')') break;
        if (token.quoted || token.value != ',') {
          found.add(_migrationTokenName(token));
        }
      }
      return found;
    }

    final columns = foreign < 0
        ? [_migrationTokenName(definition.first)]
        : names(foreign + 2);
    final target = names(references + 2);
    var deferred = false;
    for (var index = references + 2; index + 1 < definition.length; index++) {
      if (definition[index].isWord('INITIALLY') &&
          definition[index + 1].isWord('DEFERRED')) {
        deferred = true;
      }
      if (definition[index].isWord('NOT') &&
          definition[index + 1].isWord('DEFERRABLE')) {
        deferred = false;
        break;
      }
    }
    result.add(_MigrationForeignDeclaration(
        _migrationTokenName(definition[references + 1]),
        columns,
        target,
        deferred));
  }
  return result;
}

final class _MigrationObject {
  _MigrationObject(this.type, this.name, this.tableName, this.sql);
  final String type, name, tableName;
  final String? sql;
}

final class _MigrationIndex {
  _MigrationIndex(this.name, this.unique, this.origin, this.partial,
      this.columns, this.descending, this.collations);
  final String name, origin;
  final bool unique, partial;
  final List<String?> columns;
  final List<bool> descending;
  final List<String> collations;
}

final class _MigrationTable {
  _MigrationTable(
      this.name, this.sql, this.columns, this.indexes, this.foreignKeys);
  final String name, sql;
  final List<List<Object?>> columns, foreignKeys;
  final List<_MigrationIndex> indexes;
}

final class _MigrationCatalog {
  _MigrationCatalog(this.target, this.version, this.managed);
  final String target;
  final BigInt version;
  final Map<String, dynamic> managed;
}

final class _MigrationSnapshot {
  _MigrationSnapshot(this.objects, this.tables, this.catalog, this.canonical);
  final List<_MigrationObject> objects;
  final Map<String, _MigrationTable> tables;
  final _MigrationCatalog? catalog;
  final String canonical;
}
