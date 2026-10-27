# sqlite_plus

A Pure Dart database engine. SQL, JSON, FTS5, and R-tree run in the Dart VM. The production runtime has no FFI, native SQLite, or WASM.

Version `0.0.1-dev.1` is the current pre-release. Publication on pub.dev is planned and waits for an explicit request. Until then, depend on the git repository:

```yaml
dependencies:
  sqlite_plus:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus
      ref: main
```

## Library tour

`example/` is a separate Dart project. `example/lib/library_tour.dart` builds one in-memory library with bound `json_object` values. It rolls back a third card, highlights an FTS5 match, matches an Arabic token, finds the R-tree shelf inside the unit box, sets `user_version` to 7, and reopens the exported image with the same title and version.

```dart
final db = await MutableSqliteDatabase.create();
await db.execute(
    'CREATE TABLE books (id INTEGER PRIMARY KEY, card TEXT NOT NULL)');
await db.execute(
    "INSERT INTO books(card) VALUES ('{\"title\":\"Kept Garden\",\"pages\":320}')");
final card = await db.query(
    "SELECT json_extract(card, '\$.title') FROM books WHERE id = 1");
await db.execute('CREATE VIRTUAL TABLE book_text USING fts5(title, body)');
await db.execute(
    "INSERT INTO book_text(title, body) VALUES ('Kept Garden', 'a garden kept in the margin')");
final text = await db.query(
    "SELECT highlight(book_text, 1, '[', ']') FROM book_text WHERE book_text MATCH 'kept'");
```

From a checkout, after `dart pub get` at the repository root:

```sh
cd example
dart run bin/main.dart
```

The tour test checks `Kept Garden`, 320 pages, `a garden [kept] in the margin`, `Arabic Shelf`, two cards after rollback, shelf id `1`, version `7` before and after `exportImage`.

## Planned

`json_pretty`, correlated `json_each`, EXPLAIN bytecode, STAT4, `auto_vacuum`, a durable commit across two databases, and more journal modes are planned. The FTS plan adds multi-page leaves, porter, trigram, detail, tokendata, locale, and FTS3/FTS4 writes. ICU and locale collations, Android, iOS, power-loss durability, and benchmarks at 100000 and 1000000 rows are planned. The current Linux AOT file is `benchmark_results/scenarios_10k_linux_x64.json`, at 10000 rows.

File databases use `package:sqlite_plus/sqlite_plus_io.dart`. Browser storage reports `canRead`, `canWrite`, `durabilityPromised`, and `placement`. A durable browser store is planned.

The format and SQL reference lives in the repository as `docs/REFERENCE.md`.
