import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/src/format.dart';
import 'package:sqlite_plus_browser/src/index_stats.dart';
import 'package:sqlite_plus_browser/src/schema_sql.dart';
import 'package:sqlite_plus_browser/src/session.dart';
import 'package:sqlite_plus_browser/src/sql_view.dart';

void main() {
  test('a create statement keeps each column on one line', () {
    expect(
      formatSql(
        'CREATE TABLE events (\n'
        '    id      INTEGER PRIMARY\n'
        'KEY,\n'
        '        category TEXT,\n'
        '    value   REAL,\n'
        '    flag    INTEGER\n'
        ')',
      ),
      'CREATE TABLE events (\n'
      '  id INTEGER PRIMARY KEY,\n'
      '  category TEXT,\n'
      '  value REAL,\n'
      '  flag INTEGER\n'
      ')',
    );
    expect(
      formatSql(
        'CREATE TABLE IF NOT EXISTS books '
        '(id INTEGER PRIMARY KEY, title TEXT NOT NULL, pages INTEGER)',
      ),
      contains('  id INTEGER PRIMARY KEY,\n  title TEXT NOT NULL,'),
    );
  });

  test('the editor formats at a boundary and leaves a prefix alone', () {
    final prefix = liveSqlEdit('SEL', 3);
    expect(prefix.text, 'SEL');
    expect(prefix.cursor, 3);

    final spaced = liveSqlEdit('SELECT ', 7);
    expect(spaced.text, 'SELECT ');
    expect(spaced.cursor, 7);

    const fromText = 'SELECT title FROM ';
    final from = liveSqlEdit(fromText, fromText.length);
    expect(from.text, 'SELECT title\nFROM ');
    expect(from.cursor, from.text.length);

    const opened = 'CREATE TABLE events (\n';
    final indented = liveSqlEdit(opened, opened.length);
    expect(indented.text, endsWith('\n  '));
    expect(indented.cursor, indented.text.length);

    const typed = 'CREATE TABLE events (id INTEGER,';
    final comma = liveSqlEdit(typed, typed.length);
    expect(comma.text, endsWith(',\n  '));

    const partial = 'CREATE TABLE events (\n  id INTEGER PRIMARY KEY';
    final open = liveSqlEdit(partial, partial.length);
    expect(open.text, partial);

    const closed =
        'CREATE TABLE events (id INTEGER PRIMARY KEY, category TEXT, value REAL, flag INTEGER)';
    final formatted = liveSqlEdit(closed, closed.length);
    expect(formatted.text, formatSql(closed));
    expect(formatted.cursor, formatted.text.length);
    expect(formatted.text, contains('  id INTEGER PRIMARY KEY,'));
    final again = liveSqlEdit(formatted.text, formatted.cursor);
    expect(again.text, formatted.text);
    expect(again.cursor, formatted.cursor);
  });

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

  test('a cell editor follows the declared column type', () {
    expect(cellKind('INTEGER'), CellKind.integer);
    expect(cellKind('int'), CellKind.integer);
    expect(cellKind('BIGINT'), CellKind.integer);
    expect(cellKind('REAL'), CellKind.real);
    expect(cellKind('FLOAT'), CellKind.real);
    expect(cellKind('DOUBLE PRECISION'), CellKind.real);
    expect(cellKind('NUMERIC'), CellKind.real);
    expect(cellKind('DECIMAL(8,2)'), CellKind.real);
    expect(cellKind('TEXT'), CellKind.text);
    expect(cellKind('VARCHAR(20)'), CellKind.text);
    expect(cellKind(''), CellKind.text);
    expect(cellKind('BLOB'), CellKind.text);
    expect(cellKind('BOOLEAN'), CellKind.boolean);
    expect(cellKind('BOOL'), CellKind.boolean);
    expect(cellKind('DATE'), CellKind.date);
    expect(cellKind('DATETIME'), CellKind.dateTime);
    expect(cellKind('TIMESTAMP'), CellKind.dateTime);
    expect(cellKind('TIME'), CellKind.time);

    expect(
      parseTypedCell('321', CellKind.integer, nullWord: false),
      BigInt.from(321),
    );
    expect(parseTypedCell(' 42 ', CellKind.integer, nullWord: false),
        BigInt.from(42));
    expect(parseTypedCell('', CellKind.integer, nullWord: false), isNull);
    expect(parseTypedCell('7', CellKind.integer, nullWord: true), isNull);
    expect(parseTypedCell('320', CellKind.text, nullWord: false), '320');
    expect(parseTypedCell('1.5', CellKind.real, nullWord: false), 1.5);
    expect(parseTypedCell('4', CellKind.real, nullWord: false), BigInt.from(4));
    expect(parseTypedCell('0', CellKind.boolean, nullWord: false), BigInt.zero);
    expect(cellTextValid('3.2', CellKind.integer), isFalse);
    expect(cellTextValid('-7', CellKind.integer), isTrue);
    expect(cellTextValid('', CellKind.integer), isTrue);
    expect(cellTextValid('1e2', CellKind.real), isTrue);
    expect(cellTextValid('nope', CellKind.real), isFalse);
    expect(cellTextValid('nan', CellKind.real), isFalse);
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

  test('a form builds a table, an index, and a foreign key', () async {
    expect(
      createTableSql('', const [ColumnDraft(name: 'id', type: 'INTEGER')]),
      isNull,
    );
    expect(createTableSql('notes', const []), isNull);
    expect(
      createTableSql('notes', const [
        ColumnDraft(name: 'id', type: 'INTEGER'),
        ColumnDraft(name: 'ID', type: 'TEXT'),
      ]),
      isNull,
    );
    expect(
      createTableSql('notes', const [
        ColumnDraft(name: 'id', type: 'INTEGER', primaryKey: true),
        ColumnDraft(name: 'title', type: 'TEXT', notNull: true),
      ]),
      'CREATE TABLE "notes" (\n'
      '  "id" INTEGER PRIMARY KEY,\n'
      '  "title" TEXT NOT NULL\n'
      ')',
    );
    expect(
      createTableSql('pair', const [
        ColumnDraft(name: 'a', type: 'INTEGER', primaryKey: true),
        ColumnDraft(name: 'b', type: 'INTEGER', primaryKey: true),
      ]),
      contains('PRIMARY KEY ("a", "b")'),
    );
    expect(
      createIndexSql(table: 'notes', columns: ['title']),
      'CREATE INDEX "idx_notes_title" ON "notes" ("title")',
    );
    expect(
      createIndexSql(
        table: 'notes',
        columns: ['title'],
        name: 'uq',
        unique: true,
      ),
      'CREATE UNIQUE INDEX "uq" ON "notes" ("title")',
    );
    expect(
      linkColumnSql(
        child: 'books',
        column: 'authors_id',
        type: 'INTEGER',
        parent: 'authors',
        parentColumn: 'id',
      ),
      'ALTER TABLE "books" ADD COLUMN "authors_id" INTEGER '
      'REFERENCES "authors" ("id")',
    );

    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(createTableSql('authors', const [
      ColumnDraft(name: 'id', type: 'INTEGER', primaryKey: true),
      ColumnDraft(name: 'name', type: 'TEXT'),
    ])!);
    await session.run(createTableSql('books', const [
      ColumnDraft(name: 'id', type: 'INTEGER', primaryKey: true),
      ColumnDraft(name: 'title', type: 'TEXT', notNull: true),
    ])!);
    await session.run(createIndexSql(table: 'books', columns: ['title'])!);
    await session.run(linkColumnSql(
      child: 'books',
      column: 'authors_id',
      type: 'INTEGER',
      parent: 'authors',
      parentColumn: 'id',
    )!);
    final books =
        session.objects.singleWhere((object) => object.name == 'books');
    expect(books.columns.map((column) => column.name), contains('authors_id'));
    final link = books.foreignKeys.single;
    expect(link.from, 'authors_id');
    expect(link.table, 'authors');
    expect(link.to, 'id');
    final index = session.objects
        .singleWhere((object) => object.name == 'idx_books_title');
    expect(index.indexColumns, ['title']);
  });

  test('an added column keeps its null rule, default, and reference', () async {
    expect(
      addColumnSql(table: '', name: 'note', type: 'TEXT'),
      isNull,
    );
    expect(
      addColumnSql(
        table: 'events',
        name: 'id',
        type: 'INTEGER',
        existing: const ['id'],
      ),
      isNull,
    );
    expect(
      addColumnSql(
        table: 'events',
        name: 'note',
        type: 'TEXT',
        notNull: true,
      ),
      isNull,
    );
    expect(
      addColumnSql(
        table: 'events',
        name: 'note',
        type: 'TEXT',
        notNull: true,
        defaultText: "Kept's",
      ),
      'ALTER TABLE "events" ADD COLUMN "note" TEXT NOT NULL DEFAULT \'Kept\'\'s\'',
    );
    expect(
      addColumnSql(
        table: 'events',
        name: 'rank',
        type: 'INTEGER',
        defaultText: '3',
      ),
      'ALTER TABLE "events" ADD COLUMN "rank" INTEGER DEFAULT 3',
    );
    expect(
      addColumnSql(
        table: 'books',
        name: 'author_id',
        type: 'INTEGER',
        referenceTable: 'authors',
        referenceColumn: 'id',
      ),
      'ALTER TABLE "books" ADD COLUMN "author_id" INTEGER '
      'REFERENCES "authors" ("id")',
    );
    expect(columnTypeSql(base: 'TEXT'), 'TEXT');
    expect(columnTypeSql(base: 'TEXT', length: '160'), 'VARCHAR(160)');
    expect(columnTypeSql(base: 'TEXT', length: '0'), isNull);
    expect(columnTypeSql(base: 'TEXT', length: 'wide'), isNull);
    expect(columnTypeSql(base: 'INTEGER'), 'INTEGER');
    expect(columnTypeSql(base: 'INTEGER', digits: '11'), 'INTEGER(11)');
    expect(
        columnTypeSql(base: 'REAL', digits: '10', places: '2'), 'REAL(10, 2)');
    expect(columnTypeSql(base: 'REAL', places: '2'), isNull);
    expect(columnTypeSql(base: 'NUMERIC', digits: '8'), 'NUMERIC(8)');
    expect(columnTypeSql(base: 'BLOB', length: '32'), 'BLOB(32)');
    expect(
      addColumnSql(
        table: 'events',
        name: 'rank',
        type: 'INTEGER(11)',
        defaultText: '3',
      ),
      'ALTER TABLE "events" ADD COLUMN "rank" INTEGER(11) DEFAULT 3',
    );

    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(
      'CREATE TABLE events (id INTEGER PRIMARY KEY, category TEXT)',
    );
    await session.run(
      'CREATE TABLE authors (id INTEGER PRIMARY KEY)',
    );
    await session.run(addColumnSql(
      table: 'events',
      name: 'note',
      type: 'TEXT',
      notNull: true,
      defaultText: 'Kept',
    )!);
    await session.run(addColumnSql(
      table: 'events',
      name: 'author_id',
      type: 'INTEGER',
      referenceTable: 'authors',
      referenceColumn: 'id',
    )!);
    final events =
        session.objects.singleWhere((object) => object.name == 'events');
    final note = events.columns.singleWhere((column) => column.name == 'note');
    expect(note.notNull, isTrue);
    expect(note.defaultValue, contains('Kept'));
    final link = events.foreignKeys.single;
    expect(link.from, 'author_id');
    expect(link.table, 'authors');
    expect(link.to, 'id');
  });

  test('related rows use one parent column from this page', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(
      'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT UNIQUE)',
    );
    await session.run(
      'CREATE TABLE books ('
      'id INTEGER PRIMARY KEY, title TEXT, author_id INTEGER, '
      'FOREIGN KEY (author_id) REFERENCES authors(id), '
      'FOREIGN KEY (author_id) REFERENCES authors(name))',
    );
    await session.run(
      "INSERT INTO authors (id, name) VALUES (1, 'Ada'), (2, 'Grace')",
    );
    await session.run(
      "INSERT INTO books (title, author_id) VALUES ('Kept', 1)",
    );
    final books =
        session.objects.singleWhere((object) => object.name == 'books');
    final links = [
      for (final key in books.foreignKeys)
        if (key.from == 'author_id') key,
    ];
    expect(links, hasLength(2));
    final matched = await session.rowsMatching(
      table: 'authors',
      column: 'name',
      values: const ['Ada', null, 'Ada'],
    );
    final name = matched.columns.indexOf('name');
    expect(matched.rows, hasLength(1));
    expect(matched.rows.single[name], 'Ada');
    expect(matched.more, isFalse);
    final none = await session.rowsMatching(
      table: 'authors',
      column: 'id',
      values: const [null],
    );
    expect(none.rows, isEmpty);
    expect(none.columns, contains('name'));
  });

  test('a confirmed column link keeps the rows and the index', () async {
    expect(
      rewriteTableForeignKey(
        sql: 'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT)',
        column: 'title',
        parent: 'authors',
        parentColumn: 'id',
        newName: 'books__link',
      ),
      'CREATE TABLE "books__link" (id INTEGER PRIMARY KEY, title TEXT '
      'REFERENCES "authors" ("id"))',
    );
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(
      'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)',
    );
    await session.run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT)',
    );
    await session.run("INSERT INTO books (title) VALUES ('Kept')");
    await session.run('CREATE INDEX idx_books_title ON books (title)');
    final books =
        session.objects.singleWhere((object) => object.name == 'books');
    final authors =
        session.objects.singleWhere((object) => object.name == 'authors');
    final refused = planColumnLink(
      child: books,
      childColumn: 'title',
      parent: authors,
      parentColumn: 'name',
      catalog: session.objects,
    );
    expect(refused.allowed, isFalse);
    expect(refused.statements, isEmpty);
    final plan = planColumnLink(
      child: books,
      childColumn: 'title',
      parent: authors,
      parentColumn: 'id',
      catalog: session.objects,
    );
    expect(plan.refusal, isNull);
    expect(plan.statements, isNotEmpty);
    await session.runAll(plan.statements);
    final linked =
        session.objects.singleWhere((object) => object.name == 'books');
    expect(linked.columns.map((column) => column.name), ['id', 'title']);
    final key = linked.foreignKeys.single;
    expect(key.from, 'title');
    expect(key.table, 'authors');
    expect(key.to, 'id');
    final index = session.objects
        .singleWhere((object) => object.name == 'idx_books_title');
    expect(index.indexColumns, ['title']);
    final page = await session.slice('books');
    final title = page.columns.indexWhere((column) => column.name == 'title');
    expect(page.rows.single[title + (page.hasRowid ? 1 : 0)], 'Kept');
    expect(
      session.objects.where((object) => object.name.endsWith('__link')),
      isEmpty,
    );
  });

  test('only a key column on another table can be linked', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(
      'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT UNIQUE)',
    );
    await session.run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, author_id INTEGER)',
    );
    await session.run(
      'CREATE TABLE pair (a INTEGER, b INTEGER, PRIMARY KEY (a, b))',
    );
    await session.run('CREATE UNIQUE INDEX idx_books_title ON books (title)');
    final authors =
        session.objects.singleWhere((object) => object.name == 'authors');
    final books =
        session.objects.singleWhere((object) => object.name == 'books');
    final pair = session.objects.singleWhere((object) => object.name == 'pair');
    expect(columnCanReference(books, 'author_id'), isTrue);
    expect(columnCanReference(books, 'missing'), isFalse);
    expect(columnAcceptsReference(authors, 'id', session.objects), isTrue);
    expect(columnAcceptsReference(authors, 'name', session.objects), isTrue);
    expect(columnAcceptsReference(books, 'title', session.objects), isTrue);
    expect(
      columnAcceptsReference(books, 'author_id', session.objects),
      isFalse,
    );
    expect(columnAcceptsReference(pair, 'a', session.objects), isFalse);
    expect(columnAcceptsReference(pair, 'b', session.objects), isFalse);
    final plan = planColumnLink(
      child: books,
      childColumn: 'author_id',
      parent: authors,
      parentColumn: 'id',
      catalog: session.objects,
    );
    await session.runAll(plan.statements);
    final linked =
        session.objects.singleWhere((object) => object.name == 'books');
    expect(columnCanReference(linked, 'author_id'), isFalse);
    expect(columnCanReference(linked, 'title'), isTrue);
  });

  test('a column search and sort cover the whole table', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, title TEXT, pages INTEGER)',
    );
    await session.run(
      "INSERT INTO books (title, pages) VALUES ('Kept Garden', 320), "
      "('Other Atlas', 40)",
    );
    final ascending = await session.slice(
      'books',
      orderBy: 'pages',
      ascending: true,
    );
    expect('${ascending.rows.first.last}', '40');
    expect('${ascending.rows.last.last}', '320');
    final found = await session.slice('books', contains: {'title': 'kept'});
    expect(found.rows, hasLength(1));
    expect(found.rows.single[2], 'Kept Garden');
    expect(await session.countRows('books', contains: {'title': 'kept'}), 1);
    expect(await session.countRows('books'), 2);
  });

  test('a failed script rolls the database back', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    Object? error;
    try {
      await session.runAll(const [
        'CREATE TABLE nope (id INTEGER)',
        'NOT SQL',
      ]);
    } catch (caught) {
      error = caught;
    }
    expect(error, isNotNull);
    expect(session.objects.where((object) => object.name == 'nope'), isEmpty);
  });

  test('an index reports its leaf entries and page size', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(
      'CREATE TABLE events (id INTEGER PRIMARY KEY, category TEXT, value REAL)',
    );
    await session.run(
      'CREATE INDEX idx_events_category_value ON events (category, value)',
    );
    final empty = session.objects
        .singleWhere((object) => object.name == 'idx_events_category_value');
    expect(empty.entries, 0);
    expect(empty.byteSize, greaterThan(0));
    expect(empty.byteSize! % 512, 0);

    final values = [
      for (var i = 0; i < 300; i++) "('c$i', $i)",
    ].join(', ');
    await session.run(
      'INSERT INTO events (category, value) VALUES $values',
    );
    await session.run(
      'CREATE INDEX idx_kept ON events (category) WHERE value > 0',
    );
    final full = session.objects
        .singleWhere((object) => object.name == 'idx_events_category_value');
    final partial =
        session.objects.singleWhere((object) => object.name == 'idx_kept');
    expect(full.entries, 300);
    expect(full.byteSize, greaterThan(empty.byteSize!));
    expect(partial.entries, 299);
    final image = session.exportBytes();
    final measured = measureIndex(image, full.rootPage!);
    expect(measured.entries, full.entries);
    expect(measured.bytes, full.byteSize);
  });
}
