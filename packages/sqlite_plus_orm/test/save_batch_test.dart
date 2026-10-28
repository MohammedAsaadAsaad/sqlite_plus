import 'package:sqlite_plus/sqlite_plus.dart'
    show MutableSqliteDatabase, MutationResult, QueryResult, SqlException;
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

class _Row {
  _Row(this.name, {this.id});
  BigInt? id;
  String name;
}

final _id = Column<_Row, BigInt?>(
    property: 'id',
    codec: Codecs.nullable(Codecs.bigInt),
    read: (entity) => entity.id,
    write: (entity, value) => entity.id = value,
    keyOrder: 0,
    generated: true);
final _name = Column<_Row, String>(
    property: 'name',
    codec: Codecs.text,
    read: (entity) => entity.name,
    write: (entity, value) => entity.name = value);
final _type = EntityType<_Row>(
    tableName: 'rows',
    columns: [_id, _name],
    create: (row) => _Row(row.read(_name), id: row.read(_id)));

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
    write: (entity, value) => entity.name = value);
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
    write: (entity, value) => entity.label = value);
final _childType = EntityType<_Child>(
    tableName: 'children',
    columns: [_childId, _childParent, _childLabel],
    create: (row) => _Child(row.read(_childLabel),
        id: row.read(_childId), parentId: row.read(_childParent)));

class _CountingConnection extends OrmConnection {
  _CountingConnection(MutableSqliteDatabase database)
      : inner = MutableDatabaseConnection(database, closeDatabase: true);
  final MutableDatabaseConnection inner;
  final List<String> statements = [];

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
    statements.add(sql);
    return inner.query(sql, parameters);
  }

  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) {
    statements.add(sql);
    return inner.execute(sql, parameters);
  }

  @override
  Future<void> close() => inner.close();
}

Future<(DbContext, _CountingConnection)> _open() async {
  final database = await MutableSqliteDatabase.create();
  await database.execute(
      'CREATE TABLE rows(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)');
  final connection = _CountingConnection(database);
  final context = DbContext(connection, DbModel([_type]));
  return (context, connection);
}

