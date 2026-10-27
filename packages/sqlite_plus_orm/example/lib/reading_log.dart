import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

/// A tracked reading log. The application names columns. It does not write SQL.
///
/// Two books are saved. Renaming one increments its revision and leaves the
/// other at revision 0. A later save with no edits reports zero rows. The
/// kept book is read by title and by a JSON shelf path.
final class ReadingLog {
  const ReadingLog({
    required this.title,
    required this.shelf,
    required this.revision,
    required this.otherTitle,
    required this.otherRevision,
    required this.keptCount,
    required this.idleSave,
    required this.secondPlanEmpty,
  });

  final String title;
  final String shelf;
  final int revision;
  final String otherTitle;
  final int otherRevision;
  final BigInt keptCount;
  final int idleSave;
  final bool secondPlanEmpty;
}

final class Book {
  Book(this.id, this.title, this.note, this.revision);

  final BigInt id;
  String title;
  final String note;
  int revision;
}

final _bookId = Column<Book, BigInt>(
    property: 'id', codec: Codecs.bigInt, read: (book) => book.id, keyOrder: 0);
final _bookTitle = Column<Book, String>(
    property: 'title',
    codec: Codecs.text,
    read: (book) => book.title,
    write: (book, value) => book.title = value);
final _bookNote = Column<Book, String>(
    property: 'note', codec: Codecs.text, read: (book) => book.note);
final _bookRevision = Column<Book, int>(
    property: 'revision',
    codec: Codecs.integer,
    read: (book) => book.revision,
    write: (book, value) => book.revision = value,
    version: true);
final _bookType = EntityType<Book>(
    tableName: 'books',
    columns: [_bookId, _bookTitle, _bookNote, _bookRevision],
    create: (row) => Book(row.read(_bookId), row.read(_bookTitle),
        row.read(_bookNote), row.read(_bookRevision)),
    applyStoreValues: (book, row) => Book(row.read(_bookId),
        row.read(_bookTitle), row.read(_bookNote), row.read(_bookRevision)));

Future<ReadingLog> runReadingLog() async {
  final connection = await MutableDatabaseConnection.openMemory();
  final context = DbContext(connection, DbModel([_bookType]));
  try {
    await context.migrations.ensureCreated();
    final books = context.set(_bookType);
    final book = Book(BigInt.one, 'Kept Garden', '{"shelf":"north"}', 0);
    final other = Book(BigInt.two, 'Other Atlas', '{"shelf":"south"}', 0);
    books.add(book);
    books.add(other);
    if (await context.saveChanges() != 2) {
      throw StateError('insert did not save two rows');
    }
    book.title = 'Kept Garden Revised';
    if (await context.saveChanges() != 1) {
      throw StateError('rename did not save one row');
    }
    final idle = await context.saveChanges();
    final kept = books.query.where(_bookTitle.eq('Kept Garden Revised') &
        MappedField(_bookNote).at(r'$.shelf').equalTo('north'));
    final stored = await kept.orderBy([_bookTitle.asc()]).single();
    final keptCount = await kept.count();
    final south = await books.query
        .where(MappedField(_bookNote).at(r'$.shelf').equalTo('south'))
        .single();
    final stable = (await context.migrations.plan()).isEmpty;
    return ReadingLog(
      title: stored.title,
      shelf: 'north',
      revision: stored.revision,
      otherTitle: south.title,
      otherRevision: south.revision,
      keptCount: keptCount,
      idleSave: idle,
      secondPlanEmpty: stable,
    );
  } finally {
    await context.close();
  }
}
