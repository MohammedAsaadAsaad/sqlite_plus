![sqlite_plus](packages/sqlite_plus/doc/logo.png)

# sqlite_plus

A SQLite engine in Dart, a typed ORM, and a generator for the mapping. SQL, JSON, full-text search, R-tree, change tracking, and reviewed migrations run in the Dart VM. The production runtime has no FFI, no native SQLite, and no WASM.

```yaml
dependencies:
  sqlite_plus: ^0.1.2
  sqlite_plus_orm: ^0.1.2

dev_dependencies:
  sqlite_plus_generator: ^0.1.2
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
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .toList();
```

`ensureCreated` builds the table. A later nullable field is `plan()` then `applySafe()`. A rename or a drop is a statement you write and approve. The reverse statement is the down migration.

```sh
dart run sqlite_plus_generator --input lib/models.dart
```

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
| [`sqlite_plus`](packages/sqlite_plus) | SQL, JSON, FTS5, R-tree, `exportImage` |
| [`sqlite_plus_orm`](packages/sqlite_plus_orm) | Saves, revisions, and migrations |
| [`sqlite_plus_generator`](packages/sqlite_plus_generator) | Classes in, `filter`, `path`, `search`, and `bounds` out |

| You want | Command |
|---|---|
| The engine tour | `(cd packages/sqlite_plus/example && dart run bin/main.dart)` |
| The reading log | `(cd packages/sqlite_plus_orm/example && dart run bin/main.dart)` |
| The generated library | `(cd packages/sqlite_plus_generator/example && dart run bin/main.dart)` |

## SQL

Joins through `FULL`, subqueries, `UNION` `INTERSECT` `EXCEPT`, CTEs, windows, `ON CONFLICT`, `RETURNING`, views, triggers, `CHECK`, `STRICT`, foreign keys, JSON, FTS5, R-tree, and geopoly. Integers are `BigInt`. `docs/REFERENCE.md` is the statement list.

Not in this release: `json_pretty`, correlated `json_each`, EXPLAIN bytecode, a durable two-database commit, and ICU collations.

## Develop

Packages require Dart >=3.6.0. From the repository root:

```sh
dart pub get --enforce-lockfile
dart format .
for package in sqlite_plus sqlite_plus_orm sqlite_plus_generator; do
  (cd packages/$package && dart analyze --fatal-infos && dart test) || exit
done
```
