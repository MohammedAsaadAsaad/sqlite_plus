import 'dart:async';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart'
    show MutableSqliteDatabase, MutationResult, QueryResult, SqlException;
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

class _Parent {
  _Parent(this.name, [this.id]);
  BigInt? id;
  String name;
}

class _Child {
  _Child(this.label, {this.id, this.parentId});
  BigInt? id;
  BigInt? parentId;
  String label;
}

class _RequiredChild {
  _RequiredChild(this.id, this.parentId);
  BigInt id;
  BigInt parentId;
}

class _CountingConnection extends OrmConnection {
  _CountingConnection(MutableSqliteDatabase database)
      : inner = MutableDatabaseConnection(database);
  final MutableDatabaseConnection inner;
  int selects = 0;
  int executions = 0;
  Completer<void>? commitReached;
  Completer<void>? resumeCommit;

  void pauseCommit() {
    commitReached = Completer<void>();
    resumeCommit = Completer<void>();
  }

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
  @override
  Future<QueryResult> query(String sql, [List<Object?> parameters = const []]) {
    if (sql.trimLeft().toUpperCase().startsWith('SELECT')) selects++;
    return inner.query(sql, parameters);
  }

  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    executions++;
    if (sql == 'COMMIT' && resumeCommit != null) {
      commitReached!.complete();
      await resumeCommit!.future;
      resumeCommit = null;
    }
    return inner.execute(sql, parameters);
  }

  @override
  Future<void> close() => inner.close();
}

final _parentId = Column<_Parent, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    read: (entity) => entity.id,
    write: (entity, value) => entity.id = value,
    keyOrder: 0,
    generated: true);
final _parentName = Column<_Parent, String>(
    property: 'name',
    codec: Codecs.text,
    read: (entity) => entity.name,
    write: (entity, value) => entity.name = value,
    unique: true);
final _parentType = EntityType<_Parent>(
    tableName: 'parents',
    columns: [_parentId, _parentName],
    create: (row) => _Parent(row.read(_parentName), row.read(_parentId)));
final _childId = Column<_Child, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    read: (entity) => entity.id,
    write: (entity, value) => entity.id = value,
    keyOrder: 0,
    generated: true);
final _childParent = Column<_Child, BigInt?>(
    property: 'parentId',
    codec: Codecs.nullable(Codecs.bigInt),
    read: (entity) => entity.parentId,
    write: (entity, value) => entity.parentId = value);
final _childLabel = Column<_Child, String>(
    property: 'label',
    codec: Codecs.text,
    read: (entity) => entity.label,
    write: (entity, value) => entity.label = value,
    unique: true);
final _childType = EntityType<_Child>(
    tableName: 'children',
    columns: [_childId, _childParent, _childLabel],
    create: (row) => _Child(row.read(_childLabel),
        id: row.read(_childId), parentId: row.read(_childParent)));

class _Fixture {
  _Fixture(this.database, this.connection, this.context, this.relation);
  final MutableSqliteDatabase database;
  final _CountingConnection connection;
  final DbContext context;
  final ForeignKey<_Child, _Parent> relation;
}

class _CompositeParent {
  _CompositeParent(this.tenant, this.token, this.name);
  BigInt tenant;
  Uint8List token;
  String name;
}

class _CompositeChild {
  _CompositeChild(this.id, this.tenant, this.token);
  BigInt id;
  BigInt? tenant;
  Uint8List? token;
}

class _CompositeFixture {
  _CompositeFixture(
      this.database, this.context, this.parent, this.child, this.relationship);
  final MutableSqliteDatabase database;
  final DbContext context;
  final EntityType<_CompositeParent> parent;
  final EntityType<_CompositeChild> child;
  final ForeignKey<_CompositeChild, _CompositeParent> relationship;
}

