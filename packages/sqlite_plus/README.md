# sqlite_plus

A Pure Dart database engine. SQL, JSON, FTS5, R-tree, and geopoly run in the Dart VM. The production runtime has no FFI, native SQLite, or WASM.

Version `0.0.2`.

One arm64 phone, 1000 rows, the same SQL, and every checksum matched. The phone model was not recorded. Each time bar is linear for that row, so a 79× gap is 79 times shorter. The figure is native time divided by sqlite_plus time.

![1000 rows on one arm64 phone. Bar length matches measured statement time.](doc/bench-time.png)

![Stored size for the same 1000-row statements, on one linear scale.](doc/bench-size.png)

| Operation | native | sqlite_plus | faster |
|---|---:|---:|---:|
| Separate insert | 514.9 ms | 6.5 ms | 79× |
| Transaction insert | 104.6 ms | 3.5 ms | 30× |
| Separate update | 508.2 ms | 247.5 ms | 2.1× |
| Bulk update | 1.3 ms | 92 µs | 14× |
| Search | 126.3 ms | 7.6 ms | 17× |
| Point lookup | 116.2 ms | 9.6 ms | 12× |
| VACUUM | 1.2 ms | 9 µs | 133× |
| Separate delete | 352.7 ms | 168.0 ms | 2.1× |
| Delete all | 732 µs | 105 µs | 7.0× |

These are statement intervals from one sample, versionCode 2003. Native kept a file. sqlite_plus kept memory. They are not the memory pair or the file pair Bench records now. They are not a multi-device study, and they are not a claim that every workload is faster. Separate statements cross a platform channel in the native app and stay inside one isolate here.

## Install

```yaml
dependencies:
  sqlite_plus: ^0.0.2
```

```dart
import 'package:sqlite_plus/sqlite_plus.dart';

final db = await MutableSqliteDatabase.create();
```

| Entry | Library | Use it for |
|---|---|---|
| `MutableSqliteDatabase.create` | `sqlite_plus.dart` | A new in-memory database |
| `MutableSqliteDatabase.fromImage` | `sqlite_plus.dart` | Reopen `exportImage()` bytes |
| `db.query` / `db.execute` | `sqlite_plus.dart` | Bound SQL. Integers come back as `BigInt` |
| `db.functions` | `sqlite_plus.dart` | Scalar, aggregate, and collation callbacks |
| `DatabaseOwner.open` | `sqlite_plus_io.dart` | A `dart:io` file, on its own isolate |
| `openBrowserStorage` | `sqlite_plus.dart` | Browser bytes. Read `canRead`, `canWrite`, `durabilityPromised`, `placement` |

## Library tour

`example/lib/library_tour.dart` is a separate Dart project. One database holds JSON cards, an FTS5 index, and an R-tree. `arabicToken` in that file is an Arabic token.

| Check | Value |
|---|---|
| Title | `Kept Garden` |
| Pages | `320` |
| Cards after rollback | `2` |
| Highlight | `a garden [kept] in the margin` |
| `bm25` | a finite double |
| Arabic token | title `Arabic Shelf`, count `1` |
| R-tree shelf inside the unit box | `1` |
| `user_version` before and after reopen | `7` |
| Image length | `40960` bytes |

```dart
await db.execute(
    'CREATE TABLE books (id INTEGER PRIMARY KEY, card TEXT NOT NULL)');
await db.execute(
    'INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
    ['title', 'Kept Garden', 'pages', 320]);
await db.execute('BEGIN');
await db.execute(
    'INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
    ['title', 'Rolled Back', 'pages', 1]);
await db.execute('ROLLBACK');

final card = await db.query(
    'SELECT json_extract(card, ?), json_extract(card, ?) FROM books '
    'WHERE json_extract(card, ?) = ?',
    [r'$.title', r'$.pages', r'$.title', 'Kept Garden']);

await db.execute('CREATE VIRTUAL TABLE book_text USING fts5(title, body)');
await db.execute(
    'INSERT INTO book_text(title, body) VALUES (?, ?), (?, ?)',
    ['Kept Garden', 'a garden kept in the margin', 'Arabic Shelf', arabicToken]);
final text = await db.query(
    "SELECT highlight(book_text, 1, '[', ']'), bm25(book_text) "
    'FROM book_text WHERE book_text MATCH ?',
    ['kept']);

await db.execute(
    'CREATE VIRTUAL TABLE shelves USING rtree(id, minX, maxX, minY, maxY)');
await db.execute(
    'INSERT INTO shelves VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
    [1, 0, 1, 0, 1, 2, 5, 6, 5, 6]);
final place = await db.query(
    'SELECT id FROM shelves WHERE minX <= ? AND maxX >= ? AND minY <= ? AND maxY >= ?',
    [1, 0, 1, 0]);

await db.execute('PRAGMA user_version=7');
final image = db.exportImage();
final reopened = await MutableSqliteDatabase.fromImage(image);
```

From a checkout, after `dart pub get` at the repository root:

```sh
cd example
dart run bin/main.dart
```

```text
Kept Garden (320 pages) | a garden [kept] in the margin | Arabic Shelf x1 | place 1 | cards 2 | version 7 | reopen Kept Garden v7 | 40960 bytes
```

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
final db = await MutableSqliteDatabase.create();
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
final owner = await DatabaseOwner.open(path, directoryEntriesDurable: true);
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

A second `DatabaseOwner.open` of the same path fails while the first owner is open. An explicit transaction belongs to the client that began it. `exportImage` on a memory database is the byte image a file can hold.

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
