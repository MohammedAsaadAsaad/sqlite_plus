import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class _Note {
  _Note(this.id, this.body);
  final BigInt id;
  final String body;
}

final class _NoteMapping {
  _NoteMapping() {
    id = Column(
        property: 'id',
        name: 'id',
        codec: Codecs.bigInt,
        read: (note) => note.id,
        keyOrder: 0);
    body = Column(
        property: 'body',
        name: 'body',
        codec: Codecs.text,
        read: (note) => note.body);
    type = EntityType(
        tableName: 'notes',
        columns: [id, body],
        create: (row) => _Note(row.read(id), row.read(body)));
  }

  late final Column<_Note, BigInt> id;
  late final Column<_Note, String> body;
  late final EntityType<_Note> type;
}

void main() {
  test('callers compare a JSON field without writing SQL', () async {
    final mapping = _NoteMapping();
    final fields = (
      id: MappedField(mapping.id),
      body: MappedField(mapping.body),
    );
    final db = await MutableSqliteDatabase.create();
    addTearDown(db.close);
    final connection = MutableDatabaseConnection(db);
    await db.execute('CREATE TABLE ${quoteIdentifier(mapping.type.tableName)}('
        '${quoteIdentifier(mapping.id.sqlName)} INTEGER PRIMARY KEY, '
        '${quoteIdentifier(mapping.body.sqlName)} TEXT)');
    await db.execute('INSERT INTO notes(id, body) VALUES(1, ?), (2, ?), (3, ?)',
        ['{"a":1,"b":"x"}', '{"a":2,"b":"y"}', '{"b":"z"}']);
    final query = TypedQuery(type: mapping.type, connection: connection);
    final ones = await query.where(fields.body.at(r'$.a').equalTo(1)).toList();
    final missing =
        await query.where(fields.body.at(r'$.a').equalTo(null)).toList();
    final letters =
        await query.where(fields.body.at(r'$.b').equalTo('y')).toList();
    expect(ones.map((note) => note.id), [BigInt.one]);
    expect(missing.map((note) => note.id), [BigInt.from(3)]);
    expect(letters.map((note) => note.body), ['{"a":2,"b":"y"}']);
  });

  test('a JSON path comparison binds the path', () {
    final mapping = _NoteMapping();
    final body = MappedField(mapping.body);
    final db = _UnusedConnection();
    final query = TypedQuery(type: mapping.type, connection: db)
        .where(body.at(r'$.a').equalTo(1))
        .where(body.at(r'$.missing').equalTo(null));
    final command = query.toSql();
    expect(command.sql, contains('json_extract("body", ?) = ?'));
    expect(command.sql, contains('json_extract("body", ?) IS NULL'));
    expect(command.sql.contains(r'$.a'), isFalse);
    expect(command.sql.contains(r'$.missing'), isFalse);
    expect(command.parameters, [r'$.a', BigInt.one, r'$.missing']);
  });
}

final class _UnusedConnection extends OrmConnection {
  @override
  bool get inTransaction => false;
  @override
  Future<QueryResult> query(String sql,
          [List<Object?> parameters = const []]) =>
      throw UnimplementedError();
  @override
  Future<MutationResult> execute(String sql,
          [List<Object?> parameters = const []]) =>
      throw UnimplementedError();
  @override
  Future<void> close() async {}
}
