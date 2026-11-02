import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:test/test.dart';

final class _Book {
  _Book({this.id, required this.revision, required this.title, this.note});
  final BigInt? id;
  BigInt revision;
  String title;
  String? note;

  BigInt? twice() => revision * BigInt.two;
  String label() => title.toUpperCase();
  int width() => title.length + (note?.length ?? 0);
}

final class _Books {
  _Books() {
    id = Column(
        property: 'id',
        codec: Codecs.nullable(Codecs.bigInt),
        read: (book) => book.id,
        keyOrder: 0,
        generated: true);
    revision = Column(
        property: 'revision',
        codec: Codecs.bigInt,
        read: (book) => book.revision);
    title = Column(
        property: 'title', codec: Codecs.text, read: (book) => book.title);
    note = Column(
        property: 'note',
        codec: Codecs.nullable(Codecs.text),
        read: (book) => book.note);
    type = EntityType(
        tableName: 'books',
        columns: [id, revision, title, note],
        create: (row) => _Book(
            id: row.read(id),
            revision: row.read(revision),
            title: row.read(title),
            note: row.read(note)),
        scalars: [
          EntityScalar(
              name: 'books_twice',
              columns: [revision],
              apply: (args) {
                if (args.single == null) return null;
                return _Book(
                        revision: revision.decodeValue(args.single), title: '')
                    .twice();
              }),
          EntityScalar(
              name: 'books_label',
              columns: [title],
              apply: (args) => _Book(
                      revision: BigInt.zero,
                      title: title.decodeValue(args.single))
                  .label()),
          EntityScalar(
              name: 'books_width',
              columns: [title, note],
              apply: (args) => _Book(
                      revision: BigInt.zero,
                      title: title.decodeValue(args[0]),
                      note: args[1] == null ? null : note.decodeValue(args[1]))
                  .width()),
          EntityScalar(
              name: 'books_boom',
              columns: [title],
              apply: (args) => throw StateError('boom ${args.single}')),
        ]);
    fields = (
      revision: MappedField(revision),
      title: MappedField(title),
      note: MappedField(note),
    );
  }

  late final Column<_Book, BigInt?> id;
  late final Column<_Book, BigInt> revision;
  late final Column<_Book, String> title;
  late final Column<_Book, String?> note;
  late final EntityType<_Book> type;
  late final ({
    MappedField<_Book, BigInt> revision,
    MappedField<_Book, String> title,
    MappedField<_Book, String?> note,
  }) fields;
}

void main() {
  late MutableSqliteDatabase database;
  late MutableDatabaseConnection connection;
  late _Books books;
  late TypedQuery<_Book> query;

  setUp(() async {
    books = _Books();
    database = await MutableSqliteDatabase.create();
    connection = MutableDatabaseConnection(database);
    query = TypedQuery(type: books.type, connection: connection);
    await database
        .execute('CREATE TABLE books(id INTEGER PRIMARY KEY, revision INTEGER, '
            'title TEXT NOT NULL, note TEXT)');
    await database.execute(
        'INSERT INTO books(revision, title, note) VALUES '
        '(5, ?, NULL), (30, ?, ?), (-4, ?, ?)',
        ['kept', 'other', 'south', 'west', 'side']);
  });

  tearDown(() async {
    await connection.close();
    await database.close();
  });

  SqlCall<_Book, Object?> twice() =>
      SqlCall('books_twice', [SqlArgument.of(books.fields.revision)]);

  test('a model scalar and the engine scalars filter the same rows', () async {
    final onHand = _Book(revision: BigInt.from(5), title: 'kept').twice();
    expect(onHand, BigInt.from(10));
    final doubled = await query.where(twice() > 20).toList();
    expect(doubled.map((book) => book.revision), [BigInt.from(30)]);
    final kept = await query
        .where(SqlCall<_Book, String>(
                'books_label', [SqlArgument.of(books.fields.title)])
            .equalTo('KEPT'))
        .toList();
    expect(kept.single.title, 'kept');
    final wide = await query.where(books.fields.revision.abs() > 20).toList();
    expect(wide.single.revision, BigInt.from(30));
    final west =
        await query.where(books.fields.title.upper().equalTo('WEST')).toList();
    expect(west.single.title, 'west');
    final short = await query
        .where(books.fields.title.lower().length() < 5)
        .orderBy([books.fields.title.length().ascending]).toList();
    expect(short.map((book) => book.title).toSet(), {'kept', 'west'});
    final filled = await query
        .where(books.fields.note.coalesce(books.fields.title).equalTo('kept'))
        .toList();
    expect(filled.single.title, 'kept');
    final dated = await query
        .where(books.fields.title.ifNull('none').substr(1, 4).equalTo('kept'))
        .toList();
    expect(dated.single.title, 'kept');
  });

  test('null fields stay null and a thrown body fails the statement', () async {
    final command = query
        .where(books.fields.revision.abs().equalTo(null))
        .where(books.fields.title.trim('t').upper().equalTo('WES'))
        .toSql();
    expect(command.sql, contains('abs("revision") IS NULL'));
    expect(command.sql, contains('upper(trim("title", ?)) = ?'));
    expect(command.parameters, ['t', 'WES']);
    expect(await query.where(books.fields.title.oneOf(<String>[])).toList(),
        isEmpty);
    final missing = await query
        .where(SqlCall<_Book, int>('books_width', [
          SqlArgument.of(books.fields.title),
          SqlArgument.of(books.fields.note)
        ]).equalTo(4))
        .toList();
    expect(missing.single.title, 'kept');
    await database.execute(
        'INSERT INTO books(revision, title) VALUES (NULL, ?), (1, ?)',
        ['none', '']);
    expect(await query.where(twice().isNull).count(), BigInt.one);
    expect(await query.where(books.fields.title.length().equalTo(0)).count(),
        BigInt.one);
    await expectLater(
        query
            .where(
                SqlCall('books_boom', [SqlArgument.of(books.fields.title)]) > 0)
            .toList(),
        throwsA(isA<SqlException>().having(
            (error) => error.message, 'message', contains('books_boom'))));
  });

  test('scalar metadata rejects a bad name, a foreign column, and a duplicate',
      () {
    expect(
        () => EntityScalar<_Book>(
            name: 'books twice',
            columns: [books.revision],
            apply: (args) => args.single),
        throwsA(isA<OrmMappingException>()));
    final other = Column<_Book, String>(
        property: 'other', codec: Codecs.text, read: (book) => book.title);
    expect(
        () => EntityType<_Book>(
                tableName: 'books',
                columns: books.type.columns,
                create: books.type.create,
                scalars: [
                  EntityScalar(
                      name: 'books_twice',
                      columns: [other],
                      apply: (args) => args.single)
                ]),
        throwsA(isA<OrmMappingException>()));
    final copy = EntityScalar<_Book>(
        name: 'books_twice',
        columns: [books.revision],
        apply: (args) => args.single);
    expect(
        () => DbModel([
              books.type,
              EntityType<_Book>(
                  tableName: 'other_books',
                  columns: books.type.columns,
                  create: books.type.create,
                  scalars: [copy])
            ]),
        throwsA(isA<OrmMappingException>()));
  });
}
