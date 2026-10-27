import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';

/// One in-memory library.
///
/// Bound JSON constructors, a rolled-back insert, FTS5 highlight and an
/// Arabic token, an R-tree hit, `user_version`, then the same image reopened.
final class LibraryTour {
  const LibraryTour({
    required this.title,
    required this.pages,
    required this.highlighted,
    required this.rank,
    required this.arabicTitle,
    required this.arabicMatches,
    required this.placeId,
    required this.keptCards,
    required this.userVersion,
    required this.reopenedTitle,
    required this.reopenedVersion,
    required this.imageBytes,
  });

  final String title;
  final BigInt pages;
  final String highlighted;
  final double rank;
  final String arabicTitle;
  final BigInt arabicMatches;
  final BigInt placeId;
  final BigInt keptCards;
  final BigInt userVersion;
  final String reopenedTitle;
  final BigInt reopenedVersion;
  final int imageBytes;
}

Future<LibraryTour> runLibraryTour() async {
  final db = await MutableSqliteDatabase.create();
  try {
    await db.execute(
        'CREATE TABLE books (id INTEGER PRIMARY KEY, card TEXT NOT NULL)');
    await db.execute('INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
        ['title', 'Kept Garden', 'pages', 320]);
    await db.execute('INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
        ['title', 'Other Atlas', 'pages', 90]);
    await db.execute('BEGIN');
    await db.execute('INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
        ['title', 'Rolled Back', 'pages', 1]);
    await db.execute('ROLLBACK');
    final kept = await db.query('SELECT COUNT(*) FROM books');

    final card = await db.query(
        'SELECT json_extract(card, ?), json_extract(card, ?) FROM books '
        'WHERE json_extract(card, ?) = ?',
        [r'$.title', r'$.pages', r'$.title', 'Kept Garden']);

    await db.execute('CREATE VIRTUAL TABLE book_text USING fts5(title, body)');
    await db
        .execute('INSERT INTO book_text(title, body) VALUES (?, ?), (?, ?)', [
      'Kept Garden',
      'a garden kept in the margin',
      'Arabic Shelf',
      'مرحبا بالعالم',
    ]);
    final text = await db.query(
        "SELECT highlight(book_text, 1, '[', ']'), bm25(book_text) "
        'FROM book_text WHERE book_text MATCH ?',
        ['kept']);
    final arabic = await db.query(
        'SELECT title FROM book_text WHERE book_text MATCH ?', ['مرحبا']);
    final arabicCount = await db.query(
        'SELECT COUNT(*) FROM book_text WHERE book_text MATCH ?', ['مرحبا']);

    await db.execute(
        'CREATE VIRTUAL TABLE shelves USING rtree(id, minX, maxX, minY, maxY)');
    await db.execute(
        'INSERT INTO shelves VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
        [1, 0, 1, 0, 1, 2, 5, 6, 5, 6]);
    final place = await db.query(
        'SELECT id FROM shelves '
        'WHERE minX <= ? AND maxX >= ? AND minY <= ? AND maxY >= ?',
        [1, 0, 1, 0]);

    await db.execute('PRAGMA user_version=7');
    final version = await db.query('PRAGMA user_version');
    final image = db.exportImage();
    final reopened = await MutableSqliteDatabase.fromImage(image);
    try {
      final again = await reopened.query(
          'SELECT json_extract(card, ?) FROM books WHERE id = ?',
          [r'$.title', 1]);
      final againVersion = await reopened.query('PRAGMA user_version');
      return LibraryTour(
        title: card.rows.single[0] as String,
        pages: card.rows.single[1] as BigInt,
        highlighted: text.rows.single[0] as String,
        rank: text.rows.single[1] as double,
        arabicTitle: arabic.rows.single.single as String,
        arabicMatches: arabicCount.rows.single.single as BigInt,
        placeId: place.rows.single.single as BigInt,
        keptCards: kept.rows.single.single as BigInt,
        userVersion: version.rows.single.single as BigInt,
        reopenedTitle: again.rows.single.single as String,
        reopenedVersion: againVersion.rows.single.single as BigInt,
        imageBytes: image.length,
      );
    } finally {
      await reopened.close();
    }
  } finally {
    await db.close();
  }
}

Future<void> main() async {
  final tour = await runLibraryTour();
  stdout.writeln('${tour.title} (${tour.pages} pages) | ${tour.highlighted} '
      '| ${tour.arabicTitle} x${tour.arabicMatches} '
      '| place ${tour.placeId} | cards ${tour.keptCards} '
      '| version ${tour.userVersion} '
      '| reopen ${tour.reopenedTitle} v${tour.reopenedVersion} '
      '| ${tour.imageBytes} bytes');
}
