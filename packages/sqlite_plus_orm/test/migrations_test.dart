import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart' hide ForeignKey;
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

class _Record {
  _Record(this.values);
  final Map<String, dynamic> values;
}

class _Field {
  const _Field(this.name, this.codec,
      {this.key,
      this.generated = false,
      this.unique = false,
      this.defaultSql,
      this.version = false});
  final String name;
  final ValueCodec<dynamic> codec;
  final int? key;
  final bool generated, unique, version;
  final String? defaultSql;
}

class _Index {
  const _Index(this.name, this.columns, {this.unique = false});
  final String name;
  final List<String> columns;
  final bool unique;
}

class _Mapping {
  _Mapping(String name, List<_Field> fields,
      {List<_Index> indexes = const []}) {
    columns = {
      for (final field in fields)
        field.name: Column<_Record, dynamic>(
            property: field.name,
            codec: field.codec,
            keyOrder: field.key,
            generated: field.generated,
            unique: field.unique,
            version: field.version,
            defaultSql: field.defaultSql,
            read: (entity) => entity.values[field.name],
            write: (entity, value) => entity.values[field.name] = value)
    };
    type = EntityType<_Record>(
        tableName: name,
        columns: columns.values.toList(),
        indexes: [
          for (final index in indexes)
            OrmIndex<_Record>(
                name: index.name,
                columns: [for (final name in index.columns) columns[name]!],
                unique: index.unique)
        ],
        create: (row) => _Record(
            {for (final field in fields) field.name: row.raw(field.name)}));
  }
  late final Map<String, Column<_Record, dynamic>> columns;
  late final EntityType<_Record> type;
}

_Mapping _people(
        {bool extra = false,
        bool uniqueIndex = false,
        ValueCodec<dynamic>? nameCodec,
        String table = 'people',
        String nameColumn = 'name',
        List<_Index>? indexes}) =>
    _Mapping(
        table,
        [
          _Field('id', Codecs.nullable(Codecs.bigInt), key: 0, generated: true),
          _Field(nameColumn, nameCodec ?? Codecs.nullable(Codecs.text)),
          if (extra) _Field('note', Codecs.nullable(Codecs.text)),
        ],
        indexes: indexes ??
            [
              if (uniqueIndex)
                const _Index('person_name', ['name'], unique: true)
            ]);

Future<BigInt> _version(OrmConnection connection) async =>
    (await connection.query('SELECT version FROM _sqlite_plus_orm_model'))
        .rows
        .single
        .single as BigInt;

