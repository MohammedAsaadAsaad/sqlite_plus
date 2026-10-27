# sqlite_plus

A Pure Dart database engine. SQL, JSON, FTS5, R-tree, and geopoly run in the Dart VM. The production runtime has no FFI, native SQLite, or WASM.

You open an in-memory database, run bound SQL, register a Dart function, export the image, and open that image again. File databases and browser storage are separate entry points on the same engine.

Version `0.0.1-dev.1` is the current pre-release. Publication on pub.dev is planned and waits for an explicit request. Until then:

```yaml
dependencies:
  sqlite_plus:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus
      ref: main
```

```dart
import 'package:sqlite_plus/sqlite_plus.dart';

final db = await MutableSqliteDatabase.create();
```

## What the engine runs

**Queries.** `SELECT` with `INNER`, `LEFT`, `RIGHT`, `FULL`, `CROSS`, and `NATURAL` joins, `ON` and `USING`, derived tables, scalar and correlated subqueries, `EXISTS`, and `IN`. `UNION`, `UNION ALL`, `INTERSECT`, and `EXCEPT`. Ordinary, forward, and recursive CTEs. `GROUP BY`, `HAVING`, `DISTINCT`, `FILTER`, `ORDER BY`, and `LIMIT`/`OFFSET`.

**Windows.** `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `PERCENT_RANK`, `CUME_DIST`, `NTILE`, `LAG`, `LEAD`, `FIRST_VALUE`, `LAST_VALUE`, and `NTH_VALUE`, with `PARTITION BY`, `ORDER BY`, `ROWS`, `GROUPS`, and `RANGE` frames.

**Writes.** `INSERT` of `VALUES`, `DEFAULT VALUES`, and `SELECT`, including multi-row `VALUES`. `UPDATE` and `DELETE`. `OR IGNORE`, `OR REPLACE`, `OR FAIL`, and `OR ROLLBACK`. `ON CONFLICT` `DO NOTHING` and `DO UPDATE`, with `excluded` and `WHERE`. `RETURNING` on direct `INSERT`, `UPDATE`, and `DELETE`. `BEGIN`, `COMMIT`, `ROLLBACK`, and savepoints.

**Schema.** `CREATE` and `DROP` for tables, indexes, views, and triggers. `ALTER TABLE` add, rename, and drop column, and table rename. `PRIMARY KEY`, `NOT NULL`, `UNIQUE`, `CHECK`, `STRICT`, `AUTOINCREMENT`, and `WITHOUT ROWID`. `PRAGMA foreign_keys` enables foreign-key checks and actions. `BEFORE` and `AFTER` row triggers, `INSTEAD OF` view triggers, and `RAISE`. Expression indexes, partial indexes, and `VIRTUAL` or `STORED` generated columns. `TEMP` tables, indexes, views, and triggers. One `ATTACH` of `':memory:'` or a file path.

**JSON.** `json`, `jsonb`, `json_array`, `json_array_length`, `json_error_position`, `json_extract`, `json_insert`, `json_object`, `json_patch`, `json_quote`, `json_remove`, `json_replace`, `json_set`, `json_type`, `json_valid`, `json_group_array`, and `json_group_object`, plus the `jsonb_` forms of those constructors and mutators. Paths and values can be bound parameters. SQL `INTEGER` values are `BigInt`.

**Search and space.** `CREATE VIRTUAL TABLE ... USING fts5`. `MATCH`, `highlight`, `snippet`, and `bm25`. `USING rtree` for bounding boxes. `USING geopoly` with `geopoly_json`, `geopoly_blob`, `geopoly_area`, `geopoly_overlap`, and `geopoly_within`. `generate_series` as a virtual table.

**Values and time.** `CAST`, `CASE`, `LIKE`, `GLOB`, `BETWEEN`, `INSTR`, `substr`, `replace`, `trim`, `length`, `lower`, `upper`, `printf`, `abs`, `round`, `coalesce`, `nullif`, `iif`, and the compiled math functions (`sin`, `cos`, `sqrt`, `ln`, `pow`, and the rest of that set). `DATE`, `TIME`, `DATETIME`, `JULIANDAY`, `UNIXEPOCH`, `STRFTIME`, `TIMEDIFF`, and `CURRENT_DATE`, `CURRENT_TIME`, and `CURRENT_TIMESTAMP`. Aggregates include `COUNT`, `SUM`, `TOTAL`, `AVG`, `MIN`, `MAX`, `GROUP_CONCAT`, `STRING_AGG`, `median`, `percentile`, `percentile_cont`, and `percentile_disc`. Collations include `BINARY`, `NOCASE`, and `RTRIM`, and `createCollation` adds one connection-local collation.

**Your functions.** `functions.registerScalar` and `functions.registerAggregate` install synchronous Dart callbacks on that connection. A scalar used in a schema expression takes `deterministic: true`.

**Images.** `exportImage()` returns the database bytes. `MutableSqliteDatabase.fromImage` opens them. `PRAGMA user_version` and `application_id` persist in that image. `integrity_check`, `quick_check`, and `foreign_key_check` read the image you have.

**Files and the browser.** `package:sqlite_plus/sqlite_plus_io.dart` exports `DatabaseOwner` for a `dart:io` file. `openBrowserStorage` opens browser bytes and reports `canRead`, `canWrite`, `durabilityPromised`, and `placement`.

Parameters use `?`, `?NNN`, `:name`, `@name`, and `$name`. The same name shares one index. Values cross the API as `BigInt`, `double`, `String`, `Uint8List`, or `null`.

## Library tour

`example/` is a separate Dart project. `example/lib/library_tour.dart` is the program below. It stores two JSON cards, rolls back a third, highlights an FTS5 match, matches an Arabic token, selects the R-tree shelf inside the unit box, sets `user_version` to 7, and reopens the exported image.

`arabicToken` in that file is an Arabic token. The `MATCH` on it returns the title `Arabic Shelf` and a count of one. The surrounding program is:

```dart
final db = await MutableSqliteDatabase.create();
await db.execute(
    'CREATE TABLE books (id INTEGER PRIMARY KEY, card TEXT NOT NULL)');
