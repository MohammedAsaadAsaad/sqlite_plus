# sqlite_plus

SQL, JSON, full-text search, and R-tree, written in Dart. The production runtime has no FFI, native SQLite, or WASM.

Version `0.1.1`.

```yaml
dependencies:
  sqlite_plus: ^0.1.1
```

```dart
import 'package:sqlite_plus/sqlite_plus.dart';

final db = await openInMemory();
```

## Write a row, read it back

```dart
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

Integers come back as `BigInt`. Parameters are `?`, `:name`, `@name`, and `$name`.

## JSON, search, and a map

```dart
await db.execute(
  'CREATE TABLE books (id INTEGER PRIMARY KEY, card TEXT NOT NULL)',
);
await db.execute(
  'INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
  ['title', 'Kept Garden', 'pages', 320],
);
final card = await db.query(
  'SELECT json_extract(card, ?) FROM books WHERE json_extract(card, ?) = ?',
  [r'$.pages', r'$.title', 'Kept Garden'],
);

await db.execute('CREATE VIRTUAL TABLE book USING fts5(title, body)');
await db.execute(
  'INSERT INTO book(title, body) VALUES (?, ?)',
  ['Kept Garden', 'a garden kept in the margin'],
);
final hit = await db.query(
  "SELECT highlight(book, 1, '[', ']') FROM book WHERE book MATCH ?",
  ['kept'],
);

await db.execute(
  'CREATE VIRTUAL TABLE shelf USING rtree(id, minX, maxX, minY, maxY)',
);
await db.execute(
  'INSERT INTO shelf VALUES (?, ?, ?, ?, ?)',
  [1, 0, 1, 0, 1],
);
final place = await db.query(
  'SELECT id FROM shelf WHERE minX <= ? AND maxX >= ? AND minY <= ? AND maxY >= ?',
  [1, 0, 1, 0],
);
```

`card` is `320`. `hit` is `a garden [kept] in the margin`. `place` is shelf `1`.

`BEGIN` / `ROLLBACK` drops a row that never committed. `PRAGMA user_version=7`, then `exportImage()` and `MutableSqliteDatabase.fromImage`, reopen the same title at version `7`. The library tour in `example/lib/library_tour.dart` prints that whole path, including an Arabic token match.

## A function you write

```dart
db.functions.registerScalar(
  'twice',
  1,
  (args) => args.single == null ? null : (args.single as BigInt) * BigInt.two,
);
final doubled = await db.query('SELECT twice(?)', [21]);
```

`doubled` is `42`. The callback stays on that connection.

## A file

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

final owner = await openDatabase(path, directoryEntriesDurable: true);
final version = await owner.client.query('PRAGMA user_version');
await owner.close();
```

`openDatabase` is `DatabaseOwner.open`. It needs `dart:io`, and the file plus its journal sidecar already exist.

## One phone, one thousand rows

Bench versionCode 2009, one arm64 phone, Asia/Hebron 14:00 on 2026-10-29. The same SQL on both engines, and every checksum matched. The phone model was not in the log. Each row has its own linear scale, so the bar is the measured time. The gold figure is native time divided by sqlite_plus time. This is one sample, not a multi-device study. Separate statements cross a platform channel in the native app and stay inside one isolate here.

![Memory round, 1000 rows. Bar length matches measured time.](doc/bench-time.png)

| Operation | native | sqlite_plus | faster |
|---|---:|---:|---:|
| Separate insert | 99.0 ms | 5.0 ms | 20× |
| Transaction insert | 82.1 ms | 2.1 ms | 39× |
| Separate update | 92.4 ms | 10.7 ms | 8.6× |
| Bulk update | 336 µs | 106 µs | 3.2× |
| Search | 108.0 ms | 6.5 ms | 17× |
| Point lookup | 97.7 ms | 9.6 ms | 10× |
| VACUUM | 781 µs | 10 µs | 78× |
| Separate delete | 93.7 ms | 7.3 ms | 13× |
| Delete all | 195 µs | 97 µs | 2.0× |

The same sample on a file was faster on every operation as well. Search was 11×, a point lookup 14×, and `VACUUM` 71×. Inserts and separate deletes were closer, from 1.1× to 2.0×.

![File round, 1000 rows. Bar length matches measured time.](doc/bench-file.png)

