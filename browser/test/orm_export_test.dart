import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite_plus_browser/src/orm_export.dart';
import 'package:sqlite_plus_browser/src/session.dart';

void main() {
  test('an open database exports generator classes', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run(
      'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)',
    );
    await session.run(
      'CREATE TABLE books ('
      'AlbumId INTEGER PRIMARY KEY, '
      'title TEXT NOT NULL, '
      'pages INTEGER, '
      'author_id INTEGER REFERENCES authors(id) ON DELETE CASCADE, '
      'cover BLOB)',
    );
    await session.run(
      'CREATE TABLE pair (a INTEGER, b INTEGER, PRIMARY KEY (a, b))',
    );
    await session.run('CREATE VIRTUAL TABLE docs USING fts5(body)');
    await session.run('CREATE VIEW names AS SELECT name FROM authors');
    final source = ormModels(session.objects);
    expect(source, startsWith("import 'dart:typed_data';\n"));
    expect(
      source,
      contains("import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';"),
    );
    expect(source, contains('dart run sqlite_plus_generator'));
    expect(source, isNot(contains('--input')));
    expect(source, contains('lib/models.dart'));
    expect(source, contains('sqlite_plus_migrations.g.dart'));
    expect(source, contains("@DbEntity(table: 'authors')"));
    expect(source, contains('class Authors {'));
    expect(source, contains('@DbKey(generated: true)'));
    expect(source, contains('final BigInt? id;'));
    expect(source, contains('@DbColumn(unique: true)'));
    expect(source, contains('required this.name'));
    expect(source, contains('final String name;'));
    expect(source, contains("@DbEntity(table: 'books')"));
    expect(source, contains("@DbColumn(name: 'AlbumId')"));
    expect(source, contains('final BigInt? albumId;'));
    expect(source, contains('required this.title'));
    expect(source, contains('final String title;'));
    expect(source, contains('final BigInt? pages;'));
    expect(
      source,
      contains(
        '@DbReference(Authors, onDelete: ForeignKeyAction.cascade)',
      ),
    );
    expect(source, contains('final Uint8List? cover;'));
    expect(source, contains('@DbKey(order: 0)'));
    expect(source, contains('@DbKey(order: 1)'));
    expect(source, contains('class Pair {'));
    expect(source, contains('docs is a virtual table'));
    expect(source, contains('Internal tables of docs were left out.'));
    expect(source, contains('View names is not a generated class.'));
    expect(source, isNot(contains("table: 'docs'")));
    expect(source, isNot(contains("table: 'docs_content'")));
    expect(source, isNot(contains('class Names')));
    final parts = splitModelLibrary(source);
    expect(parts.classes.map((block) => block.name), [
      'Authors',
      'Books',
      'Pair',
    ]);
    expect(parts.classes[1].table, 'books');
    expect(parts.imports.first, "import 'dart:typed_data';");
    expect(
      parts.notes,
      contains(
        'docs is a virtual table. Write its fts5, rtree, or vec0 class by hand.',
      ),
    );
    expect(parts.notes, contains('View names is not a generated class.'));
    expect(parts.notes.join('\n'), isNot(contains('dart run')));
  });

  test('a table without a primary key is owned through its rowid', () async {
    final session = BrowserSession();
    await session.openEmpty();
    addTearDown(session.close);
    await session.run('CREATE TABLE boundary (name TEXT NOT NULL, geom BLOB)');
    await session.run('CREATE TABLE tagged (rowid TEXT, name TEXT)');
    await session
        .run('CREATE TABLE shadowed (rowid TEXT, oid INTEGER, name TEXT)');
    await session.run(
      'CREATE TABLE occupied (rowid TEXT, oid INTEGER, _rowid_ REAL, name TEXT)',
    );
    await session.run(
      'CREATE TABLE closed (id INTEGER PRIMARY KEY, name TEXT) WITHOUT ROWID',
    );
    final source = ormModels(session.objects);
    expect(source, contains("@DbEntity(table: 'boundary')"));
    expect(source, contains('class Boundary {'));
    expect(
      source,
      contains('SQLite row id. boundary has no PRIMARY KEY.'),
    );
    expect(source, contains('@DbKey(generated: true)'));
    expect(source, contains('final BigInt? rowid;'));
    expect(source, contains('required this.name'));
    expect(source, contains('final Uint8List? geom;'));
    expect(source, contains("@DbEntity(table: 'tagged')"));
    expect(source, contains('final BigInt? oid;'));
    expect(source, contains('final String? rowid;'));
    expect(source, contains("@DbColumn(name: '_rowid_')"));
    expect(source, contains('final BigInt? rowid;'));
    expect(source, contains("@DbColumn(name: 'rowid')"));
    expect(source, contains('final String? rowid2;'));
    expect(
      source,
      contains(
        'occupied uses the names rowid, oid, and _rowid_ as columns, so the generator cannot name its row id.',
      ),
    );
    expect(source, isNot(contains("table: 'occupied'")));
    expect(source, contains("@DbEntity(table: 'closed')"));
    expect(source, contains('@DbKey()\n  final BigInt id;'));
    expect(source, isNot(contains('closed has no primary key')));
    final parts = splitModelLibrary(source);
    expect(parts.classes.map((block) => block.table), [
      'boundary',
      'closed',
      'shadowed',
      'tagged',
    ]);
  });
}