Future<_CompositeFixture> _compositeFixture(
    {bool mixedNullability = false}) async {
  final tenant = Column<_CompositeParent, BigInt>(
      property: 'tenant',
      codec: Codecs.bigInt,
      keyOrder: 0,
      read: (parent) => parent.tenant);
  final token = Column<_CompositeParent, Uint8List>(
      property: 'token',
      codec: Codecs.blob,
      keyOrder: 1,
      read: (parent) => parent.token);
  final name = Column<_CompositeParent, String>(
      property: 'name', codec: Codecs.text, read: (parent) => parent.name);
  final parent = EntityType<_CompositeParent>(
      tableName: 'composite_parents',
      columns: [tenant, token, name],
      create: (row) =>
          _CompositeParent(row.read(tenant), row.read(token), row.read(name)));
  final id = Column<_CompositeChild, BigInt>(
      property: 'id',
      codec: Codecs.bigInt,
      keyOrder: 0,
      read: (child) => child.id);
  final Column<_CompositeChild, dynamic> childTenant = mixedNullability
      ? Column<_CompositeChild, BigInt>(
          property: 'tenant',
          codec: Codecs.bigInt,
          read: (child) => child.tenant!,
          write: (child, value) => child.tenant = value)
      : Column<_CompositeChild, BigInt?>(
          property: 'tenant',
          codec: Codecs.nullable(Codecs.bigInt),
          read: (child) => child.tenant,
          write: (child, value) => child.tenant = value);
  final childToken = Column<_CompositeChild, Uint8List?>(
      property: 'token',
      codec: Codecs.nullable(Codecs.blob),
      read: (child) => child.token,
      write: (child, value) => child.token = value);
  final child = EntityType<_CompositeChild>(
      tableName: 'composite_children',
      columns: [id, childTenant, childToken],
      create: (row) => _CompositeChild(
          row.read(id),
          row.read<_CompositeChild, dynamic>(childTenant) as BigInt?,
          row.read(childToken)));
  final relationship = ForeignKey<_CompositeChild, _CompositeParent>(
      name: 'composite_parent',
      child: child,
      parent: parent,
      columns: [childTenant, childToken],
      targetColumns: [tenant, token]);
  final database = await MutableSqliteDatabase.create();
  await database.execute('CREATE TABLE composite_parents('
      'tenant INTEGER NOT NULL,token BLOB NOT NULL,name TEXT NOT NULL,'
      'PRIMARY KEY(tenant,token))');
  await database.execute('CREATE TABLE composite_children('
      'id INTEGER PRIMARY KEY,tenant INTEGER'
      '${mixedNullability ? ' NOT NULL' : ''},token BLOB,'
      'FOREIGN KEY(tenant,token) REFERENCES composite_parents(tenant,token))');
  final context = DbContext(MutableDatabaseConnection(database),
      DbModel([parent, child], foreignKeys: [relationship]));
  addTearDown(() async {
    await context.close();
    await database.close();
  });
  return _CompositeFixture(database, context, parent, child, relationship);
}

class _Node {
  _Node(this.name, {this.id, this.nextId});
  BigInt? id;
  BigInt? nextId;
  String name;
}

Future<
        (
          MutableSqliteDatabase,
          _CountingConnection,
          DbContext,
          EntityType<_Node>,
          ForeignKey<_Node, _Node>
        )>
    _cycleFixture(
        {required bool deferred,
        ForeignKeyAction onDelete = ForeignKeyAction.noAction}) async {
  final id = Column<_Node, BigInt?>(
      property: 'id',
      codec: Codecs.nullable(Codecs.bigInt),
      keyOrder: 0,
      generated: true,
      read: (node) => node.id,
      write: (node, value) => node.id = value);
  final nextId = Column<_Node, BigInt?>(
      property: 'nextId',
      codec: Codecs.nullable(Codecs.bigInt),
      read: (node) => node.nextId,
      write: (node, value) => node.nextId = value);
  final name = Column<_Node, String>(
      property: 'name', codec: Codecs.text, read: (node) => node.name);
  final type = EntityType<_Node>(
      tableName: 'nodes',
      columns: [id, nextId, name],
      create: (row) =>
          _Node(row.read(name), id: row.read(id), nextId: row.read(nextId)));
  final relation = ForeignKey<_Node, _Node>(
      name: 'next',
      child: type,
      parent: type,
      columns: [nextId],
      targetColumns: [id],
      onDelete: onDelete,
      deferred: deferred);
  final database = await MutableSqliteDatabase.create();
  await database.execute('CREATE TABLE nodes('
      'id INTEGER PRIMARY KEY,nextId INTEGER,name TEXT NOT NULL,'
      'FOREIGN KEY(nextId) REFERENCES nodes(id)'
      '${onDelete == ForeignKeyAction.cascade ? ' ON DELETE CASCADE' : ''}'
      '${deferred ? ' DEFERRABLE INITIALLY DEFERRED' : ''})');
  final connection = _CountingConnection(database);
  final context =
      DbContext(connection, DbModel([type], foreignKeys: [relation]));
  addTearDown(() async {
    await context.close();
    await database.close();
  });
  return (database, connection, context, type, relation);
}

