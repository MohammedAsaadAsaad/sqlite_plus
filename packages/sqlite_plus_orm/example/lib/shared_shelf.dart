import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

part 'shared_shelf.orm.g.dart';

/// One file holding a book and a note.
final class SharedShelf {
  const SharedShelf({required this.bookTitle, required this.noteBody});

  final String bookTitle;
  final String noteBody;
}

@DbEntity(table: 'books')
class ShelfBook {
  ShelfBook(this.id, this.title);

  final BigInt id;
  String title;
}

@DbEntity(table: 'notes')
class ShelfNote {
  ShelfNote(this.id, this.body);

  final BigInt id;
  String body;
}

/// Opens one file, creates both tables, and saves one row in each.
Future<SharedShelf> runSharedMemory() async {
  final dir = await Directory.systemTemp.createTemp('shared_shelf_');
  final path = '${dir.path}/shelf.db';
  final database = await MutableSqliteDatabase.create();
  final connection = MutableDatabaseConnection(database, closeDatabase: true);
  final context = DbContext(connection, generatedModel);
  try {
    await context.migrations.ensureCreated();
    final books = context.set(ShelfBookMapping.instance);
    final notes = context.set(ShelfNoteMapping.instance);
    books.add(ShelfBook(BigInt.one, 'Kept Garden'));
    notes.add(ShelfNote(BigInt.one, 'margin'));
    final saved = await context.saveChanges();
    if (saved != 2) throw StateError('expected 2 saved rows, got $saved');
    final book = await books.query
        .selectWhere((row) => row.title.equalTo('Kept Garden'))
        .single();
    final note = await notes.query
        .selectWhere((row) => row.body.equalTo('margin'))
        .single();
    await File(path).writeAsBytes(database.exportImage(), flush: true);
    return SharedShelf(bookTitle: book.title, noteBody: note.body);
  } finally {
    await context.close();
  }
}

/// Saves one note to [path], closes it, and reads that note back.
Future<String> runFileKeepsRow(String path) async {
  final notes = await DbSet.openDbFile(ShelfNoteMapping.instance, path);
  try {
    notes.add(ShelfNote(BigInt.one, 'kept'));
    final saved = await notes.saveChanges();
    if (saved != 1) throw StateError('expected 1 saved row, got $saved');
  } finally {
    await notes.close();
  }
  final again = await DbSet.openDbFile(ShelfNoteMapping.instance, path);
  try {
    final stored = await again.query
        .selectWhere((row) => row.body.equalTo('kept'))
        .single();
    return stored.body;
  } finally {
    await again.close();
  }
}

/// True when a second open of [path] fails while the first set is still open.
Future<bool> runSecondFileOpenRejected(String path) async {
  final notes = await DbSet.openDbFile(ShelfNoteMapping.instance, path);
  try {
    try {
      await DbSet.openDbFile(ShelfNoteMapping.instance, path);
      return false;
    } on StateError {
      return true;
    }
  } finally {
    await notes.close();
  }
}

/// True when a second save throws while the first save is still running.
Future<bool> runSecondSaveRejected() async {
  final dir = await Directory.systemTemp.createTemp('shared_shelf_save_');
  final notes =
      await DbSet.openDbFile(ShelfNoteMapping.instance, '${dir.path}/notes.db');
  try {
    notes.add(ShelfNote(BigInt.one, 'kept'));
    final pending = notes.saveChanges();
    var rejected = false;
    try {
      await notes.saveChanges();
    } on OrmStateException {
      rejected = true;
    }
    final saved = await pending;
    if (saved != 1) throw StateError('expected 1 saved row, got $saved');
    return rejected;
  } finally {
    await notes.close();
  }
}

/// Two queries on one context both return. The second waits for the first.
Future<List<String>> runQueuedQueries() async {
  final dir = await Directory.systemTemp.createTemp('shared_shelf_queue_');
  final database = await MutableSqliteDatabase.create();
  final connection = MutableDatabaseConnection(database, closeDatabase: true);
  final context = DbContext(connection, generatedModel);
  try {
    await context.migrations.ensureCreated();
    final books = context.set(ShelfBookMapping.instance);
    final notes = context.set(ShelfNoteMapping.instance);
    books.add(ShelfBook(BigInt.one, 'Kept Garden'));
    notes.add(ShelfNote(BigInt.one, 'margin'));
    await context.saveChanges();
    await File('${dir.path}/shelf.db')
        .writeAsBytes(database.exportImage(), flush: true);
    final book = books.query
        .selectWhere((row) => row.title.equalTo('Kept Garden'))
        .single();
    final note =
        notes.query.selectWhere((row) => row.body.equalTo('margin')).single();
    final storedBook = await book;
    final storedNote = await note;
    return [storedBook.title, storedNote.body];
  } finally {
    await context.close();
  }
}
