import 'dart:async';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

class _Record {
  _Record(this.name, {this.id, Uint8List? bytes, BigInt? revision})
      : bytes = bytes ?? Uint8List.fromList([1, 2]),
        revision = revision ?? BigInt.zero;
  BigInt? id;
  String name;
  Uint8List bytes;
  BigInt revision;
}

final _id = Column<_Record, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    read: (entity) => entity.id,
    write: (entity, value) => entity.id = value,
    keyOrder: 0,
    generated: true);
final _name = Column<_Record, String>(
    property: 'name',
    codec: Codecs.text,
    read: (entity) => entity.name,
    write: (entity, value) => entity.name = value,
    unique: true);
final _bytes = Column<_Record, Uint8List>(
    property: 'bytes',
    codec: Codecs.blob,
    read: (entity) => entity.bytes,
    write: (entity, value) => entity.bytes = value);
final _revision = Column<_Record, BigInt>(
    property: 'revision',
    codec: Codecs.bigInt,
    read: (entity) => entity.revision,
    write: (entity, value) => entity.revision = value,
    version: true);
final _type = EntityType<_Record>(
    tableName: 'records',
    columns: [_id, _name, _bytes, _revision],
    create: (row) => _Record(row.read(_name),
        id: row.read(_id),
        bytes: row.read(_bytes),
        revision: row.read(_revision)));

class _Immutable {
  const _Immutable(this.name, [this.id]);
  final BigInt? id;
  final String name;
}

class _IntRecord {
  _IntRecord(this.name, {this.id, this.revision = 0});
  int? id;
  String name;
  int revision;
}

final _intId = Column<_IntRecord, int?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.integer),
    read: (entity) => entity.id,
    write: (entity, value) => entity.id = value,
    keyOrder: 0,
    generated: true);
final _intName = Column<_IntRecord, String>(
    property: 'name',
    codec: Codecs.text,
    read: (entity) => entity.name,
    write: (entity, value) => entity.name = value);
final _intRevision = Column<_IntRecord, int>(
    property: 'revision',
    codec: Codecs.integer,
    read: (entity) => entity.revision,
    write: (entity, value) => entity.revision = value,
    version: true);
final _intType = EntityType<_IntRecord>(
    tableName: 'int_records',
    columns: [_intId, _intName, _intRevision],
    create: (row) => _IntRecord(row.read(_intName),
        id: row.read(_intId), revision: row.read(_intRevision)));

final _immutableId = Column<_Immutable, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    read: (entity) => entity.id,
    keyOrder: 0,
    generated: true);
final _immutableName = Column<_Immutable, String>(
    property: 'name', codec: Codecs.text, read: (entity) => entity.name);
final _immutableType = EntityType<_Immutable>(
    tableName: 'immutable_records',
    columns: [_immutableId, _immutableName],
    create: (row) =>
        _Immutable(row.read(_immutableName), row.read(_immutableId)),
    applyStoreValues: (_, row) =>
        _Immutable(row.read(_immutableName), row.read(_immutableId)));

class _Connection extends OrmConnection {
  _Connection(MutableSqliteDatabase database)
      : inner = MutableDatabaseConnection(database);
  final MutableDatabaseConnection inner;
  final List<String> statements = [];
  String? block;
  final entered = Completer<void>();
  final resume = Completer<void>();
  Object? beginError;
  Object? commitError;
  bool errorAfterCommit = false;
  Object? rollbackError;

  @override
  void claim(Object owner) {
    inner.claim(owner);
    super.claim(owner);
  }

  @override
  void release(Object owner) {
    super.release(owner);
    inner.release(owner);
  }

  @override
  bool get inTransaction => inner.inTransaction;

  Future<void> _before(String sql) async {
    statements.add(sql);
    if (block != null && sql.startsWith(block!)) {
      block = null;
      entered.complete();
      await resume.future;
    }
  }