void main() {
  late MutableSqliteDatabase engine;
  late MutableDatabaseConnection connection;
  setUp(() async {
    engine = await MutableSqliteDatabase.create();
    connection = MutableDatabaseConnection(engine);
  });
  tearDown(() async {
    if (engine.inTransaction) await engine.execute('ROLLBACK');
    await engine.close();
  });

  test('empty schema creation is reviewable, quoted and idempotent', () async {
    final people =
        _people(table: 'select "Δ', nameColumn: 'value "λ', indexes: [
      const _Index('index "Δ', ['value "λ'])
    ]);
    final migrations = SchemaMigrator(connection, DbModel([people.type]));
    final plan = await migrations.plan();
    expect(plan.isEmpty, isFalse);
    expect(plan.requiresApproval, isFalse);
    expect(plan.canApply, isTrue);
    expect(plan.operations.map((operation) => operation.kind), [
      MigrationKind.createTable,
      MigrationKind.createIndex,
      MigrationKind.recordModel
    ]);
    expect(plan.operations.first.sql, contains('"select ""Δ"'));
    expect(() => plan.operations.clear(), throwsUnsupportedError);
    await migrations.applySafe(plan);
    await engine
        .execute('INSERT INTO "select ""Δ"("value ""λ") VALUES(?)', ['Ada']);
    expect(
        (await engine.query('SELECT "id","value ""λ" FROM "select ""Δ"')).rows,
        [
          [BigInt.one, 'Ada']
        ]);
    expect(await _version(connection), BigInt.one);
    expect((await migrations.plan()).isEmpty, isTrue);
    await migrations.ensureCreated();
    expect(await _version(connection), BigInt.one);
    expect((await engine.query('PRAGMA integrity_check')).rows, [
      ['ok']
    ]);
  });

  test('matching legacy table can be adopted without rewriting its rows',
      () async {
    await engine
        .execute('CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT)');
    await engine.execute("INSERT INTO people VALUES(5,'Ada')");
    final migrations = SchemaMigrator(connection, DbModel([_people().type]));
    final plan = await migrations.plan();
    expect(plan.operations.map((operation) => operation.kind),
        [MigrationKind.recordModel]);
    await migrations.applySafe(plan);
    expect((await engine.query('SELECT * FROM people')).rows, [
      [BigInt.from(5), 'Ada']
    ]);
  });

  test('safe column and index additions retain unmanaged objects and data',
      () async {
    final original = _people();
    await SchemaMigrator(connection, DbModel([original.type])).ensureCreated();
    await engine.execute("INSERT INTO people(name) VALUES('Ada')");
    await engine.execute('CREATE TABLE audit(v)');
    await engine
        .execute('CREATE VIEW people_view AS SELECT id,name FROM people');
    await engine.execute(
        'CREATE TRIGGER logged AFTER INSERT ON people BEGIN INSERT INTO audit VALUES(NEW.id); END');
    await engine.execute('CREATE INDEX unmanaged_name ON people(name)');
    final updated = _people(extra: true, indexes: [
      const _Index('people_note', ['note'])
    ]);
    final migrations = SchemaMigrator(connection, DbModel([updated.type]));
    final plan = await migrations.plan();
    expect(plan.requiresApproval, isFalse);
    expect(plan.operations.map((operation) => operation.kind), [
      MigrationKind.addColumn,
      MigrationKind.createIndex,
      MigrationKind.recordModel
    ]);
    await migrations.applySafe(plan);
    expect((await engine.query('SELECT id,name,note FROM people')).rows, [
      [BigInt.one, 'Ada', null]
    ]);
    await engine
        .execute("INSERT INTO people(name,note) VALUES('Grace','notes')");
    expect((await engine.query('SELECT * FROM audit')).rows, [
      [BigInt.two]
    ]);
    expect((await engine.query('SELECT * FROM people_view ORDER BY id')).rows, [
      [BigInt.one, 'Ada'],
      [BigInt.two, 'Grace']
    ]);
    expect(
        (await engine.query(
                "SELECT name FROM sqlite_schema WHERE name='unmanaged_name'"))
            .rows,
        [
          ['unmanaged_name']
        ]);
    expect(await _version(connection), BigInt.two);
    expect((await migrations.plan()).isEmpty, isTrue);
  });

  test(
      'adding a unique index needs exact approval and rolls back duplicate failure',
      () async {
    await SchemaMigrator(connection, DbModel([_people().type])).ensureCreated();
    await engine.execute("INSERT INTO people(name) VALUES('Ada'),('Ada')");
    final migrations =
        SchemaMigrator(connection, DbModel([_people(uniqueIndex: true).type]));
    final plan = await migrations.plan();
    final before = engine.exportImage();
    expect(plan.requiresApproval, isTrue);
    expect(plan.canApply, isTrue);
    await expectLater(migrations.applySafe(plan),
        throwsA(isA<MigrationApprovalRequiredException>()));
    expect(engine.exportImage(), before);
    await expectLater(
        migrations.apply(plan, approval: MigrationApproval.forPlan(plan)),
        throwsA(isA<SqlException>()));
    expect(engine.exportImage(), before);
    expect(await _version(connection), BigInt.one);
    await engine.execute("UPDATE people SET name='Grace' WHERE id=2");
    await migrations.apply(plan, approval: MigrationApproval.forPlan(plan));
    expect(await _version(connection), BigInt.two);
    expect((await migrations.plan()).isEmpty, isTrue);
  });

  test('type change requires a supplied rebuild mapping and bound approval',
      () async {
    await SchemaMigrator(connection, DbModel([_people().type])).ensureCreated();
    await engine.execute("INSERT INTO people(name) VALUES('42')");
    final desired = _people(nameCodec: Codecs.nullable(Codecs.integer));
    final migrations = SchemaMigrator(connection, DbModel([desired.type]));
    final plan = await migrations.plan();
    expect(plan.canApply, isFalse);
    await expectLater(
        migrations.apply(plan, approval: MigrationApproval.forPlan(plan)),
        throwsA(isA<MigrationRequiredException>()));
    final reviewed = plan.withOperations([
      MigrationOperation.sql(
          'CREATE TABLE people_new(id INTEGER PRIMARY KEY,name INTEGER)',
          reason: 'Build reviewed target'),
      MigrationOperation.sql(
          'INSERT INTO people_new(id,name) SELECT id,CAST(name AS INTEGER) FROM people',
          reason: 'Explicit source-to-target conversion'),
      MigrationOperation.sql('DROP TABLE people',
          reason: 'Replace old physical table after mapped copy'),
      MigrationOperation.sql('ALTER TABLE people_new RENAME TO people',
          reason: 'Publish rebuilt table'),
    ]);
    await expectLater(
        migrations.apply(reviewed, approval: MigrationApproval.forPlan(plan)),
        throwsA(isA<MigrationApprovalRequiredException>()));
    await expectLater(migrations.applySafe(reviewed),
        throwsA(isA<MigrationApprovalRequiredException>()));
    await migrations.apply(reviewed,
        approval: MigrationApproval.forPlan(reviewed));
    expect(
        (await engine.query('SELECT id,name,typeof(name) FROM people')).rows, [
      [BigInt.one, BigInt.from(42), 'integer']
    ]);
    expect((await migrations.plan()).isEmpty, isTrue);
  });

  test('renames are not guessed and explicit rename retains data', () async {
    await SchemaMigrator(connection, DbModel([_people().type])).ensureCreated();
    await engine.execute("INSERT INTO people(name) VALUES('Ada')");
    final migrations = SchemaMigrator(
        connection, DbModel([_people(nameColumn: 'display_name').type]));
    final plan = await migrations.plan();
    expect(plan.canApply, isFalse);
    final reviewed = plan.withOperations([
      MigrationOperation.sql(
          'ALTER TABLE people RENAME COLUMN name TO display_name',
          reason: 'Reviewed exact rename'),
    ]);
    await migrations.apply(reviewed,
        approval: MigrationApproval.forPlan(reviewed));
    expect((await engine.query('SELECT display_name FROM people')).rows, [
      ['Ada']
    ]);
  });

  test('removed managed table requires explicit retain or drop', () async {
    await SchemaMigrator(connection, DbModel([_people().type])).ensureCreated();
    await engine.execute("INSERT INTO people(name) VALUES('Ada')");
    final migrations = SchemaMigrator(connection, DbModel([]));
    final plan = await migrations.plan();
    expect(plan.canApply, isFalse);
    final emptyReplacement = plan.withOperations([]);
    expect(emptyReplacement.requiresApproval, isTrue);
    await expectLater(
        migrations.apply(emptyReplacement,
            approval: MigrationApproval.forPlan(emptyReplacement)),
        throwsA(isA<MigrationRequiredException>()));
    final retained =
        plan.withOperations([MigrationOperation.retainTable('people')]);
    await migrations.apply(retained,
        approval: MigrationApproval.forPlan(retained));
    expect((await engine.query('SELECT name FROM people')).rows, [
      ['Ada']
    ]);
    expect((await migrations.plan()).isEmpty, isTrue);
  });

  test('explicit reviewed drop removes only previously mapped table', () async {
    await SchemaMigrator(connection, DbModel([_people().type])).ensureCreated();
    await engine.execute('CREATE TABLE unmanaged(v)');
    final migrations = SchemaMigrator(connection, DbModel([]));
    final reviewed = (await migrations.plan()).withOperations([
      MigrationOperation.sql('DROP TABLE people',
          reason: 'Explicit approved data removal'),
    ]);
    await migrations.apply(reviewed,
        approval: MigrationApproval.forPlan(reviewed));
    expect(
        (await engine.query(
                "SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name"))
            .rows,
        [
          ['_sqlite_plus_orm_model'],
          ['unmanaged']
        ]);
  });

  test('unmanaged schema change makes even an empty plan stale', () async {
    final migrations = SchemaMigrator(connection, DbModel([_people().type]));
    await migrations.ensureCreated();
    final stale = await migrations.plan();
    expect(stale.isEmpty, isTrue);
    await engine.execute('CREATE VIEW elsewhere AS SELECT 1');
    await expectLater(
        migrations.applySafe(stale), throwsA(isA<SchemaChangedException>()));
    expect(await _version(connection), BigInt.one);
  });

  test('stale nonempty plan is rechecked inside transaction', () async {
    final migrations = SchemaMigrator(connection, DbModel([_people().type]));
    final plan = await migrations.plan();
    await engine.execute('CREATE TABLE other(v)');
    final before = engine.exportImage();
    await expectLater(
        migrations.applySafe(plan), throwsA(isA<SchemaChangedException>()));
    expect(engine.exportImage(), before);
    expect(engine.inTransaction, isFalse);
  });

  test('plan and approval cannot be applied to another target model', () async {
    final first = SchemaMigrator(connection, DbModel([_people().type]));
    final plan = await first.plan();
    final second =
        SchemaMigrator(connection, DbModel([_people(extra: true).type]));
    await expectLater(
        second.applySafe(plan), throwsA(isA<SchemaChangedException>()));
    expect(
        (await engine.query('SELECT name FROM sqlite_schema')).rows, isEmpty);
  });

  test(
      'failed reviewed data/DDL mapping rolls back data, schema and model version',
      () async {
    await SchemaMigrator(connection, DbModel([_people().type])).ensureCreated();
    await engine.execute("INSERT INTO people(name) VALUES('Ada')");
    final migrations =
        SchemaMigrator(connection, DbModel([_people(extra: true).type]));
    final plan = (await migrations.plan()).withOperations([
      MigrationOperation.sql('ALTER TABLE people ADD COLUMN note TEXT',
          reason: 'Reviewed nullable addition'),
      MigrationOperation.sql("UPDATE people SET name='changed'",
          reason: 'Reviewed data transformation'),
      MigrationOperation.sql('INSERT INTO absent VALUES(1)',
          reason: 'Deliberately invalid final operation'),
    ]);
    final before = engine.exportImage();
    await expectLater(
        migrations.apply(plan, approval: MigrationApproval.forPlan(plan)),
        throwsA(isA<SqlException>()));
    expect(engine.exportImage(), before);
    expect(await _version(connection), BigInt.one);
    expect((await engine.query('SELECT name FROM people')).rows, [
      ['Ada']
    ]);
  });

  test('manual steps must actually establish the requested target shape',
      () async {
    await SchemaMigrator(connection, DbModel([_people().type])).ensureCreated();
    final migrations =
        SchemaMigrator(connection, DbModel([_people(extra: true).type]));
    final plan = (await migrations.plan()).withOperations([
      MigrationOperation.sql('CREATE TABLE unrelated(v)',
          reason: 'Wrong target deliberately'),
    ]);
    final before = engine.exportImage();
    await expectLater(
        migrations.apply(plan, approval: MigrationApproval.forPlan(plan)),
        throwsA(isA<MigrationRequiredException>()));
    expect(engine.exportImage(), before);
  });

  test(
      'required/default/key/unique additions and unexplained constraints are guarded',
      () async {
    await SchemaMigrator(connection, DbModel([_people().type])).ensureCreated();
    for (final field in [
      _Field('extra', Codecs.text),
      _Field('extra', Codecs.nullable(Codecs.text), defaultSql: "'x'"),
      _Field('extra', Codecs.nullable(Codecs.text), unique: true),
      _Field('extra', Codecs.bigInt, version: true),
    ]) {
      final desired = _Mapping('people', [
        _Field('id', Codecs.nullable(Codecs.bigInt), key: 0, generated: true),
        _Field('name', Codecs.nullable(Codecs.text)),
        field
      ]);
      final plan =
          await SchemaMigrator(connection, DbModel([desired.type])).plan();
      expect(plan.canApply, isFalse);
      expect(plan.requiresApproval, isTrue);
    }
  });

  test(
      'existing CHECK/collation/STRICT/conflict policies do not get silently adopted',
      () async {
    for (final suffix in [
      'name TEXT CHECK(length(name)>0)',
      'name TEXT COLLATE NOCASE',
      'name TEXT UNIQUE ON CONFLICT IGNORE',
      'name TEXT) STRICT --',
    ]) {
      final db = await MutableSqliteDatabase.create();
      try {
        await db.execute('CREATE TABLE people(id INTEGER PRIMARY KEY,$suffix)');
        final plan = await SchemaMigrator(
            MutableDatabaseConnection(db), DbModel([_people().type])).plan();
        expect(plan.canApply, isFalse, reason: suffix);
      } finally {
        await db.close();
      }
    }
  });

  test(
      'protected metadata name collisions and corrupt ownership records reject',
      () async {
    await engine.execute('CREATE TABLE _sqlite_plus_orm_model(v)');
    await expectLater(
        SchemaMigrator(connection, DbModel([_people().type])).plan(),
        throwsA(isA<MigrationRequiredException>()));
    await engine.execute('DROP TABLE _sqlite_plus_orm_model');
    final migrations = SchemaMigrator(connection, DbModel([_people().type]));
    await migrations.ensureCreated();
    await engine.execute("UPDATE _sqlite_plus_orm_model SET format='unowned'");
    await expectLater(
        migrations.plan(), throwsA(isA<MigrationRequiredException>()));
  });

  test('malformed catalog model record rejects without adopting or deleting it',
      () async {
    final migrations = SchemaMigrator(connection, DbModel([_people().type]));
    await migrations.ensureCreated();
    await engine.execute("UPDATE _sqlite_plus_orm_model SET schema='{}'");
    final before = engine.exportImage();
    await expectLater(
        migrations.plan(), throwsA(isA<MigrationRequiredException>()));
    expect(engine.exportImage(), before);
  });

  test('assigned nullable key codec still creates a nonnullable SQL key',
      () async {
    final mapping = _Mapping('assigned', [
      _Field('id', Codecs.nullable(Codecs.text), key: 10),
      _Field('v', Codecs.nullable(Codecs.text)),
    ]);
    final migrations = SchemaMigrator(connection, DbModel([mapping.type]));
    await migrations.ensureCreated();
    expect((await engine.query("PRAGMA table_info('assigned')")).rows.first[3],
        BigInt.one);
    await expectLater(engine.execute("INSERT INTO assigned(id) VALUES(NULL)"),
        throwsA(isA<SqlException>()));
    expect((await migrations.plan()).isEmpty, isTrue);
  });

  test('composite keys and deferred FK actions introspect idempotently',
      () async {
    final parent = _Mapping('parent', [
      _Field('a', Codecs.bigInt, key: 5),
      _Field('b', Codecs.text, key: 10)
    ]);
    final child = _Mapping('child', [
      _Field('id', Codecs.nullable(Codecs.bigInt), key: 0, generated: true),
      _Field('pa', Codecs.nullable(Codecs.bigInt)),
      _Field('pb', Codecs.nullable(Codecs.text))
    ]);
    final relation = ForeignKey<_Record, _Record>(
        name: 'child_parent',
        child: child.type,
        parent: parent.type,
        columns: [child.columns['pa']!, child.columns['pb']!],
        targetColumns: [parent.columns['a']!, parent.columns['b']!],
        onDelete: ForeignKeyAction.setNull,
        onUpdate: ForeignKeyAction.cascade,
        deferred: true);
    final migrations = SchemaMigrator(connection,
        DbModel([child.type, parent.type], foreignKeys: [relation]));
    await migrations.ensureCreated();
    expect((await migrations.plan()).isEmpty, isTrue);
    await engine.execute('INSERT INTO parent VALUES(1,\'key\')');
    await engine.execute('INSERT INTO child(pa,pb) VALUES(1,\'key\')');
    await engine.execute('DELETE FROM parent');
    expect((await engine.query('SELECT pa,pb FROM child')).rows, [
      [null, null]
    ]);
  });

  test(
      'FK deferral changes require a rebuild even when PRAGMA rows otherwise match',
      () async {
    final parent = _Mapping('parent', [_Field('id', Codecs.bigInt, key: 0)]);
    final child = _Mapping('child',
        [_Field('id', Codecs.bigInt, key: 0), _Field('p', Codecs.bigInt)]);
    DbModel model(bool deferred) => DbModel([
          parent.type,
          child.type
        ], foreignKeys: [
          ForeignKey<_Record, _Record>(
              name: 'fk',
              child: child.type,
              parent: parent.type,
              columns: [child.columns['p']!],
              targetColumns: [parent.columns['id']!],
              deferred: deferred)
        ]);
    await SchemaMigrator(connection, model(false)).ensureCreated();
    final plan = await SchemaMigrator(connection, model(true)).plan();
    expect(plan.canApply, isFalse);
    expect(
        plan.operations.any((operation) =>
            operation.description.contains('Foreign keys changed')),
        isTrue);
  });

  test('foreign key check failure rolls back approved schema and data changes',
      () async {
    final parent = _Mapping('parent', [_Field('id', Codecs.bigInt, key: 0)]);
    final child = _Mapping('child',
        [_Field('id', Codecs.bigInt, key: 0), _Field('p', Codecs.bigInt)]);
    final model = DbModel([
      parent.type,
      child.type
    ], foreignKeys: [
      ForeignKey<_Record, _Record>(
          name: 'fk',
          child: child.type,
          parent: parent.type,
          columns: [child.columns['p']!],
          targetColumns: [parent.columns['id']!],
          deferred: true)
    ]);
    final migrations = SchemaMigrator(connection, model);
    await migrations.ensureCreated();
    final plan = (await migrations.plan()).withOperations([
      MigrationOperation.sql('INSERT INTO child VALUES(1,999)',
          reason: 'Deliberately invalid deferred child'),
      MigrationOperation.sql('CREATE TABLE incidental(v)',
          reason: 'Must roll back with child'),
    ]);
    final before = engine.exportImage();
    await expectLater(
        migrations.apply(plan, approval: MigrationApproval.forPlan(plan)),
        throwsA(isA<MigrationRequiredException>()));
    expect(engine.exportImage(), before);
  });

  test(
      'default expression quoting and parentheses compare without evaluating functions',
      () async {
    final mapping = _Mapping('defaults', [
      _Field('id', Codecs.nullable(Codecs.bigInt), key: 0, generated: true),
      _Field('value', Codecs.nullable(Codecs.text),
          defaultSql: "('CHECK, COLLATE )''(')"),
    ]);
    final migrations = SchemaMigrator(connection, DbModel([mapping.type]));
    await migrations.ensureCreated();
    expect((await migrations.plan()).isEmpty, isTrue);
    await engine.execute('INSERT INTO defaults DEFAULT VALUES');
    expect((await engine.query('SELECT value FROM defaults')).rows, [
      ["CHECK, COLLATE )'("]
    ]);
  });

  test('operation parameters and review collections are immutable copies',
      () async {
    final bytes = Uint8List.fromList([1, 2]);
    final operation = MigrationOperation.sql('INSERT INTO t VALUES(?)',
        reason: 'Explicit blob backfill', parameters: [bytes]);
    bytes[0] = 9;
    final copy = operation.parameters.single as Uint8List;
    expect(copy, [1, 2]);
    copy[0] = 8;
    expect(operation.parameters.single, [1, 2]);
    expect(() => operation.parameters.clear(), throwsUnsupportedError);
    for (final sql in [
      'BEGIN',
      'COMMIT',
      'ROLLBACK',
      'SAVEPOINT x',
      'PRAGMA foreign_keys=OFF',
      '/* comment */ COMMIT',
      '-- comment\nEND'
    ]) {
      expect(() => MigrationOperation.sql(sql),
          throwsA(isA<OrmMappingException>()));
    }
  });

  test(
      'standalone migrator serializes concurrent calls and rejects external transactions',
      () async {
    final migrations = SchemaMigrator(connection, DbModel([_people().type]));
    await Future.wait([migrations.ensureCreated(), migrations.ensureCreated()]);
    expect(await _version(connection), BigInt.one);
    await engine.execute('BEGIN');
    await expectLater(migrations.plan(), throwsA(isA<OrmStateException>()));
    await expectLater(
        migrations.ensureCreated(), throwsA(isA<OrmStateException>()));
  });

  test('indeterminate commit poisons migrator and publishes no model update',
      () async {
    final faulty = _FaultConnection(connection)..failCommit = true;
    final migrations = SchemaMigrator(faulty, DbModel([_people().type]));
    await expectLater(migrations.ensureCreated(), throwsA(isA<StateError>()));
    expect(
        (await engine.query('SELECT name FROM sqlite_schema')).rows, isEmpty);
    await expectLater(migrations.plan(), throwsA(isA<OrmStateException>()));
  });

  test('a BEGIN failure after opening its transaction is cleaned up', () async {
    final faulty = _FaultConnection(connection)..failBeginAfterOpen = true;
    final migrations = SchemaMigrator(faulty, DbModel([_people().type]));
    await expectLater(migrations.ensureCreated(), throwsA(isA<StateError>()));
    expect(engine.inTransaction, isFalse);
    expect(
        (await engine.query('SELECT name FROM sqlite_schema')).rows, isEmpty);
    await migrations.ensureCreated();
    expect(await _version(connection), BigInt.one);
  });

  test(
      'rollback failure retains original and cleanup causes and poisons migrator',
      () async {
    final faulty = _FaultConnection(connection)..failRollback = true;
    final migrations = SchemaMigrator(faulty, DbModel([_people().type]));
    final plan = (await migrations.plan()).withOperations([
      MigrationOperation.sql(
          'CREATE TABLE people(id INTEGER PRIMARY KEY,name TEXT)',
          reason: 'Create target'),
      MigrationOperation.sql('INSERT INTO absent VALUES(1)',
          reason: 'Inject failure'),
    ]);
    await expectLater(
        migrations.apply(plan, approval: MigrationApproval.forPlan(plan)),
        throwsA(isA<OrmStateException>()
            .having((error) => error.cause, 'cause', isNotNull)));
    await expectLater(migrations.plan(), throwsA(isA<OrmStateException>()));
  });
}

class _FaultConnection extends OrmConnection {
  _FaultConnection(this.inner);
  final OrmConnection inner;
  bool failCommit = false, failRollback = false, failBeginAfterOpen = false;
  @override
  bool get inTransaction => inner.inTransaction;
  @override
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      inner.query(sql, parameters);
  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    if (failBeginAfterOpen && sql == 'BEGIN') {
      failBeginAfterOpen = false;
      await inner.execute(sql, parameters);
      throw StateError('BEGIN failed after opening transaction');
    }
    if (failCommit && sql == 'COMMIT') throw StateError('commit failure');
    if (failRollback && sql == 'ROLLBACK') throw StateError('rollback failure');
    return inner.execute(sql, parameters);
  }

  @override
  Future<void> close() => inner.close();
}
