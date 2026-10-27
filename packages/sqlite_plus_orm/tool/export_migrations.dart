// Development-only native cross-open driver; the ORM runtime does not use IO.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite_plus/sqlite_plus.dart' hide ForeignKey;
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

Object? _encode(Object? value) {
  if (value is BigInt) return {'integer': value.toString()};
  if (value is Uint8List) {
    return {
      'blob': value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()
    };
  }
  return value;
}

class _Row {
  _Row(this.values);
  final Map<String, Object?> values;
}

class _Mappings {
  _Mappings(
      {String label = 'label',
      bool integerLabel = false,
      bool unique = false,
      bool note = false}) {
    final a = Column<_Row, BigInt>(
        property: 'a',
        codec: Codecs.bigInt,
        keyOrder: 5,
        read: (row) => row.values['a'] as BigInt);
    final b = Column<_Row, String>(
        property: 'b',
        codec: Codecs.text,
        keyOrder: 10,
        read: (row) => row.values['b'] as String);
    parent = EntityType<_Row>(
        tableName: 'parent',
        columns: [a, b],
        create: (row) => _Row({'a': row.read(a), 'b': row.read(b)}));
    final id = Column<_Row, BigInt?>(
        property: 'id',
        codec: Codecs.nullable(Codecs.bigInt),
        keyOrder: 0,
        generated: true,
        read: (row) => row.values['id'] as BigInt?);
    final pa = Column<_Row, BigInt?>(
        property: 'pa',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (row) => row.values['pa'] as BigInt?);
    final pb = Column<_Row, String?>(
        property: 'pb',
        codec: Codecs.nullable(Codecs.text),
        read: (row) => row.values['pb'] as String?);
    final value = Column<_Row, dynamic>(
        property: label,
        codec: integerLabel
            ? Codecs.nullable(Codecs.bigInt)
            : Codecs.nullable(Codecs.text),
        read: (row) => row.values[label]);
    final extra = Column<_Row, String?>(
        property: 'note',
        codec: Codecs.nullable(Codecs.text),
        read: (row) => row.values['note'] as String?);
    child = EntityType<_Row>(
        tableName: 'child',
        columns: [id, pa, pb, value, if (note) extra],
        indexes: [
          OrmIndex<_Row>(name: 'child_label', columns: [value], unique: unique),
          if (note) OrmIndex<_Row>(name: 'child_note', columns: [extra])
        ],
        create: (row) => _Row({
              'id': row.read(id),
              'pa': row.read(pa),
              'pb': row.read(pb),
              label: row.read(value),
              if (note) 'note': row.read(extra)
            }));
    final relation = ForeignKey<_Row, _Row>(
        name: 'child_parent',
        child: child,
        parent: parent,
        columns: [pa, pb],
        targetColumns: [a, b],
        onDelete: ForeignKeyAction.setNull,
        onUpdate: ForeignKeyAction.cascade,
        deferred: true);
    model = DbModel([child, parent], foreignKeys: [relation]);
  }
  late final EntityType<_Row> parent, child;
  late final DbModel model;
}

class _LoggedConnection extends OrmConnection {
  _LoggedConnection(this.inner);
  final OrmConnection inner;
  final List<Map<String, Object?>> operations = [];
  @override
  bool get inTransaction => inner.inTransaction;
  @override
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      inner.query(sql, parameters);
  @override
  Future<MutationResult> execute(String sql,
      [List<Object?> parameters = const []]) async {
    final operation = <String, Object?>{
      'sql': sql,
      'parameters': parameters.map(_encode).toList(),
      'error': false
    };
    operations.add(operation);
    try {
      return await inner.execute(sql, parameters);
    } catch (_) {
      operation['error'] = true;
      rethrow;
    }
  }

  @override
  Future<void> close() => inner.close();
}