| Operation | native | sqlite_plus | faster |
|---|---:|---:|---:|
| Separate insert | 326.8 ms | 162.2 ms | 2.0× |
| Transaction insert | 81.0 ms | 72.6 ms | 1.1× |
| Separate update | 477.6 ms | 381.2 ms | 1.3× |
| Bulk update | 915 µs | 246 µs | 3.7× |
| Search | 129.4 ms | 11.7 ms | 11× |
| Point lookup | 105.9 ms | 7.6 ms | 14× |
| VACUUM | 923 µs | 13 µs | 71× |
| Separate delete | 413.8 ms | 345.5 ms | 1.2× |
| Delete all | 773 µs | 259 µs | 3.0× |

File size is taken before close, so the sqlite_plus file still includes the redo. Separate delete was 603.6 KB against the native 16.0 KB.

## Install

The package is already in the snippet above. From a checkout, after `dart pub get` at the repository root:

```sh
cd example
dart run bin/main.dart
```

```text
Kept Garden (320 pages) | a garden [kept] in the margin | Arabic Shelf x1 | place 1 | cards 2 | version 7 | reopen Kept Garden v7 | 40960 bytes
```

## Reference

| Entry | Library | Use it for |
|---|---|---|
| `openInMemory` | `sqlite_plus.dart` | A new in-memory database. Same function as `MutableSqliteDatabase.create` |
| `MutableSqliteDatabase.fromImage` | `sqlite_plus.dart` | Reopen `exportImage()` bytes |
| `db.query` / `db.execute` | `sqlite_plus.dart` | Bound SQL |
| `db.functions` | `sqlite_plus.dart` | Scalar, aggregate, and collation callbacks |
| `openDatabase` | `sqlite_plus_io.dart` | A `dart:io` file, on its own isolate |
| `openBrowserStorage` | `sqlite_plus.dart` | Browser bytes. Read `canRead`, `canWrite`, `durabilityPromised`, `placement` |

## Queries

| Piece | Forms |
|---|---|
| Joins | `INNER`, `LEFT`, `RIGHT`, `FULL`, `CROSS`, `NATURAL`, `ON`, `USING`, derived tables |
| Subqueries | Scalar, correlated, `EXISTS`, `IN` |
| Compounds | `UNION`, `UNION ALL`, `INTERSECT`, `EXCEPT` |
| CTE | Ordinary, `WITH`, recursive |
| Grouping | `GROUP BY`, `HAVING`, `DISTINCT`, `FILTER`, `ORDER BY`, `LIMIT`, `OFFSET` |
| Windows | `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `PERCENT_RANK`, `CUME_DIST`, `NTILE`, `LAG`, `LEAD`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE` |
| Frames | `PARTITION BY`, `ROWS`, `GROUPS`, `RANGE` |
| Predicates | `CASE`, `CAST`, `LIKE`, `GLOB`, `BETWEEN`, `IN` lists |

## Writes and schema

