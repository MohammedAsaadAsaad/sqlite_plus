import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class _Note {
  _Note(this.id, this.body);
  final BigInt id;
  String body;
}

final _id = Column<_Note, BigInt>(
  property: 'id',
  codec: Codecs.bigInt,
  read: (note) => note.id,
  keyOrder: 0,
);
final _body = Column<_Note, String>(
  property: 'body',
  codec: Codecs.text,
  read: (note) => note.body,
  write: (note, value) => note.body = value,
);
final _type = EntityType<_Note>(
  tableName: 'notes',
  columns: [_id, _body],
  create: (row) => _Note(row.read(_id), row.read(_body)),
);

void main() {
  test('openMemory creates the table and save stays on that set', () async {
    final notes = await DbSet.openMemory(_type);
    notes.add(_Note(BigInt.one, 'kept'));
    expect(await notes.saveChanges(), 1);
    final stored = await notes.query.where(_body.eq('kept')).single();
    expect(stored.body, 'kept');
    expect((await notes.migrations.plan()).isEmpty, isTrue);
    final tables = await notes.context.connection.query(
      "SELECT name FROM sqlite_schema WHERE type = 'table' AND name = 'notes'",
    );
    expect(tables.rows, hasLength(1));
    await notes.close();
    expect(notes.saveChanges(), throwsA(isA<OrmStateException>()));
  });

  test('openMemory closes the database when creating the table fails',
      () async {
    final body = Column<_Note, String>(
      property: 'body',
      codec: Codecs.text,
      read: (note) => note.body,
      write: (note, value) => note.body = value,
      defaultSql: 'not valid',
    );
    expect(
      DbSet.openMemory(
        EntityType<_Note>(
          tableName: 'notes',
          columns: [_id, body],
          create: (row) => _Note(row.read(_id), row.read(body)),
        ),
      ),
      throwsA(isA<Exception>()),
    );
  });
}
