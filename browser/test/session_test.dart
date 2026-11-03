import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/src/format.dart';
import 'package:sqlite_plus_browser/src/session.dart';

void main() {
  test('words ignore quoted text', () {
    expect(sqlWords("SELECT 'INSERT' FROM books"), ['select', 'from', 'books']);
    expect(
        statementReads('WITH saved AS (SELECT 1) SELECT * FROM saved'), isTrue);
    expect(
        statementReads(
            'WITH saved AS (SELECT 1) INSERT INTO books SELECT * FROM saved'),
        isFalse);
    expect(parseCell('320', nullWord: false), BigInt.from(320));
    expect(parseCell('3.5', nullWord: false), 3.5);
    expect(parseCell('Kept Garden', nullWord: false), 'Kept Garden');
    expect(parseCell('320', nullWord: true), isNull);
    expect(formatCell(null), 'NULL');
  });

  test('sample rows edit, delete, and reopen from the image', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.insertSample();
    expect(session.objects.map((object) => object.name), contains('books'));
    final books =
        session.objects.singleWhere((object) => object.name == 'books');
    expect(
        books.columns.map((column) => column.name), ['id', 'title', 'pages']);
    expect(books.columns.first.primaryKey, isTrue);
    expect(books.columns[1].notNull, isTrue);

    final page = await session.slice('books');
    expect(page.hasRowid, isTrue);
    expect(page.total, 2);
    expect(page.rows.map((row) => row[2]), ['Kept Garden', 'Other Atlas']);
    expect(page.rows.first[3], BigInt.from(320));

    final garden = page.rows.first.first as BigInt;
    await session.updateCell('books', garden, 'pages', BigInt.from(321));
    final revised = await session.slice('books');
    expect(revised.rows.first[3], BigInt.from(321));

    final other = revised.rows[1].first as BigInt;
    await session.deleteRow('books', other);
    expect((await session.slice('books')).total, 1);

    final copy = BrowserSession();
    addTearDown(copy.close);
    await copy.openBytes(session.exportBytes(), label: 'saved.db');
    final kept = await copy.slice('books');
    expect(kept.total, 1);
    expect(kept.rows.single[2], 'Kept Garden');
    expect(kept.rows.single[3], BigInt.from(321));
    expect(copy.dirty, isFalse);
  });

  test('a query returns rows and a bad name fails', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.insertSample();
    final result =
        await session.run("SELECT title FROM books WHERE pages = 40");
    expect(result.isQuery, isTrue);
    expect(result.rows.single.single, 'Other Atlas');
    await expectLater(
        session.run('SELECT * FROM missing'), throwsA(isA<Exception>()));
  });

  test('a table without rowid stays readable', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(
        'CREATE TABLE pair (a TEXT, b TEXT, PRIMARY KEY (a, b)) WITHOUT ROWID');
    await session.run("INSERT INTO pair(a, b) VALUES ('one', 'two')");
    final page = await session.slice('pair');
    expect(page.hasRowid, isFalse);
    expect(page.rows.single, ['one', 'two']);
  });

  test('a full page does not count, and the next page is the tail', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run('CREATE TABLE nums (n INTEGER)');
    final values = [for (var i = 0; i < 55; i++) '($i)'];
    await session.run('INSERT INTO nums(n) VALUES ${values.join(',')}');
    final first = await session.slice('nums');
    expect(first.rows, hasLength(50));
    expect(first.total, -1);
    expect(first.rows.first[1], BigInt.zero);
    expect(await session.countRows('nums'), 55);
    final second = await session.slice('nums', offset: 50);
    expect(second.rows, hasLength(5));
    expect(second.total, 55);
    expect(second.rows.first[1], BigInt.from(50));
    expect(second.rows.last[1], BigInt.from(54));
  });

  test('a query without a limit returns one page', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    expect(
        outerSqlLimit('SELECT * FROM (SELECT n FROM nums LIMIT 1)'), isFalse);
    expect(outerSqlLimit("SELECT 'LIMIT' FROM nums"), isFalse);
    expect(outerSqlLimit('SELECT n FROM nums LIMIT 3'), isTrue);
    await session.run('CREATE TABLE nums (n INTEGER)');
    final values = [for (var i = 0; i < 55; i++) '($i)'];
    await session.run('INSERT INTO nums(n) VALUES ${values.join(',')}');
    final first = await session.run('SELECT n FROM nums');
    expect(first.rows, hasLength(50));
    expect(first.more, isTrue);
    expect(first.offset, 0);
    expect(first.rows.first.single, BigInt.zero);
    expect(first.rows.last.single, BigInt.from(49));
    final second = await session.run('SELECT n FROM nums;', offset: 50);
    expect(second.rows, hasLength(5));
    expect(second.more, isFalse);
    expect(second.offset, 50);
    expect(second.rows.first.single, BigInt.from(50));
    expect(second.rows.last.single, BigInt.from(54));
    final limited = await session.run('SELECT n FROM nums LIMIT 60');
    expect(limited.rows, hasLength(50));
    expect(limited.more, isTrue);
    expect(limited.cached, hasLength(55));
    expect(limited.window(50).rows, hasLength(5));
    expect(limited.window(50).more, isFalse);
    expect(limited.window(50).rows.first.single, BigInt.from(50));
  });

  test('schema keeps defaults, foreign keys, indexes, and triggers', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run('CREATE TABLE authors (id INTEGER PRIMARY KEY)');
    await session.run(
      "CREATE TABLE books ("
      "id INTEGER PRIMARY KEY, "
      "title TEXT NOT NULL DEFAULT 'Kept', "
      "author_id INTEGER REFERENCES authors(id) ON DELETE CASCADE)",
    );
    await session.run(
      'CREATE UNIQUE INDEX idx_title ON books(title)',
    );
    await session.run(
      'CREATE TRIGGER tr AFTER INSERT ON books BEGIN SELECT 1; END',
    );
    final books =
        session.objects.singleWhere((object) => object.name == 'books');
    final title = books.columns.singleWhere((column) => column.name == 'title');
    expect(title.defaultValue, contains('Kept'));
    expect(title.notNull, isTrue);
    final link = books.foreignKeys.single;
    expect(link.from, 'author_id');
    expect(link.table, 'authors');
    expect(link.to, 'id');
    expect(link.onDelete.toLowerCase(), contains('cascade'));
    final index =
        session.objects.singleWhere((object) => object.name == 'idx_title');
    expect(index.unique, isTrue);
    expect(index.indexColumns, ['title']);
    expect(index.table, 'books');
    final trigger =
        session.objects.singleWhere((object) => object.name == 'tr');
    expect(trigger.type, 'trigger');
    expect(trigger.table, 'books');
  });
}
