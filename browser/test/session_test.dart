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
}
