import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

part 'reading_log.orm.g.dart';

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

@DbEntity(table: 'books')
class Book {
  Book(this.id, this.title, this.note, this.revision);

  final BigInt id;
  String title;
  @DbJson()
  final String note;
  @DbVersion()
  int revision;
}

Future<ReadingLog> runReadingLog() async {
  final books = await DbSet.openMemory(BookMapping.instance);
  try {
    final book = Book(BigInt.one, 'Kept Garden', _note('north'), 0);
    final other = Book(BigInt.two, 'Other Atlas', _note('south'), 0);
    books.add(book);
    books.add(other);
    await _save(books, 2);

    book.title = 'Kept Garden Revised';
    await _save(books, 1);
    final idleSave = await books.saveChanges();

    final kept = books.query
        .selectWhere(
          (row) =>
              row.title.equalTo(book.title) &
              row.path(r'$.shelf').equalTo('north'),
        )
        .orderByFields((row) => [row.title.ascending]);
    final stored = await kept.single();
    final south = await books.query
        .selectWhere((row) => row.path(r'$.shelf').equalTo('south'))
        .single();
    return ReadingLog(
      title: stored.title,
      shelf: 'north',
      revision: stored.revision,
      otherTitle: south.title,
      otherRevision: south.revision,
      keptCount: await kept.count(),
      idleSave: idleSave,
      secondPlanEmpty: (await books.migrations.plan()).isEmpty,
    );
  } finally {
    await books.close();
  }
}

String _note(String shelf) => '{"shelf":"$shelf"}';

Future<void> _save(DbSet<Book> books, int rows) async {
  final saved = await books.saveChanges();
  if (saved != rows) {
    throw StateError('expected $rows saved rows, got $saved');
  }
}
