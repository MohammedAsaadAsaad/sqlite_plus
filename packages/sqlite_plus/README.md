# sqlite_plus

محرك SQLite بأسلوب Pure Dart: SQL، وJSON، وFTS5، وR-tree، من غير FFI ومن غير SQLite أصلي في وقت التشغيل.

A Pure Dart database engine. SQL, JSON, FTS5, and R-tree run in the Dart VM. The production runtime has no FFI, native SQLite, or WASM.

Version `0.0.1-dev.1` is a pre-release. It is prepared for pub.dev and is not published. Until it is published, depend on the git repository:

```yaml
dependencies:
  sqlite_plus:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus
      ref: main
```

## Library tour

`example/` is a separate Dart project. `example/lib/library_tour.dart` builds one in-memory library with bound `json_object` values. It rolls back a third card, highlights an FTS5 match, matches the Arabic token `مرحبا`, finds the R-tree shelf inside the unit box, sets `user_version` to 7, and reopens the exported image with the same title and version.

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

## Limits

This is not a complete SQLite. The verified subset and the open limits are in the repository `COMPATIBILITY_MATRIX.md`. In particular:

- DQS stays off. `json_pretty` is absent. EXPLAIN bytecode throws.
- `auto_vacuum` writes are rejected. A statement cannot mutate two schemas.
- Power loss is not claimed. Android and iOS were not run.
- The 10000-row Linux AOT file is `benchmark_results/scenarios_10k_linux_x64.json` in the repository. 100000 and 1000000 rows were not run.

File databases go through `package:sqlite_plus/sqlite_plus_io.dart`. That library uses `dart:io` and is not the browser import. Browser storage is a separate, unpromised surface: `durabilityPromised` stays false.

The format and SQL reference lives in the repository as `docs/REFERENCE.md`.