| Piece | Forms |
|---|---|
| Rows | `INSERT VALUES`, multi-row `VALUES`, `DEFAULT VALUES`, `INSERT SELECT`, `UPDATE`, `DELETE` |
| Conflict | `OR IGNORE`, `OR REPLACE`, `OR FAIL`, `OR ROLLBACK`, `ON CONFLICT DO NOTHING`, `ON CONFLICT DO UPDATE` |
| Returning | `RETURNING` on direct `INSERT`, `UPDATE`, and `DELETE` |
| Transactions | `BEGIN`, `COMMIT`, `ROLLBACK`, savepoints |
| Objects | `CREATE` and `DROP` for `TABLE`, `INDEX`, `VIEW`, `TRIGGER`, plus `TEMP` copies |
| Alter | Add, rename, and drop column. Rename table |
| Rules | `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `CHECK`, `STRICT`, `AUTOINCREMENT`, `WITHOUT ROWID`, foreign keys |
| Triggers | `BEFORE`, `AFTER`, `INSTEAD OF`, `RAISE` |
| Indexes | Secondary, expression, partial. `VIRTUAL` and `STORED` generated columns |
| Attach | One `ATTACH` of `':memory:'` or a file path |

Parameters are `?`, `?NNN`, `:name`, `@name`, and `$name`. A repeated name shares one index. Values are `BigInt`, `double`, `String`, `Uint8List`, or `null`.

## JSON, search, and time

| Group | Functions and modules |
|---|---|
| JSON text | `json`, `json_array`, `json_array_length`, `json_error_position`, `json_extract`, `json_insert`, `json_object`, `json_patch`, `json_quote`, `json_remove`, `json_replace`, `json_set`, `json_type`, `json_valid` |
| JSON aggregates | `json_group_array`, `json_group_object` |
| JSONB | The `jsonb_` form of the constructors, mutators, and group functions |
| JSON operators | `->`, `->>` |
| JSON tables | `json_each`, `json_tree` for a constant argument |
| FTS5 | `CREATE VIRTUAL TABLE ... USING fts5`, `MATCH`, `highlight`, `snippet`, `bm25` |
| Spatial | `USING rtree`, `USING geopoly`, `geopoly_json`, `geopoly_blob`, `geopoly_area`, `geopoly_overlap`, `geopoly_within` |
| Series | `generate_series` |
| Clock | `DATE`, `TIME`, `DATETIME`, `JULIANDAY`, `UNIXEPOCH`, `STRFTIME`, `TIMEDIFF`, `CURRENT_DATE`, `CURRENT_TIME`, `CURRENT_TIMESTAMP` |
| Numbers | `abs`, `round`, math (`sin`, `sqrt`, `ln`, `pow`, and the rest of that set), `median`, `percentile`, `percentile_cont`, `percentile_disc` |
| Text | `instr`, `substr`, `replace`, `trim`, `length`, `lower`, `upper`, `printf`, `concat`, `coalesce`, `nullif`, `iif` |
| Aggregates | `COUNT`, `SUM`, `TOTAL`, `AVG`, `MIN`, `MAX`, `GROUP_CONCAT`, `STRING_AGG` |

## Dart callbacks

```dart
final db = await openInMemory();
db.functions.registerScalar(
  'twice',
  1,
  (args) => args.single == null ? null : (args.single as BigInt) * BigInt.two,
);
final result = await db.query('SELECT twice(?)', [21]);
```

| Call | Effect |
|---|---|
| `registerScalar(name, argumentCount, callback)` | One connection-local function. `deterministic: true` allows it inside a schema expression |
| `registerAggregate(name, argumentCount, factory)` | A fresh `SqlAggregate` per group. `-1` is varargs |
| `createCollation(name, compare)` | One text collation beside `BINARY`, `NOCASE`, and `RTRIM` |

`ORDER BY`, `UNIQUE`, and an index can name the collation from `createCollation`.

## Files

Import the file library only where `dart:io` exists.

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

// `path` is an existing database file. The caller also provisions the
// `-journal` sidecar, or the `-wal` sidecar when `wal` is true.
final owner = await openDatabase(path, directoryEntriesDurable: true);
try {
  final version = await owner.client.query('PRAGMA user_version');
} finally {
  await owner.close();
}
```

| Argument | Meaning |
|---|---|
| `path` | An existing database file |
| `directoryEntriesDurable: true` | The caller attests that the file and its sidecar are provisioned |
| `wal: false` | Default. The sidecar is `-journal` |
| `wal: true` | The sidecar is `-wal` |
| `owner.client` | `query` and `execute` for this owner |
| `DatabaseClient.connect(owner.sendPort)` | Another logical client of the same owner |

A second `openDatabase` of the same path fails while the first owner is open. `DatabaseOwner.open` is that same function. An explicit transaction belongs to the client that began it. `exportImage` on a memory database is the byte image a file can hold.

## Browser

| Field | What you read |
|---|---|
| `canRead` | The opened store accepts reads |
| `canWrite` | The opened store accepts writes |
| `durabilityPromised` | `false` for memory and for the current browser placement |
| `placement` | `memory` or `browser` |

`openBrowserStorage` looks up the browser store. A missing interface opens an empty memory backend. The ORM records a Chrome session on Linux that saved two notes, closed, reopened, and read `kept` with placement `browser`. The page text is `packages/sqlite_plus_orm/tool/chrome_orm_linux_x64.log`.

## Android

| Item | Recorded run |
|---|---|
| Image | Android 15, API 35, `x86_64` emulator |
| Toolchain | Flutter 3.47.8, Dart 3.13.7, debug APK |
| Memory | JSON card, FTS5 highlight, finite `bm25`, R-tree id `1`, `user_version` `7` after `fromImage`, `40960` bytes |
| File | `DatabaseOwner.open` in the app cache, version `7`, title `Kept Garden` |

The line is `tool/android_probe_api35_x86_64.log`. An iOS simulator run is planned.

## Planned

| Area | Next |
|---|---|
| JSON | `json_pretty`, correlated `json_each` |
| Planner | EXPLAIN bytecode, STAT4, `auto_vacuum` |
| Durability | A durable commit across two databases, more journal modes, power-loss durability, a durable browser store |
| FTS | Multi-page leaves, porter, trigram, detail, tokendata, locale, FTS3/FTS4 writes |
| Collations | ICU and locale collations |
| Platforms | iOS |
| Scale | Benchmarks at 100000 and 1000000 rows |

The current Linux AOT file is `benchmark_results/scenarios_10k_linux_x64.json`, at 10000 rows. The statement reference is `docs/REFERENCE.md`.