await db.execute(
    'INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
    ['title', 'Kept Garden', 'pages', 320]);
await db.execute(
    'INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
    ['title', 'Other Atlas', 'pages', 90]);

await db.execute('BEGIN');
await db.execute(
    'INSERT INTO books(card) VALUES (json_object(?, ?, ?, ?))',
    ['title', 'Rolled Back', 'pages', 1]);
await db.execute('ROLLBACK');
final kept = await db.query('SELECT COUNT(*) FROM books');
// kept.rows.single.single == BigInt.two

final card = await db.query(
    'SELECT json_extract(card, ?), json_extract(card, ?) FROM books '
    'WHERE json_extract(card, ?) = ?',
    [r'$.title', r'$.pages', r'$.title', 'Kept Garden']);
// card.rows.single == ['Kept Garden', BigInt.from(320)]

await db.execute('CREATE VIRTUAL TABLE book_text USING fts5(title, body)');
await db.execute(
    'INSERT INTO book_text(title, body) VALUES (?, ?), (?, ?)',
    [
      'Kept Garden',
      'a garden kept in the margin',
      'Arabic Shelf',
      arabicToken,
    ]);
final text = await db.query(
    "SELECT highlight(book_text, 1, '[', ']'), bm25(book_text) "
    'FROM book_text WHERE book_text MATCH ?',
    ['kept']);
// text.rows.single[0] == 'a garden [kept] in the margin'
// text.rows.single[1] is a finite double from bm25

final arabic = await db.query(
    'SELECT title FROM book_text WHERE book_text MATCH ?', [arabicToken]);
// arabic.rows.single.single == 'Arabic Shelf'

await db.execute(
    'CREATE VIRTUAL TABLE shelves USING rtree(id, minX, maxX, minY, maxY)');
await db.execute(
    'INSERT INTO shelves VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)',
    [1, 0, 1, 0, 1, 2, 5, 6, 5, 6]);