  @override
  Future<QueryResult> query(String sql,
      [List<Object?> parameters = const []]) async {
    await _before(sql);
    return inner.query(sql, parameters);
  }

  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    await _before(sql);
    if (sql == 'BEGIN' && beginError != null) {
      await inner.execute(sql, parameters);
      throw beginError!;
    }
    if (sql == 'COMMIT' && commitError != null) {
      if (errorAfterCommit) await inner.execute(sql, parameters);
      throw commitError!;
    }
    if (sql == 'ROLLBACK' && rollbackError != null) throw rollbackError!;
    return inner.execute(sql, parameters);
  }

  @override
  Future<void> close() => inner.close();
}

class _Fixture {
  _Fixture(this.database, this.connection, this.context);
  final MutableSqliteDatabase database;
  final _Connection connection;
  final DbContext context;
}

Future<_Fixture> _fixture() async {
  final database = await MutableSqliteDatabase.create();
  await database.execute('CREATE TABLE records('
      'id INTEGER PRIMARY KEY,name TEXT NOT NULL UNIQUE,'
      'bytes BLOB NOT NULL,revision INTEGER NOT NULL)');
  await database.execute(
      'CREATE TABLE immutable_records(id INTEGER PRIMARY KEY,name TEXT NOT NULL)');
  final connection = _Connection(database);
  final context = DbContext(connection, DbModel([_type, _immutableType]));
  addTearDown(() async {
    if (database.inTransaction) await database.execute('ROLLBACK');
    await context.close();
    await database.close();
  });
  return _Fixture(database, connection, context);
}

Future<List<List<Object?>>> _rows(_Fixture fixture) async =>
    (await fixture.database
            .query('SELECT id,name,bytes,revision FROM records ORDER BY id'))
        .rows;