Future<void> main(List<String> arguments) async {
  final directory = Directory(arguments[0])..createSync(recursive: true);
  final encoding = int.parse(arguments[1]);
  final engine = await MutableSqliteDatabase.create(encoding: encoding);
  final connection = _LoggedConnection(MutableDatabaseConnection(engine));
  final snapshots = <Object?>[];
  Future<void> snapshot(String name) async {
    final queries = <Object?>[];
    for (final sql in [
      'SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name',
      'SELECT * FROM parent ORDER BY a,b',
      'SELECT * FROM child ORDER BY id',
      "PRAGMA table_info('parent')",
      "PRAGMA table_info('child')",
      "PRAGMA index_list('child')",
      "PRAGMA index_xinfo('child_label')",
      "PRAGMA foreign_key_list('child')",
      'SELECT id,format,version FROM _sqlite_plus_orm_model',
    ]) {
      final result = await engine.query(sql);
      queries.add({
        'sql': sql,
        'columns': result.columns,
        'rows': [for (final row in result.rows) row.map(_encode).toList()]
      });
    }
    final file = 'migration_${snapshots.length}.db';
    File('${directory.path}/$file').writeAsBytesSync(engine.exportImage());
    snapshots.add({
      'name': name,
      'file': file,
      'operations': List.of(connection.operations),
      'queries': queries
    });
    connection.operations.clear();
  }

  try {
    await SchemaMigrator(connection, _Mappings().model).ensureCreated();
    await snapshot('create composite schema');
    await connection.execute('INSERT INTO parent VALUES(1,\'key\')');
    await connection
        .execute('INSERT INTO child(pa,pb,label) VALUES(1,\'key\',\'42\')');
    await snapshot('seed rows');
    final rename = SchemaMigrator(connection, _Mappings(label: 'title').model);
    final renamePlan = (await rename.plan()).withOperations([
      MigrationOperation.sql('ALTER TABLE child RENAME COLUMN label TO title',
          reason: 'Reviewed exact label rename'),
    ]);
    await rename.apply(renamePlan,
        approval: MigrationApproval.forPlan(renamePlan));
    await snapshot('reviewed column rename');
    final rebuild = SchemaMigrator(
        connection, _Mappings(label: 'title', integerLabel: true).model);
    final rebuilt = (await rebuild.plan()).withOperations([
      MigrationOperation.sql(
          'CREATE TABLE child_new(id INTEGER PRIMARY KEY,pa INTEGER,pb TEXT,title INTEGER,'
          'CONSTRAINT child_parent FOREIGN KEY(pa,pb) REFERENCES parent(a,b) '
          'ON UPDATE CASCADE ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED)',
          reason: 'Reviewed target schema'),
      MigrationOperation.sql(
          'INSERT INTO child_new(id,pa,pb,title) SELECT id,pa,pb,CAST(title AS INTEGER) FROM child',
          reason: 'Explicit source-to-target value mapping'),
      MigrationOperation.sql('DROP TABLE child',
          reason: 'Replace copied source table'),
      MigrationOperation.sql('ALTER TABLE child_new RENAME TO child',
          reason: 'Publish rebuilt child'),
      MigrationOperation.sql('CREATE INDEX child_label ON child(title)',
          reason: 'Restore target index'),
    ]);
    await rebuild.apply(rebuilt, approval: MigrationApproval.forPlan(rebuilt));
    await snapshot('reviewed mapped rebuild');
    final invalid = (await rebuild.plan()).withOperations([
      MigrationOperation.sql(
          'INSERT INTO child VALUES(999,999,\'missing\',NULL)',
          reason: 'Deliberately invalid deferred foreign key'),
      MigrationOperation.sql('CREATE TABLE incidental(v)',
          reason: 'Must roll back with invalid child'),
    ]);
    try {
      await rebuild.apply(invalid,
          approval: MigrationApproval.forPlan(invalid));
      throw StateError('Invalid migration unexpectedly committed');
    } on MigrationRequiredException {
      await snapshot('failed foreign key mapping rolls back');
    }
    final unique = SchemaMigrator(connection,
        _Mappings(label: 'title', integerLabel: true, unique: true).model);
    final uniquePlan = await unique.plan();
    await unique.apply(uniquePlan,
        approval: MigrationApproval.forPlan(uniquePlan));
    await snapshot('reviewed unique index replacement');
    await SchemaMigrator(
            connection,
            _Mappings(
                    label: 'title',
                    integerLabel: true,
                    unique: true,
                    note: true)
                .model)
        .ensureCreated();
    await snapshot('safe nullable column and index');
    File('${directory.path}/migrations.json').writeAsStringSync(
        jsonEncode({'encoding': encoding, 'snapshots': snapshots}));
  } finally {
    await engine.close();
  }
}