final place = await db.query(
    'SELECT id FROM shelves '
    'WHERE minX <= ? AND maxX >= ? AND minY <= ? AND maxY >= ?',
    [1, 0, 1, 0]);
// place.rows.single.single == BigInt.one

await db.execute('PRAGMA user_version=7');
final image = db.exportImage();
final reopened = await MutableSqliteDatabase.fromImage(image);
final again = await reopened.query(
    'SELECT json_extract(card, ?) FROM books WHERE id = ?',
    [r'$.title', 1]);
final againVersion = await reopened.query('PRAGMA user_version');
// again.rows.single.single == 'Kept Garden'
// againVersion.rows.single.single == BigInt.from(7)
// image.length == 40960
```

From a checkout, after `dart pub get` at the repository root:

```sh
cd example
dart run bin/main.dart
```

The program prints:

```text
Kept Garden (320 pages) | a garden [kept] in the margin | Arabic Shelf x1 | place 1 | cards 2 | version 7 | reopen Kept Garden v7 | 40960 bytes
```

`example/test/library_tour_test.dart` checks the title, the page count, the highlighted match, the Arabic token, the shelf id, the card count, and version `7` before and after `exportImage`.

## A function written in Dart

Scalar and aggregate callbacks are connection-local. They receive SQL values and return a SQL value. This is the scalar form:

```dart
final db = await MutableSqliteDatabase.create();
db.functions.registerScalar(
  'twice',
  1,
  (args) => args.single == null ? null : (args.single as BigInt) * BigInt.two,
);
final result = await db.query('SELECT twice(?)', [21]);
// result.rows.single.single == BigInt.from(42)
```

`registerAggregate(name, argumentCount, factory)` builds a fresh `SqlAggregate` for each group. Argument count `-1` is varargs. `createCollation(name, compare)` registers one text collation beside `BINARY`, `NOCASE`, and `RTRIM`.

```dart
db.functions.createCollation('reverse', (a, b) => b.compareTo(a));
```

`ORDER BY`, a `UNIQUE` constraint, and an index can name that collation. `BINARY`, `NOCASE`, and `RTRIM` stay built in.

## A file, owned by one isolate

Import the file library only where `dart:io` exists:

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

// `path` is an existing database file. The caller also provisions the
// `-journal` sidecar, or the `-wal` sidecar when `wal` is true.
final owner = await DatabaseOwner.open(
  path,
  directoryEntriesDurable: true,
);
try {
  final version = await owner.client.query('PRAGMA user_version');
} finally {
  await owner.close();
}
```

The caller provisions the database file and its sidecar, then passes `directoryEntriesDurable: true`. That flag is the caller's attestation. `wal: true` selects the `-wal` sidecar; the default sidecar is `-journal`. `owner.client` runs `query` and `execute`. A second `DatabaseOwner.open` of the same path fails while the first owner is open. `DatabaseClient.connect(owner.sendPort)` opens another logical client. An explicit transaction belongs to the client that began it.

`exportImage` on a memory database is the byte image a file can hold. `fromImage` opens those bytes without `dart:io`.

## Browser storage

`openBrowserStorage` looks up the browser store and returns an opened storage. The caller reads `canRead`, `canWrite`, `durabilityPromised`, and `placement`. Memory and the current browser placement both report `durabilityPromised` as false. A missing browser interface opens an empty memory backend. The ORM page records a Chrome session that saved two notes, closed, reopened, and read `kept` with placement `browser`.

## Planned

`json_pretty`, correlated `json_each`, EXPLAIN bytecode, STAT4, `auto_vacuum`, a durable commit across two databases, and more journal modes are planned. The FTS plan adds multi-page leaves, porter, trigram, detail, tokendata, locale, and FTS3/FTS4 writes. ICU and locale collations, a durable browser store, Android, iOS, power-loss durability, and benchmarks at 100000 and 1000000 rows are planned. The current Linux AOT file is `benchmark_results/scenarios_10k_linux_x64.json`, at 10000 rows.

The format and SQL reference lives in the repository as `docs/REFERENCE.md`. `docs/ENGINE_SUPPORT.md` is the current baseline.
