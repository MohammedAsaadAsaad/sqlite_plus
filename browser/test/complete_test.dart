import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/src/session.dart';
import 'package:sqlite_plus_browser/src/sql_complete.dart';

void main() {
  const books = SchemaObject(
    type: 'table',
    name: 'books',
    table: 'books',
    sql: null,
    columns: [
      ColumnInfo(
        name: 'id',
        type: 'INTEGER',
        notNull: true,
        primaryKey: true,
      ),
      ColumnInfo(
        name: 'title',
        type: 'TEXT',
        notNull: true,
        primaryKey: false,
      ),
      ColumnInfo(
        name: 'pages',
        type: 'INTEGER',
        notNull: false,
        primaryKey: false,
      ),
    ],
  );
  const authors = SchemaObject(
    type: 'table',
    name: 'authors',
    table: 'authors',
    sql: null,
    columns: [
      ColumnInfo(
        name: 'id',
        type: 'INTEGER',
        notNull: true,
        primaryKey: true,
      ),
      ColumnInfo(
        name: 'name',
        type: 'TEXT',
        notNull: true,
        primaryKey: false,
      ),
    ],
  );

  List<String> labels(String text) {
    return sqlCompletions(
      text: text,
      cursor: text.length,
      objects: const [books, authors],
    ).map((item) => item.label).toList();
  }

  test('a prefix completes a keyword, a table, and a column', () {
    expect(labels('SEL').first, 'SELECT');
    expect(labels('SELECT title FROM bo'), contains('books'));
    expect(labels('SELECT books.'), ['id', 'title', 'pages']);
    final typed = sqlCompletions(
      text: 'SELECT books.',
      cursor: 'SELECT books.'.length,
      objects: const [books, authors],
    );
    expect(typed.singleWhere((item) => item.label == 'id').detail, 'INTEGER');
    expect(typed.singleWhere((item) => item.label == 'title').detail, 'TEXT');
    expect(
        typed.singleWhere((item) => item.label == 'pages').detail, 'INTEGER');
    expect(labels('SELECT * FROM books WHERE pa'), contains('pages'));
    expect(labels("SELECT 'SEL"), isEmpty);
    expect(labels('CREATE TABLE bo'), isNot(contains('books')));
    expect(labels('ALTER TABLE bo'), contains('books'));
    expect(labels('SELECT '), containsAll(['*', 'title', 'pages']));
    expect(labels('SELECT id, name FROM books, authors WHERE i'),
        containsAll(['books.id', 'authors.id']));
    expect(labels('SELECT title '), ['FROM', 'AS']);
    expect(labels('SELECT title F'), ['FROM']);
    expect(labels('SELECT * FROM '), containsAll(['books', 'authors']));
    expect(labels('SELECT * FROM '), isNot(contains('SELECT')));
    expect(labels('INSERT '), ['INTO']);
    expect(labels('SELECT * FROM books WHERE pages = '), isEmpty);
  });
}