void main() {
  test('CRUD binds values, preserves zero and full integer keys, and detaches',
      () async {
    final fixture = await _fixture();
    final set = fixture.context.set(_type);
    final pending = set.add(_Record("Robert'); DROP TABLE records;--"));
    final zero = set.add(_Record('zero', id: BigInt.zero));
    final largeId = BigInt.parse('9223372036854775806');
    final large = set.add(_Record('large', id: largeId));
    expect(await fixture.context.saveChanges(), 3);
    expect(pending.entity.id, BigInt.one);
    expect(zero.entity.id, BigInt.zero);
    expect(large.entity.id, largeId);
    expect(await set.find(EntityKey([largeId])), same(large.entity));
    expect(await set.find(EntityKey([BigInt.from(100)])), isNull);
    pending.entity.name = 'updated';
    expect(pending.state, EntityState.modified);
    expect(await fixture.context.saveChanges(), 1);
    expect(pending.entity.revision, BigInt.one);
    expect(pending.state, EntityState.unchanged);
    set.remove(pending.entity);
    expect(pending.state, EntityState.deleted);
    expect(await fixture.context.saveChanges(), 1);
    expect(pending.state, EntityState.detached);
    expect(await set.find(EntityKey([BigInt.one])), isNull);
    expect((await _rows(fixture)).map((row) => row[1]), ['zero', 'large']);
  });

  test('identity map rejects duplicate instances and tracking preserves edits',
      () async {
    final fixture = await _fixture();
    final set = fixture.context.set(_type);
    final entity = _Record('original', id: BigInt.one);
    final entry = set.add(entity);
    await fixture.context.saveChanges();
    expect(set.attach(entity), same(entry));
    expect(() => set.attach(_Record('duplicate', id: BigInt.one)),
        throwsA(isA<OrmStateException>()));
    entity.name = 'local';
    expect((await set.query.toList()).single, same(entity));
    expect(entity.name, 'local');
    final untracked = (await set.query.asNoTracking().toList()).single;
    expect(untracked, isNot(same(entity)));
    expect(untracked.name, 'original');
    expect(() => fixture.context.entry(untracked),
        throwsA(isA<OrmStateException>()));
  });

  test('reverted changes are clean and snapshots isolate in-place blob edits',
      () async {
    final fixture = await _fixture();
    final entry = fixture.context.set(_type).add(_Record('original'));
    await fixture.context.saveChanges();
    fixture.connection.statements.clear();
    entry.entity.name = 'changed';
    expect(entry.state, EntityState.modified);
    entry.entity.name = 'original';
    final copied = entry.originalValues['bytes'] as Uint8List;
    copied[0] = 99;
    expect(entry.state, EntityState.unchanged);
    expect(await fixture.context.saveChanges(), 0);
    expect(fixture.connection.statements, isEmpty);
    entry.entity.bytes[0] = 7;
    expect(entry.state, EntityState.modified);
    await fixture.context.saveChanges();
    expect((await _rows(fixture)).single[2], [7, 2]);
    entry.entity.bytes[1] = 8;
    expect(entry.originalValues['bytes'], [7, 2]);
    expect(
        () => entry.originalValues['name'] = 'other', throwsUnsupportedError);
  });

  test(
      'added removed entities cancel and generated temporary identities differ',
      () async {
    final fixture = await _fixture();
    final set = fixture.context.set(_type);
    final first = set.add(_Record('first'));
    final second = set.add(_Record('second'));
    set.remove(first.entity);
    expect(first.state, EntityState.detached);
    expect(await fixture.context.saveChanges(), 1);
    expect(second.entity.id, BigInt.one);
    expect(await fixture.context.saveChanges(), 0);
  });

  test(
      'immutable generated values use canonical entry and replace preserves key',
      () async {
    final fixture = await _fixture();
    final set = fixture.context.set(_immutableType);
    const original = _Immutable('before');
    final entry = set.add(original);
    await fixture.context.saveChanges();
    expect(original.id, isNull);
    expect(entry.entity.id, BigInt.one);
    expect(() => fixture.context.entry(original),
        throwsA(isA<OrmStateException>()));
    final replacement = _Immutable('after', entry.entity.id);
    expect(set.replace(entry.entity, replacement), same(entry));
    expect(entry.state, EntityState.modified);
    expect(() => set.replace(replacement, _Immutable('bad', BigInt.two)),
        throwsA(isA<OrmStateException>()));
    await fixture.context.saveChanges();
    expect(await set.find(EntityKey([BigInt.one])), same(replacement));
    expect(
        (await fixture.database.query('SELECT name FROM immutable_records'))
            .rows
            .single
            .single,
        'after');
  });

  test('assigned nullable keys must have actual values and keys cannot mutate',
      () async {
    final fixture = await _fixture();
    final assignedId = Column<_Immutable, BigInt?>(
        property: 'id',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (entity) => entity.id,
        keyOrder: 0);
    final type = EntityType<_Immutable>(
        tableName: 'assigned',
        columns: [assignedId, _immutableName],
        create: (row) =>
            _Immutable(row.read(_immutableName), row.read(assignedId)));
    final context = DbContext(
        MutableDatabaseConnection(await MutableSqliteDatabase.create()),
        DbModel([type]));
    addTearDown(() async {
      final connection = context.connection as MutableDatabaseConnection;
      await context.close();
      await connection.database.close();
    });
    expect(() => context.set(type).add(const _Immutable('missing')),
        throwsA(isA<OrmStateException>()));
    expect(() => fixture.context.set(_type).attach(_Record('missing')),
        throwsA(isA<OrmStateException>()));
    final entry = fixture.context.set(_type).add(_Record('key'));
    await fixture.context.saveChanges();
    entry.entity.id = BigInt.two;
    expect(() => entry.state, throwsA(isA<OrmStateException>()));
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<OrmStateException>()));
    expect((await _rows(fixture)).single[0], BigInt.one);
  });

  test('unique failure rolls back all rows and generated keys; retry is atomic',
      () async {
    final fixture = await _fixture();
    final set = fixture.context.set(_type);
    final first = set.add(_Record('duplicate'));
    final second = set.add(_Record('duplicate'));
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<SqlException>()));
    expect(await _rows(fixture), isEmpty);
    expect(first.entity.id, isNull);
    expect(second.entity.id, isNull);
    expect(first.state, EntityState.added);
    expect(first.originalValues, isEmpty);
    second.entity.name = 'fixed';
    expect(await fixture.context.saveChanges(), 2);
    expect(first.entity.id, BigInt.one);
    expect(second.entity.id, BigInt.two);
  });

  test('stale second revision rolls back first update and accepts no snapshots',
      () async {
    final fixture = await _fixture();
    final set = fixture.context.set(_type);
    final first = set.add(_Record('first'));
    final second = set.add(_Record('second'));
    await fixture.context.saveChanges();
    first.entity.name = 'first changed';
    second.entity.name = 'second changed';
    await fixture.database.execute('UPDATE records SET revision=1 WHERE id=2');
    await expectLater(fixture.context.saveChanges(),
        throwsA(isA<OptimisticConcurrencyException>()));
    expect((await _rows(fixture)).map((row) => row[1]), ['first', 'second']);
    expect(first.entity.revision, BigInt.zero);
    expect(first.originalValues['name'], 'first');
    expect(first.state, EntityState.modified);
    expect(second.state, EntityState.modified);
    set.remove(second.entity);
    await expectLater(fixture.context.saveChanges(),
        throwsA(isA<OptimisticConcurrencyException>()));
    expect(second.state, EntityState.deleted);
    expect((await _rows(fixture)).length, 2);
  });

  test('manual revision edits and missing update or delete are rejected',
      () async {
    final fixture = await _fixture();
    final set = fixture.context.set(_type);
    final entry = set.add(_Record('row'));
    await fixture.context.saveChanges();
    entry.entity.revision = BigInt.one;
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<OrmStateException>()));
    entry.entity.revision = BigInt.zero;
    await fixture.database.execute('DELETE FROM records');
    entry.entity.name = 'changed';
    await expectLater(fixture.context.saveChanges(),
        throwsA(isA<OptimisticConcurrencyException>()));
    set.remove(entry.entity);
    await expectLater(fixture.context.saveChanges(),
        throwsA(isA<OptimisticConcurrencyException>()));
    expect(entry.state, EntityState.deleted);
  });

  test('AFTER trigger values refresh while key-changing triggers roll back',
      () async {
    final fixture = await _fixture();
    await fixture.database.execute(
        'CREATE TRIGGER refresh AFTER INSERT ON records '
        "BEGIN UPDATE records SET name=UPPER(NEW.name) WHERE id=NEW.id; END");
    final entry = fixture.context.set(_type).add(_Record('lower'));
    await fixture.context.saveChanges();
    expect(entry.entity.name, 'LOWER');
    expect(entry.originalValues['name'], 'LOWER');
    await fixture.database.execute('DROP TRIGGER refresh');
    await fixture.database
        .execute('CREATE TRIGGER move AFTER INSERT ON records '
            'BEGIN UPDATE records SET id=id+100 WHERE id=NEW.id; END');
    final moved = fixture.context.set(_type).add(_Record('moved'));
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<OrmStateException>()));
    expect(moved.entity.id, isNull);
    expect((await _rows(fixture)).length, 1);
    expect(moved.state, EntityState.added);
  });

  test('trigger callback failure rolls back batch and leaves retry possible',
      () async {
    final fixture = await _fixture();
    await fixture.database.execute('CREATE TRIGGER reject_second BEFORE INSERT '
        "ON records WHEN NEW.name='second' BEGIN SELECT RAISE(ABORT,'blocked'); END");
    final first = fixture.context.set(_type).add(_Record('first'));
    final second = fixture.context.set(_type).add(_Record('second'));
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<SqlException>()));
    expect(await _rows(fixture), isEmpty);
    expect(first.entity.id, isNull);
    expect(second.entity.id, isNull);
    await fixture.database.execute('DROP TRIGGER reject_second');
    expect(await fixture.context.saveChanges(), 2);
  });

  test(
      'Dart SQL callback failure rolls back previous writes and provisional IDs',
      () async {
    final fixture = await _fixture();
    var calls = 0;
    var fail = true;
    fixture.database.functions.registerScalar('observed_write', 1, (arguments) {
      calls++;
      if (arguments.single == 'second' && fail) {
        throw StateError('injected callback failure');
      }
      return 1;
    });
    await fixture.database.execute('CREATE TRIGGER observe AFTER INSERT '
        'ON records BEGIN SELECT observed_write(NEW.name); END');
    final first = fixture.context.set(_type).add(_Record('first'));
    final second = fixture.context.set(_type).add(_Record('second'));
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<SqlException>()));
    expect(calls, 2);
    expect(await _rows(fixture), isEmpty);
    expect(first.entity.id, isNull);
    expect(second.entity.id, isNull);
    fail = false;
    expect(await fixture.context.saveChanges(), 2);
    expect(calls, 4);
  });

  test('invalid store codec values roll back before publishing generated keys',
      () async {
    final fixture = await _fixture();
    await fixture.database.execute('CREATE TRIGGER corrupt_blob AFTER INSERT '
        "ON records BEGIN UPDATE records SET bytes='text' WHERE id=NEW.id; END");
    final entry = fixture.context.set(_type).add(_Record('row'));
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<OrmCodecException>()));
    expect(entry.entity.id, isNull);
    expect(entry.state, EntityState.added);
    expect(await _rows(fixture), isEmpty);
    await fixture.database.execute('DROP TRIGGER corrupt_blob');
    await fixture.context.saveChanges();
    expect(entry.entity.id, BigInt.one);
  });

  test(
      'generated key identity collisions with attached rows fail before commit',
      () async {
    final fixture = await _fixture();
    fixture.context.set(_type).attach(_Record('phantom', id: BigInt.one));
    final added = fixture.context.set(_type).add(_Record('generated'));
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<OrmStateException>()));
    expect(await _rows(fixture), isEmpty);
    expect(added.entity.id, isNull);
    expect(added.state, EntityState.added);
  });

  test('int generated keys and revisions keep portable codec semantics',
      () async {
    final database = await MutableSqliteDatabase.create();
    await database.execute('CREATE TABLE int_records('
        'id INTEGER PRIMARY KEY,name TEXT,revision INTEGER NOT NULL)');
    final context =
        DbContext(MutableDatabaseConnection(database), DbModel([_intType]));
    addTearDown(() async {
      await context.close();
      await database.close();
    });
    final entry = context.set(_intType).add(_IntRecord('before'));
    await context.saveChanges();
    expect(entry.entity.id, 1);
    entry.entity.name = 'after';
    await context.saveChanges();
    expect(entry.entity.revision, 1);
    expect(await context.set(_intType).find(EntityKey([BigInt.one])),
        same(entry.entity));
    final boundary = context.set(_intType).add(_IntRecord('boundary',
        id: 9007199254740991, revision: 9007199254740991));
    await context.saveChanges();
    boundary.entity.name = 'overflow';
    await expectLater(context.saveChanges(), throwsA(isA<OrmCodecException>()));
    expect(boundary.entity.revision, 9007199254740991);
    expect(
        (await database.query('SELECT name FROM int_records WHERE id=?',
                [BigInt.parse('9007199254740991')]))
            .rows
            .single
            .single,
        'boundary');
  });

  test('save freezes synchronously and preserves later scalar and blob edits',
      () async {
    final fixture = await _fixture();
    final entry = fixture.context.set(_type).add(_Record('frozen'));
    fixture.connection.block = 'BEGIN';
    final saving = fixture.context.saveChanges();
    entry.entity.name = 'later';
    entry.entity.bytes[0] = 7;
    await fixture.connection.entered.future;
    expect(entry.entity.id, isNull);
    fixture.connection.resume.complete();
    expect(await saving, 1);
    final row = (await _rows(fixture)).single;
    expect(row[1], 'frozen');
    expect(row[2], [1, 2]);
    expect(entry.entity.name, 'later');
    expect(entry.entity.bytes, [7, 2]);
    expect(entry.entity.id, BigInt.one);
    expect(entry.state, EntityState.modified);
    expect(entry.originalValues['name'], 'frozen');
    await fixture.context.saveChanges();
    expect((await _rows(fixture)).single[1], 'later');
    expect(entry.state, EntityState.unchanged);
  });

  test('save freezes before queued queries finish and queues later reads',
      () async {
    final fixture = await _fixture();
    final entry = fixture.context.set(_type).add(_Record('frozen'));
    fixture.connection.block = 'SELECT';
    final earlier = fixture.context.set(_type).query.toList();
    await fixture.connection.entered.future;
    final saving = fixture.context.saveChanges();
    entry.entity.name = 'later';
    final reading = fixture.context.set(_type).query.asNoTracking().toList();
    var readFinished = false;
    unawaited(reading.then((_) => readFinished = true));
    await Future<void>.delayed(Duration.zero);
    expect(readFinished, isFalse);
    fixture.connection.resume.complete();
    expect(await earlier, isEmpty);
    await saving;
    expect((await reading).single.name, 'frozen');
    expect(entry.entity.name, 'later');
    expect(entry.state, EntityState.modified);
  });

  test('pending save rejects overlapping saves and tracking membership edits',
      () async {
    final fixture = await _fixture();
    final set = fixture.context.set(_type);
    final entry = set.add(_Record('row'));
    fixture.connection.block = 'BEGIN';
    final saving = fixture.context.saveChanges();
    await fixture.connection.entered.future;
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<OrmStateException>()));
    expect(() => set.add(_Record('new')), throwsA(isA<OrmStateException>()));
    expect(() => set.attach(_Record('attached', id: BigInt.two)),
        throwsA(isA<OrmStateException>()));
    expect(() => set.remove(entry.entity), throwsA(isA<OrmStateException>()));
    expect(() => set.replace(entry.entity, _Record('replacement')),
        throwsA(isA<OrmStateException>()));
    fixture.connection.resume.complete();
    await saving;
    set.add(_Record('after'));
    expect(await fixture.context.saveChanges(), 1);
  });

  test('external transaction is rejected without accepting snapshots',
      () async {
    final fixture = await _fixture();
    await fixture.context.set(_type).query.toList();
    final entry = fixture.context.set(_type).add(_Record('row'));
    await fixture.database.execute('BEGIN');
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<OrmStateException>()));
    expect(fixture.database.inTransaction, isTrue);
    expect(entry.entity.id, isNull);
    expect(entry.state, EntityState.added);
    await fixture.database.execute('ROLLBACK');
    expect(await fixture.context.saveChanges(), 1);
  });

  test(
      'BEGIN acknowledgement failure rolls back opened transaction and retries',
      () async {
    final fixture = await _fixture();
    final entry = fixture.context.set(_type).add(_Record('pending'));
    final failure = StateError('lost BEGIN acknowledgement');
    fixture.connection.beginError = failure;
    await expectLater(fixture.context.saveChanges(), throwsA(same(failure)));
    expect(fixture.database.inTransaction, isFalse);
    expect(await _rows(fixture), isEmpty);
    expect(entry.entity.id, isNull);
    expect(entry.state, EntityState.added);
    expect(entry.originalValues, isEmpty);
    expect(fixture.connection.statements.where((sql) => sql == 'ROLLBACK'),
        hasLength(1));
    fixture.connection.beginError = null;
    expect(await fixture.context.saveChanges(), 1);
    expect(entry.entity.id, BigInt.one);
    expect(entry.state, EntityState.unchanged);
  });

  for (final afterCommit in [false, true]) {
    test(
        'unknown ${afterCommit ? 'durable' : 'precommit'} error poisons context',
        () async {
      final fixture = await _fixture();
      final entry = fixture.context.set(_type).add(_Record('row'));
      fixture.connection.commitError = StateError('injected commit error');
      fixture.connection.errorAfterCommit = afterCommit;
      await expectLater(fixture.context.saveChanges(), throwsStateError);
      expect(entry.entity.id, isNull);
      expect(entry.state, EntityState.added);
      expect((await _rows(fixture)).length, afterCommit ? 1 : 0);
      expect(
          () => fixture.context.set(_type), throwsA(isA<OrmStateException>()));
      await expectLater(
          fixture.context.saveChanges(), throwsA(isA<OrmStateException>()));
      expect(
          fixture.connection.statements
              .where((sql) => sql == 'ROLLBACK')
              .length,
          afterCommit ? 0 : 1);
    });
  }

  test('rollback failure retains both errors and poisons subsequent operations',
      () async {
    final fixture = await _fixture();
    fixture.context.set(_type).add(_Record('same'));
    fixture.context.set(_type).add(_Record('same'));
    final cleanup = StateError('injected rollback error');
    fixture.connection.rollbackError = cleanup;
    await expectLater(
        fixture.context.saveChanges(),
        throwsA(isA<OrmStateException>().having(
            (error) => error.cause,
            'preserved causes',
            isA<({Object operation, Object rollback})>()
                .having((cause) => cause.rollback, 'rollback', same(cleanup))
                .having((cause) => cause.operation, 'operation',
                    isA<SqlException>()))));
    expect(() => fixture.context.set(_type), throwsA(isA<OrmStateException>()));
    await fixture.database.execute('ROLLBACK');
  });

  test('indeterminate migration commit blocks every context SQL operation',
      () async {
    final database = await MutableSqliteDatabase.create();
    final connection = _Connection(database);
    final context = DbContext(connection, DbModel([_type]));
    addTearDown(() async {
      await context.close();
      await database.close();
    });
    // Obtain handles before the fault so they must also enforce unusability.
    final set = context.set(_type);
    final query = set.query;
    final entry = set.add(_Record('pending'));
    final migration = context.migrations;
    connection.commitError = StateError('lost migration acknowledgement');
    connection.errorAfterCommit = true;
    await expectLater(migration.ensureCreated(), throwsStateError);
    expect((await database.query('SELECT * FROM records')).rows, isEmpty);
    expect(entry.entity.id, isNull);
    final statements = connection.statements.length;
    expect(() => context.set(_type), throwsA(isA<OrmStateException>()));
    expect(() => set.add(_Record('later')), throwsA(isA<OrmStateException>()));
    await expectLater(query.toList(), throwsA(isA<OrmStateException>()));
    await expectLater(
        set.find(EntityKey([BigInt.one])), throwsA(isA<OrmStateException>()));
    await expectLater(context.saveChanges(), throwsA(isA<OrmStateException>()));
    await expectLater(migration.plan(), throwsA(isA<OrmStateException>()));
    expect(connection.statements.length, statements);
    await context.close();
    final reopened =
        DbContext(MutableDatabaseConnection(database), DbModel([_type]));
    expect(await reopened.set(_type).query.toList(), isEmpty);
    await reopened.close();
  });

  test('close drains pending work, detaches entries and releases connection',
      () async {
    final fixture = await _fixture();
    final entry = fixture.context.set(_type).add(_Record('row'));
    fixture.connection.block = 'BEGIN';
    final saving = fixture.context.saveChanges();
    await fixture.connection.entered.future;
    final closing = fixture.context.close();
    expect(() => fixture.context.set(_type), throwsA(isA<OrmStateException>()));
    fixture.connection.resume.complete();
    await saving;
    await closing;
    expect(entry.state, EntityState.detached);
    await fixture.context.close();
    final reopened = DbContext(
        MutableDatabaseConnection(fixture.database), DbModel([_type]));
    expect((await reopened.set(_type).query.toList()).single.name, 'row');
    await reopened.close();
  });
}
