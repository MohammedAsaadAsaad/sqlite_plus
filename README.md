![sqlite_plus](packages/sqlite_plus/doc/logo.png)

# sqlite_plus

A SQLite engine in Dart, a typed ORM, and a generator for the mapping. SQL, JSON, full-text search, R-tree, change tracking, and reviewed migrations run in the Dart VM. The production runtime has no FFI, no native SQLite, and no WASM.

```yaml
dependencies:
  sqlite_plus: ^0.1.4
  sqlite_plus_orm: ^0.1.3

dev_dependencies:
  sqlite_plus_generator: ^0.1.3
```

## Query

```dart
import 'package:sqlite_plus/sqlite_plus.dart';

final db = await openInMemory();
await db.execute(
  'CREATE TABLE note (id INTEGER PRIMARY KEY, title TEXT, body TEXT)',
);
await db.execute(
  'INSERT INTO note(title, body) VALUES (?, ?)',
  ['Kept Garden', 'a garden kept in the margin'],
);
final rows = await db.query(
  'SELECT title FROM note WHERE title LIKE ?',
  ['%Garden%'],
);
```

The same database does a JSON path, `MATCH` with `highlight`, an R-tree box, a Dart function, and `exportImage()`. A file uses `openDatabase` from `sqlite_plus_io.dart`.

## Track a change

```dart
final books = context.set(BookMapping.instance);
final book = books.add(Book(title: 'Kept Garden'));
await context.saveChanges();

book.title = 'Kept Garden Revised';
await context.saveChanges(); // one row, revision 1
```

## Let the class own the schema

```dart
class Purchase {
  Purchase({this.id, this.customerId, required this.total});
  BigInt? id;
  BigInt? customerId;
  double total;
}

await context.migrations.ensureCreated();

final expensive = await purchases.query
    .selectWhere((row) => (row.total > 20.0) | (row.total.abs() > 20))
    .orderByFields((row) => [row.total.ascending])
    .select();
```

`abs` is the engine, called on the column. A method marked `@DbScalar()` is called the same way: `row.twice() > 20` reads `revision` from the model and runs that body for each row.

`ensureCreated` builds the table. A later nullable field is `plan()` then `applySafe()`. A rename or a drop is a statement you write and approve. The reverse statement is the down migration.

```sh
dart run sqlite_plus_generator
```

That scans `lib/` for every public `@DbEntity`, writes each `name.orm.g.dart`, and writes `lib/sqlite_plus_migrations.g.dart`. A class that only has an `id` field is not included. One library is still `dart run sqlite_plus_generator --input lib/models.dart`. A later run leaves an unchanged part alone and prints a summary.

![Create, add, or review.](packages/sqlite_plus_orm/doc/migrations.png)

## Speed

1,000 rows on Linux, release build. The same SQL, and every checksum matched. Each bar is measured time.

![Memory, 1,000 rows. Bar length is measured time.](packages/sqlite_plus/doc/bench-time.png)

| Operation | native | sqlite_plus | faster |
|---|---:|---:|---:|
| Separate insert | 1.896 s | 7.5 ms | 253× |
| Transaction insert | 1.841 s | 7.0 ms | 263× |
| Separate update | 1.853 s | 20.1 ms | 92× |
| Bulk update | 1.8 ms | 71 µs | 25× |
| Search | 1.864 s | 17.4 ms | 107× |
| Point lookup | 1.995 s | 25.4 ms | 79× |
| VACUUM | 2.2 ms | 77 µs | 29× |
| Separate delete | 1.777 s | 13.2 ms | 135× |
| Delete all | 1.4 ms | 159 µs | 8.8× |

On a file, search was 142×, a point lookup 104×, and `VACUUM` 175×.

![File, 1,000 rows. Bar length is measured time.](packages/sqlite_plus/doc/bench-file.png)

## Packages

| Package | Start here |
|---|---|
| [`sqlite_plus`](packages/sqlite_plus) | SQL, JSON, FTS5, R-tree, `abs`, `exportImage`, SQLCipher 4 |
| [`sqlite_plus_orm`](packages/sqlite_plus_orm) | Saves, revisions, `row.twice()`, migrations |
| [`sqlite_plus_generator`](packages/sqlite_plus_generator) | Classes in, `filter`, `path`, `@DbScalar`, `search`, and `bounds` out |

| You want | Command |
|---|---|
| The engine tour | `(cd packages/sqlite_plus/example && dart run bin/main.dart)` |
| The reading log | `(cd packages/sqlite_plus_orm/example && dart run bin/main.dart)` |
| The generated library | `(cd packages/sqlite_plus_generator/example && dart run bin/main.dart)` |

## SQL

Joins through `FULL`, subqueries, `UNION` `INTERSECT` `EXCEPT`, CTEs, windows, `ON CONFLICT`, `RETURNING`, views, triggers, `CHECK`, `STRICT`, foreign keys, JSON, FTS5, R-tree, and geopoly. Integers are `BigInt`. `docs/REFERENCE.md` is the statement list.

`SqlCipherDatabase.create('secret')` writes a SQLCipher 4 image. `encryptedImage()` is the file. `database.exportImage()` is the decrypted SQLite image. The default key schedule is PBKDF2-HMAC-SHA512 for 256000 iterations, AES-256-CBC, and HMAC-SHA512, with an 80-byte reserve. Derivation runs when the database is created or opened. A later export reuses those keys. `saveSqlCipher` replaces the whole file. WAL files, SQLCipher 1–3, rekey, a plaintext header, and auto-vacuum with the reserve stay outside this codec.

Compared with pinned SQLite 3.53.1: constant `EXPLAIN` arithmetic, a constant `WHERE`, one table scan, a constant subquery, an integer-primary-key scan, `WITHOUT ROWID`, a virtual generated column, a typed `INSERT`, and a multi-row `VALUES` insert. An integer-primary-key insert and a join of two subqueries still have no bytecode. This is not a VDBE. Contentless FTS4 returns the pinned `MATCH` row and stores no content table. File `journal_mode` `wal`, `persist`, and `truncate` follow the pinned header and journal bytes. This is not a multi-frame WAL. `incremental_vacuum` moves a live end page before truncating. ICU collations are absent. `json_pretty` and correlated `json_each` are in the engine. `json_each(docs.label) RIGHT JOIN docs` returns 0 rows, matching the pinned CLI. Double quotes stay identifiers unless `doubleQuotedStrings` is set. That mode matches the pinned CLI for the cases in `db_browser_b3_dqs_test.dart`. Unquoted `a.title` beside a column named `a.title` returns the `title` column, matching the pinned CLI.

## Develop

Packages require Dart >=3.6.0. From the repository root:

```sh
dart pub get --enforce-lockfile
dart format .
for package in sqlite_plus sqlite_plus_orm sqlite_plus_generator; do
  (cd packages/$package && dart analyze --fatal-infos && dart test) || exit
done
```