void main() {
  test('one save inserts a batch with one INSERT and publishes keys in order',
      () async {
    final (context, connection) = await _open();
    addTearDown(context.close);
    const count = 1000;
    final rows = [for (var i = 0; i < count; i++) _Row('row $i')];
    final set = context.set(_type);
    for (final row in rows) {
      set.add(row);
    }
    connection.statements.clear();
    final watch = Stopwatch()..start();
    expect(await context.saveChanges(), count);
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(10000));
    final inserts = connection.statements
        .where((sql) => sql.toUpperCase().startsWith('INSERT'));
    expect(inserts, hasLength(1));
    expect(connection.statements.where((sql) => sql.contains('sqlite_schema')),
        hasLength(1));
    expect(
        connection.statements
            .where((sql) => sql.toUpperCase().startsWith('SELECT "')),
        isEmpty);
    for (var i = 0; i < count; i++) {
      expect(rows[i].id, BigInt.from(i + 1));
      expect(rows[i].name, 'row $i');
    }
    expect(await context.saveChanges(), 0);
    final stored = await set.query.orderBy([_id.asc()]).toList();
    expect(stored, hasLength(count));
    expect(stored.first.name, 'row 0');
    expect(stored.last.id, BigInt.from(count));
  });

  test('a unique failure in a batched insert publishes no keys', () async {
    final (context, connection) = await _open();
    addTearDown(context.close);
    final first = _Row('same');
    final second = _Row('same');
    context.set(_type)
      ..add(first)
      ..add(second);
    connection.statements.clear();
    await expectLater(context.saveChanges(), throwsA(isA<SqlException>()));
    expect(first.id, isNull);
    expect(second.id, isNull);
    expect(await context.set(_type).query.count(), BigInt.zero);
  });

  test('parent keys generated in the same save reach child rows', () async {
    final database = await MutableSqliteDatabase.create();
    await database.execute(
        'CREATE TABLE parents(id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
    await database.execute('CREATE TABLE children(id INTEGER PRIMARY KEY, '
        'parentId INTEGER REFERENCES parents(id), label TEXT NOT NULL)');
    final relation = ForeignKey<_Child, _Parent>(
        name: 'parent',
        child: _childType,
        parent: _parentType,
        columns: [_childParent],
        targetColumns: [_parentId]);
    final connection = _CountingConnection(database);
    final context = DbContext(connection,
        DbModel([_parentType, _childType], foreignKeys: [relation]));
    addTearDown(context.close);
    final parents = [_Parent('ada'), _Parent('grace')];
    final parentSet = context.set(_parentType);
    final entries = [for (final parent in parents) parentSet.add(parent)];
    final children = [_Child('one'), _Child('two'), _Child('three')];
    final childSet = context.set(_childType);
    for (final child in children) {
      childSet.add(child);
    }
    entries[0].collection(relation).add(context.entry(children[0]));
    entries[0].collection(relation).add(context.entry(children[1]));
    entries[1].collection(relation).add(context.entry(children[2]));
    expect(await context.saveChanges(), 5);
    expect(children.map((child) => child.parentId),
        [parents[0].id, parents[0].id, parents[1].id]);
    expect(parents.every((parent) => parent.id != null), isTrue);
    final inserts = connection.statements
        .where((sql) => sql.toUpperCase().startsWith('INSERT'));
    expect(inserts, hasLength(2));
  });

  test('one save deletes a batch with one DELETE', () async {
    final (context, connection) = await _open();
    addTearDown(context.close);
    const count = 1000;
    final set = context.set(_type);
    for (var i = 0; i < count; i++) {
      set.add(_Row('row $i'));
    }
    expect(await context.saveChanges(), count);
    final stored = await set.query.toList();
    for (final row in stored) {
      set.remove(row);
    }
    connection.statements.clear();
    final watch = Stopwatch()..start();
    expect(await context.saveChanges(), count);
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(10000));
    final deletes = connection.statements
        .where((sql) => sql.toUpperCase().startsWith('DELETE'));
    expect(deletes, hasLength(1));
    expect(deletes.single.toUpperCase(), isNot(contains(' WHERE ')));
    expect(await set.query.count(), BigInt.zero);
  });

  test('a partial delete uses one IN list', () async {
    final (context, connection) = await _open();
    addTearDown(context.close);
    final set = context.set(_type);
    for (var i = 0; i < 4; i++) {
      set.add(_Row('row $i'));
    }
    expect(await context.saveChanges(), 4);
    final stored = await set.query.toList();
    set.remove(stored[0]);
    set.remove(stored[1]);
    connection.statements.clear();
    expect(await context.saveChanges(), 2);
    final deletes = connection.statements
        .where((sql) => sql.toUpperCase().startsWith('DELETE'));
    expect(deletes, hasLength(1));
    expect(deletes.single.toUpperCase(), contains(' IN ('));
    expect(await set.query.count(), BigInt.two);
  });

  test('separate one-row saves stay within one image rebuild', () async {
    final (context, connection) = await _open();
    addTearDown(context.close);
    const count = 100;
    final set = context.set(_type);
    final watch = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      set.add(_Row('row $i'));
      expect(await context.saveChanges(), 1);
    }
    watch.stop();
    expect(watch.elapsedMilliseconds, lessThan(15000));
    expect(connection.statements.where((sql) => sql.startsWith('INSERT')),
        hasLength(count));
    final stored = await set.query.orderBy([_id.asc()]).toList();
    expect(stored, hasLength(count));
    expect(stored.last.name, 'row ${count - 1}');
  });

  test('an AFTER trigger still replaces the returned insert values', () async {
    final (context, _) = await _open();
    addTearDown(context.close);
    await context.connection.execute('CREATE TRIGGER upper_name AFTER INSERT '
        'ON rows BEGIN UPDATE rows SET name=UPPER(NEW.name) WHERE id=NEW.id; END');
    final row = context.set(_type).add(_Row('lower'));
    expect(await context.saveChanges(), 1);
    expect(row.entity.name, 'LOWER');
    expect(row.originalValues['name'], 'LOWER');
  });
}