Future<_Fixture> _fixture(
    {ForeignKeyAction onDelete = ForeignKeyAction.noAction}) async {
  final database = await MutableSqliteDatabase.create();
  final action = switch (onDelete) {
    ForeignKeyAction.cascade => 'CASCADE',
    ForeignKeyAction.setNull => 'SET NULL',
    _ => 'NO ACTION'
  };
  await database.execute(
      'CREATE TABLE parents(id INTEGER PRIMARY KEY,name TEXT NOT NULL UNIQUE)');
  await database.execute('CREATE TABLE children(id INTEGER PRIMARY KEY,'
      'parentId INTEGER,label TEXT NOT NULL UNIQUE,'
      'FOREIGN KEY(parentId) REFERENCES parents(id) ON DELETE $action)');
  final relation = ForeignKey<_Child, _Parent>(
      name: 'parent',
      child: _childType,
      parent: _parentType,
      columns: [_childParent],
      targetColumns: [_parentId],
      onDelete: onDelete);
  final connection = _CountingConnection(database);
  final context = DbContext(
      connection, DbModel([_parentType, _childType], foreignKeys: [relation]));
  addTearDown(() async {
    await context.close();
    await database.close();
  });
  return _Fixture(database, connection, context, relation);
}

void main() {
  test('optional references skip SQL and repeated loads reuse tracked identity',
      () async {
    final fixture = await _fixture();
    await fixture.database
        .execute("INSERT INTO parents VALUES(1,'Ada'),(2,'Grace')");
    await fixture.database.execute(
        "INSERT INTO children VALUES(1,1,'first'),(2,NULL,'optional')");
    final first = (await fixture.context.set(_childType).find(EntityKey([1])))!;
    final optional =
        (await fixture.context.set(_childType).find(EntityKey([2])))!;
    fixture.connection.selects = 0;
    expect(
        await fixture.context
            .entry(optional)
            .reference(fixture.relation)
            .load(),
        isNull);
    expect(fixture.connection.selects, 0);
    final parent = (await fixture.context
        .entry(first)
        .reference(fixture.relation)
        .load())!;
    parent.name = 'local edit';
    final again =
        await fixture.context.entry(first).reference(fixture.relation).load();
    expect(identical(parent, again), isTrue);
    expect(again!.name, 'local edit');
  });

  test('required missing parent is an explicit relationship error', () async {
    final database = await MutableSqliteDatabase.create();
    final id = Column<_RequiredChild, BigInt>(
        property: 'id',
        codec: Codecs.bigInt,
        read: (entity) => entity.id,
        keyOrder: 0);
    final parentId = Column<_RequiredChild, BigInt>(
        property: 'parentId',
        codec: Codecs.bigInt,
        read: (entity) => entity.parentId);
    final type = EntityType<_RequiredChild>(
        tableName: 'required_children',
        columns: [id, parentId],
        create: (row) => _RequiredChild(row.read(id), row.read(parentId)));
    final relation = ForeignKey<_RequiredChild, _Parent>(
        name: 'required_parent',
        child: type,
        parent: _parentType,
        columns: [parentId],
        targetColumns: [_parentId]);
    await database
        .execute('CREATE TABLE parents(id INTEGER PRIMARY KEY,name TEXT)');
    await database.execute(
        'CREATE TABLE required_children(id INTEGER PRIMARY KEY,parentId INTEGER NOT NULL)');
    await database.execute('INSERT INTO required_children VALUES(1,99)');
    final context = DbContext(MutableDatabaseConnection(database),
        DbModel([_parentType, type], foreignKeys: [relation]));
    addTearDown(() async {
      await context.close();
      await database.close();
    });
    final child = (await context.set(type).find(EntityKey([1])))!;
    await expectLater(context.entry(child).reference(relation).load(),
        throwsA(isA<OrmStateException>()));
    expect(() => context.entry(child).reference(relation).set(null),
        throwsA(isA<OrmStateException>()));
  });

  test('optional missing parent returns null without creating a tracked value',
      () async {
    final fixture = await _fixture();
    // External databases may contain an orphan created before enforcement was
    // enabled. Explicit loading still has defined optional-reference behavior.
    await fixture.database
        .execute("INSERT INTO children VALUES(1,99,'orphan')");
    final child = (await fixture.context.set(_childType).find(EntityKey([1])))!;
    expect(
        await fixture.context.entry(child).reference(fixture.relation).load(),
        isNull);
    expect(
        await fixture.context.set(_parentType).find(EntityKey([99])), isNull);
  });

  test(
      'collection loads reflect FK edits and pending links without stale caches',
      () async {
    final fixture = await _fixture();
    await fixture.database
        .execute("INSERT INTO parents VALUES(1,'Ada'),(2,'Grace')");
    await fixture.database
        .execute("INSERT INTO children VALUES(1,1,'first'),(2,1,'second')");
    final ada = (await fixture.context.set(_parentType).find(EntityKey([1])))!;
    final grace =
        (await fixture.context.set(_parentType).find(EntityKey([2])))!;
    final adaEntry = fixture.context.entry(ada);
    final graceEntry = fixture.context.entry(grace);
    final children = await adaEntry.collection(fixture.relation).load();
    expect(children.map((entity) => entity.label), ['first', 'second']);
    children.first.parentId = BigInt.two;
    expect(
        (await adaEntry.collection(fixture.relation).load())
            .map((entity) => entity.label),
        ['second']);
    expect(
        (await graceEntry.collection(fixture.relation).load())
            .map((entity) => entity.label),
        ['first']);
    final added = fixture.context.set(_childType).add(_Child('new'));
    graceEntry.collection(fixture.relation).add(added);
    expect(
        (await graceEntry.collection(fixture.relation).load())
            .map((entity) => entity.label),
        ['first', 'new']);
    expect(await added.reference(fixture.relation).load(), same(grace));
  });

  test('batched reference and collection loading uses bounded IN queries',
      () async {
    final fixture = await _fixture();
    const count = 901;
    await fixture.database.execute('INSERT INTO parents VALUES ${[
      for (var id = 1; id <= count; id++) "($id,'parent$id')"
    ].join(',')}');
    await fixture.database.execute('INSERT INTO children VALUES ${[
      for (var id = 1; id <= count; id++) "($id,$id,'child$id')"
    ].join(',')}');
    final children = await fixture.context.set(_childType).query.toList();
    final entries = children.map(fixture.context.entry).toList();
    fixture.connection.selects = 0;
    final parents =
        await fixture.context.loadReferences(fixture.relation, entries);
    expect(parents.length, count);
    expect(fixture.connection.selects, 2);
    expect(parents[entries.first]!.id, BigInt.one);
    expect(parents[entries.last]!.id, BigInt.from(count));
    final parentEntries =
        parents.values.map((parent) => fixture.context.entry(parent!)).toList();
    fixture.connection.selects = 0;
    final collections =
        await fixture.context.loadCollections(fixture.relation, parentEntries);
    expect(fixture.connection.selects, 2);
    expect(
        collections.values.every((children) => children.length == 1), isTrue);
    expect(identical(collections[parentEntries.first]!.single, children.first),
        isTrue);
    expect(() => collections[parentEntries.first]!.clear(),
        throwsUnsupportedError);
  });

  test('generated parent and child save together in dependency order',
      () async {
    final fixture = await _fixture();
    final child = fixture.context.set(_childType).add(_Child('child'));
    final parent = fixture.context.set(_parentType).add(_Parent('parent'));
    child.reference(fixture.relation).set(parent);
    expect(parent.entity.id, isNull);
    expect(child.entity.parentId, isNull);
    fixture.connection.selects = 0;
    expect(await child.reference(fixture.relation).load(), same(parent.entity));
    expect(fixture.connection.selects, 0);
    expect(await parent.collection(fixture.relation).load(), [child.entity]);
    expect(await fixture.context.saveChanges(), 2);
    expect(parent.entity.id, isNotNull);
    expect(child.entity.id, isNotNull);
    expect(child.entity.parentId, parent.entity.id);
    expect(child.state, EntityState.unchanged);
    expect((await fixture.database.query('PRAGMA foreign_key_check')).rows,
        isEmpty);
  });

  test('failed related batch publishes no provisional keys or FK values',
      () async {
    final fixture = await _fixture();
    await fixture.database
        .execute("INSERT INTO children VALUES(1,NULL,'duplicate')");
    final child = fixture.context.set(_childType).add(_Child('duplicate'));
    final parent = fixture.context.set(_parentType).add(_Parent('parent'));
    child.reference(fixture.relation).set(parent);
    await expectLater(
        fixture.context.saveChanges(), throwsA(isA<SqlException>()));
    expect(parent.entity.id, isNull);
    expect(child.entity.id, isNull);
    expect(child.entity.parentId, isNull);
    expect(parent.state, EntityState.added);
    expect(child.state, EntityState.added);
    expect(
        (await fixture.database.query('SELECT * FROM parents')).rows, isEmpty);
    child.entity.label = 'fixed';
    await fixture.context.saveChanges();
    expect(child.entity.parentId, parent.entity.id);
  });

  test('optional collection remove clears FK only after successful save',
      () async {
    final fixture = await _fixture();
    await fixture.database.execute("INSERT INTO parents VALUES(1,'parent')");
    await fixture.database.execute("INSERT INTO children VALUES(1,1,'child')");
    final parent =
        (await fixture.context.set(_parentType).find(EntityKey([1])))!;
    final child = (await fixture.context
            .entry(parent)
            .collection(fixture.relation)
            .load())
        .single;
    fixture.context
        .entry(parent)
        .collection(fixture.relation)
        .remove(fixture.context.entry(child));
    expect(
        await fixture.context.entry(child).reference(fixture.relation).load(),
        isNull);
    expect(child.parentId, BigInt.one);
    await fixture.context.saveChanges();
    expect(child.parentId, isNull);
    expect(
        (await fixture.context
            .entry(parent)
            .collection(fixture.relation)
            .load()),
        isEmpty);
  });

  test('links reject cross-context entries and subsequent direct FK divergence',
      () async {
    final first = await _fixture();
    final second = await _fixture();
    final child = first.context.set(_childType).add(_Child('child'));
    final parent = first.context.set(_parentType).add(_Parent('parent'));
    final foreign = second.context.set(_parentType).add(_Parent('foreign'));
    expect(() => child.reference(first.relation).set(foreign),
        throwsA(isA<OrmStateException>()));
    child.reference(first.relation).set(parent);
    child.entity.parentId = BigInt.from(9);
    await expectLater(child.reference(first.relation).load(),
        throwsA(isA<OrmStateException>()));
    await expectLater(
        first.context.saveChanges(), throwsA(isA<OrmStateException>()));
    child.entity.parentId = null;
    await first.context.saveChanges();
    expect(child.entity.parentId, parent.entity.id);
  });

  test('composite references preserve large integers, blobs and partial nulls',
      () async {
    final fixture = await _compositeFixture();
    final tenant = BigInt.parse('9223372036854775807');
    await fixture.database.execute(
        'INSERT INTO composite_parents VALUES(?,?,?),(?,?,?),(?,?,?)', [
      tenant,
      Uint8List.fromList([0, 255]),
      'first',
      tenant,
      Uint8List.fromList([255, 0]),
      'second',
      BigInt.one,
      Uint8List(0),
      'empty'
    ]);
    await fixture.database.execute(
        'INSERT INTO composite_children VALUES(?,?,?),(?,?,?),(?,?,?)', [
      BigInt.one,
      tenant,
      Uint8List.fromList([0, 255]),
      BigInt.two,
      tenant,
      Uint8List.fromList([255, 0]),
      BigInt.from(3),
      tenant,
      null
    ]);
    final children = await fixture.context.set(fixture.child).query.toList();
    final entries = children.map(fixture.context.entry).toList();
    final loaded =
        await fixture.context.loadReferences(fixture.relationship, entries);
    expect(loaded[entries[0]]!.name, 'first');
    expect(loaded[entries[1]]!.name, 'second');
    expect(loaded[entries[2]], isNull);
    final first = (await fixture.context.set(fixture.parent).find(EntityKey([
          tenant,
          Uint8List.fromList([0, 255])
        ])))!;
    expect(loaded[entries[0]], same(first));
    final parents = await fixture.context.set(fixture.parent).query.toList();
    final collections = await fixture.context.loadCollections(
        fixture.relationship, parents.map(fixture.context.entry));
    expect(
        collections[fixture.context.entry(first)]!.single, same(children[0]));
    final empty = parents.singleWhere((parent) => parent.name == 'empty');
    expect(collections[fixture.context.entry(empty)], isEmpty);
    final linked = fixture.context
        .set(fixture.child)
        .add(_CompositeChild(BigInt.from(4), null, null));
    linked.reference(fixture.relationship).set(fixture.context.entry(first));
    await fixture.context.saveChanges();
    expect(linked.entity.tenant, tenant);
    expect(linked.entity.token, orderedEquals([0, 255]));
    expect(linked.entity.token, isNot(same(first.token)));
  });

  test('mixed-nullability composite optional link clears nullable components',
      () async {
    final fixture = await _compositeFixture(mixedNullability: true);
    await fixture.database
        .execute("INSERT INTO composite_parents VALUES(1,x'05','parent')");
    await fixture.database
        .execute("INSERT INTO composite_children VALUES(1,1,x'05')");
    final parent = (await fixture.context.set(fixture.parent).find(EntityKey([
          1,
          Uint8List.fromList([5])
        ])));
    final child =
        (await fixture.context.set(fixture.child).find(EntityKey([1])))!;
    final entry = fixture.context.entry(child);
    expect(await entry.reference(fixture.relationship).load(), same(parent));
    entry.reference(fixture.relationship).set(null);
    expect(await entry.reference(fixture.relationship).load(), isNull);
    expect(child.token, orderedEquals([5]));
    await fixture.context.saveChanges();
    expect(child.tenant, BigInt.one);
    expect(child.token, isNull);
    expect(entry.state, EntityState.unchanged);
    expect((await fixture.database.query('PRAGMA foreign_key_check')).rows,
        isEmpty);
  });

  test('empty batches and duplicate entries have stable immutable results',
      () async {
    final fixture = await _fixture();
    final child = fixture.context.set(_childType).add(_Child('pending'));
    final parent = fixture.context.set(_parentType).add(_Parent('pending'));
    child.reference(fixture.relation).set(parent);
    fixture.connection.selects = 0;
    expect(
        await fixture.context
            .loadReferences(fixture.relation, <EntityEntry<_Child>>[]),
        isEmpty);
    expect(
        await fixture.context
            .loadCollections(fixture.relation, <EntityEntry<_Parent>>[]),
        isEmpty);
    final references =
        await fixture.context.loadReferences(fixture.relation, [child, child]);
    expect(references.length, 1);
    expect(references[child], same(parent.entity));
    expect(() => references.clear(), throwsUnsupportedError);
    final collections = await fixture.context
        .loadCollections(fixture.relation, [parent, parent]);
    expect(collections.length, 1);
    expect(collections[parent], [child.entity]);
    expect(fixture.connection.selects, 0);
  });

  test('relationship operations reject unregistered and inactive entries',
      () async {
    final fixture = await _fixture();
    final child = fixture.context.set(_childType).add(_Child('pending'));
    final parent = fixture.context.set(_parentType).add(_Parent('pending'));
    final unregistered = ForeignKey<_Child, _Parent>(
        name: 'other',
        child: _childType,
        parent: _parentType,
        columns: [_childParent],
        targetColumns: [_parentId]);
    expect(() => child.reference(unregistered),
        throwsA(isA<OrmMappingException>()));
    final collection = parent.collection(fixture.relation);
    collection.add(child);
    fixture.context.set(_parentType).remove(parent.entity);
    expect(() => collection.remove(child), throwsA(isA<OrmStateException>()));
    await expectLater(collection.load(), throwsA(isA<OrmStateException>()));
    await expectLater(child.reference(fixture.relation).load(),
        throwsA(isA<OrmStateException>()));
  });

  test('relink during commit retains the next intended relationship', () async {
    final fixture = await _fixture();
    final first = fixture.context.set(_parentType).add(_Parent('first'));
    final second = fixture.context.set(_parentType).add(_Parent('second'));
    final child = fixture.context.set(_childType).add(_Child('child'));
    child.reference(fixture.relation).set(first);
    fixture.connection.pauseCommit();
    final save = fixture.context.saveChanges();
    await fixture.connection.commitReached!.future;
    child.reference(fixture.relation).set(second);
    fixture.connection.resumeCommit!.complete();
    await save;
    expect(child.entity.parentId, first.entity.id);
    expect(child.state, EntityState.modified);
    expect(await child.reference(fixture.relation).load(), same(second.entity));
    await fixture.context.saveChanges();
    expect(child.entity.parentId, second.entity.id);
    expect(child.state, EntityState.unchanged);
    expect(
        (await fixture.database.query('SELECT parentId FROM children'))
            .rows
            .single
            .single,
        second.entity.id);
  });

  for (final deferred in [false, true]) {
    test(
        'known-key cycle ${deferred ? 'accepts deferred' : 'rejects immediate'} '
        'constraints', () async {
      final (database, connection, context, type, relation) =
          await _cycleFixture(deferred: deferred);
      final first = context.set(type).add(_Node('first', id: BigInt.one));
      final second = context.set(type).add(_Node('second', id: BigInt.two));
      first.reference(relation).set(second);
      second.reference(relation).set(first);
      connection.executions = 0;
      if (deferred) {
        expect(await context.saveChanges(), 2);
        expect(first.entity.nextId, second.entity.id);
        expect(second.entity.nextId, first.entity.id);
        expect(
            (await database.query('PRAGMA foreign_key_check')).rows, isEmpty);
      } else {
        await expectLater(
            context.saveChanges(), throwsA(isA<OrmStateException>()));
        expect(connection.executions, 0);
        expect((await database.query('SELECT * FROM nodes')).rows, isEmpty);
      }
    });
  }

  test('known deferred cycle saves before its generated downstream dependent',
      () async {
    final (database, _, context, type, relation) =
        await _cycleFixture(deferred: true);
    final dependent = context.set(type).add(_Node('dependent'));
    final first = context.set(type).add(_Node('first', id: BigInt.one));
    final second = context.set(type).add(_Node('second', id: BigInt.two));
    dependent.reference(relation).set(first);
    first.reference(relation).set(second);
    second.reference(relation).set(first);
    expect(await context.saveChanges(), 3);
    expect(dependent.entity.id, isNotNull);
    expect(dependent.entity.nextId, first.entity.id);
    expect((await database.query('PRAGMA foreign_key_check')).rows, isEmpty);
  });

  test('ordinary updates in an existing immediate cycle need no deferred keys',
      () async {
    final (database, _, context, type, _) =
        await _cycleFixture(deferred: false);
    await database
        .execute("INSERT INTO nodes VALUES(1,2,'first'),(2,1,'second')");
    final first = (await context.set(type).find(EntityKey([1])))!;
    final second = (await context.set(type).find(EntityKey([2])))!;
    first.name = 'updated first';
    second.name = 'updated second';
    expect(await context.saveChanges(), 2);
    expect((await database.query('SELECT name FROM nodes ORDER BY id')).rows, [
      ['updated first'],
      ['updated second']
    ]);
  });

  test('cyclic cascades detach every explicitly deleted tracked row', () async {
    final (database, _, context, type, relation) =
        await _cycleFixture(deferred: true, onDelete: ForeignKeyAction.cascade);
    final first = context.set(type).add(_Node('first', id: BigInt.one));
    final second = context.set(type).add(_Node('second', id: BigInt.two));
    first.reference(relation).set(second);
    second.reference(relation).set(first);
    await context.saveChanges();
    context.set(type).remove(first.entity);
    context.set(type).remove(second.entity);
    expect(await context.saveChanges(), 2);
    expect(first.state, EntityState.detached);
    expect(second.state, EntityState.detached);
    expect((await database.query('SELECT * FROM nodes')).rows, isEmpty);
  });

  test('generated-key cycle is rejected before SQL even when deferred',
      () async {
    final (database, connection, context, type, relation) =
        await _cycleFixture(deferred: true);
    final first = context.set(type).add(_Node('first'));
    final second = context.set(type).add(_Node('second'));
    first.reference(relation).set(second);
    second.reference(relation).set(first);
    connection.executions = 0;
    await expectLater(context.saveChanges(), throwsA(isA<OrmStateException>()));
    expect(connection.executions, 0);
    expect(first.entity.id, isNull);
    expect(second.entity.id, isNull);
    expect((await database.query('SELECT * FROM nodes')).rows, isEmpty);
  });

  test('tracked children delete before parents regardless of remove order',
      () async {
    final fixture = await _fixture();
    await fixture.database.execute("INSERT INTO parents VALUES(1,'parent')");
    await fixture.database.execute("INSERT INTO children VALUES(1,1,'child')");
    final parent =
        (await fixture.context.set(_parentType).find(EntityKey([1])))!;
    final child = (await fixture.context.set(_childType).find(EntityKey([1])))!;
    final parentEntry = fixture.context.entry(parent);
    final childEntry = fixture.context.entry(child);
    fixture.context.set(_parentType).remove(parent);
    fixture.context.set(_childType).remove(child);
    expect(await fixture.context.saveChanges(), 2);
    expect(parentEntry.state, EntityState.detached);
    expect(childEntry.state, EntityState.detached);
    expect(
        (await fixture.database.query('SELECT * FROM parents')).rows, isEmpty);
    expect(
        (await fixture.database.query('SELECT * FROM children')).rows, isEmpty);
  });

  test('SET NULL refresh preserves edits made while commit waits', () async {
    final fixture = await _fixture(onDelete: ForeignKeyAction.setNull);
    await fixture.database.execute("INSERT INTO parents VALUES(1,'parent')");
    await fixture.database.execute("INSERT INTO children VALUES(1,1,'child')");
    final parent =
        (await fixture.context.set(_parentType).find(EntityKey([1])))!;
    final child = (await fixture.context.set(_childType).find(EntityKey([1])))!;
    final childEntry = fixture.context.entry(child);
    fixture.context.set(_parentType).remove(parent);
    fixture.connection.pauseCommit();
    final save = fixture.context.saveChanges();
    await fixture.connection.commitReached!.future;
    expect(child.parentId, BigInt.one);
    child.label = 'edited during commit';
    fixture.connection.resumeCommit!.complete();
    await save;
    expect(child.parentId, isNull);
    expect(child.label, 'edited during commit');
    expect(childEntry.state, EntityState.modified);
    await fixture.context.saveChanges();
    expect(childEntry.state, EntityState.unchanged);
  });

  for (final action in [ForeignKeyAction.cascade, ForeignKeyAction.setNull]) {
    test('${action.name} refresh is discarded when deferred commit fails',
        () async {
      final fixture = await _fixture(onDelete: action);
      await fixture.database.execute("INSERT INTO parents VALUES(1,'parent')");
      await fixture.database
          .execute("INSERT INTO children VALUES(1,1,'child')");
      await fixture.database.execute('CREATE TABLE guards('
          'parentId INTEGER REFERENCES parents(id) DEFERRABLE INITIALLY DEFERRED)');
      await fixture.database.execute('INSERT INTO guards VALUES(1)');
      final parent =
          (await fixture.context.set(_parentType).find(EntityKey([1])))!;
      final child =
          (await fixture.context.set(_childType).find(EntityKey([1])))!;
      final parentEntry = fixture.context.entry(parent);
      final childEntry = fixture.context.entry(child);
      fixture.context.set(_parentType).remove(parent);
      await expectLater(
          fixture.context.saveChanges(), throwsA(isA<SqlException>()));
      expect(parentEntry.state, EntityState.deleted);
      expect(childEntry.state, EntityState.unchanged);
      expect(child.parentId, BigInt.one);
      expect(
          (await fixture.database.query('SELECT parentId FROM children'))
              .rows
              .single
              .single,
          BigInt.one);
      expect((await fixture.database.query('SELECT * FROM parents')).rows,
          hasLength(1));
      await fixture.database.execute('DELETE FROM guards');
      await fixture.context.saveChanges();
      expect(parentEntry.state, EntityState.detached);
      if (action == ForeignKeyAction.cascade) {
        expect(childEntry.state, EntityState.detached);
      } else {
        expect(childEntry.state, EntityState.unchanged);
        expect(child.parentId, isNull);
      }
    });

    test('modified child reconciles with ${action.name} after parent deletion',
        () async {
      final fixture = await _fixture(onDelete: action);
      await fixture.database.execute("INSERT INTO parents VALUES(1,'parent')");
      await fixture.database
          .execute("INSERT INTO children VALUES(1,1,'child')");
      final parent =
          (await fixture.context.set(_parentType).find(EntityKey([1])))!;
      final child =
          (await fixture.context.set(_childType).find(EntityKey([1])))!;
      final childEntry = fixture.context.entry(child);
      child.label = 'saved change';
      fixture.context.set(_parentType).remove(parent);
      expect(await fixture.context.saveChanges(), 2);
      if (action == ForeignKeyAction.cascade) {
        expect(childEntry.state, EntityState.detached);
        expect((await fixture.database.query('SELECT * FROM children')).rows,
            isEmpty);
      } else {
        expect(childEntry.state, EntityState.unchanged);
        expect(child.parentId, isNull);
        expect(child.label, 'saved change');
      }
    });

    test('tracked children refresh after ${action.name} parent deletion',
        () async {
      final fixture = await _fixture(onDelete: action);
      await fixture.database.execute("INSERT INTO parents VALUES(1,'parent')");
      await fixture.database
          .execute("INSERT INTO children VALUES(1,1,'child')");
      final parent =
          (await fixture.context.set(_parentType).find(EntityKey([1])))!;
      final child = (await fixture.context
              .entry(parent)
              .collection(fixture.relation)
              .load())
          .single;
      final childEntry = fixture.context.entry(child);
      fixture.context.set(_parentType).remove(parent);
      await fixture.context.saveChanges();
      if (action == ForeignKeyAction.cascade) {
        expect(childEntry.state, EntityState.detached);
        expect((await fixture.database.query('SELECT * FROM children')).rows,
            isEmpty);
      } else {
        expect(childEntry.state, EntityState.unchanged);
        expect(childEntry.entity.parentId, isNull);
        expect(await childEntry.reference(fixture.relation).load(), isNull);
      }
    });
  }
}
