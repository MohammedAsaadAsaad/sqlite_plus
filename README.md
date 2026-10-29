# sqlite_plus

A SQLite engine in Dart, a typed ORM, and a generator that writes the mapping. SQL, JSON, full-text search, R-tree, change tracking, and generated filters run in the Dart VM. The production runtime has no FFI, native SQLite, or WASM.

Version `0.1.1`.

```yaml
dependencies:
  sqlite_plus: ^0.1.1
  sqlite_plus_orm: ^0.1.1

dev_dependencies:
  sqlite_plus_generator: ^0.1.1
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

The same database does JSON paths, `MATCH` with `highlight`, an R-tree box, a Dart scalar function, and `exportImage()`. A file uses `openDatabase` from `sqlite_plus_io.dart`.

## Track a change

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final books = context.set(bookType);
final book = books.add(Book(BigInt.one, 'Kept Garden', '{"shelf":"north"}', 0));
await context.saveChanges();

book.title = 'Kept Garden Revised';
await context.saveChanges(); // one row, revision 1

final stored = await books.query
    .where(bookTitle.eq('Kept Garden Revised') &
        MappedField(bookNote).at(r'$.shelf').equalTo('north'))
    .single();
```

## Let the generator write the mapping

```dart
class Purchase {
  Purchase({this.id, this.customerId, required this.total});
  BigInt? id;
  BigInt? customerId;
  double total;
}

final expensive = await purchases.query
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .toList();
```

`@DbJson()` adds `path`. `@DbEntity(module: 'fts5')` adds `search`. `@DbEntity(module: 'rtree')` adds `bounds.intersects`. `customerId` becomes a `reference`.

```sh
dart run sqlite_plus_generator --input lib/models.dart
```

## One phone, one thousand rows

Bench versionCode 2009, one arm64 phone, Asia/Hebron 14:00 on 2026-10-29. The same SQL on Android SQLite and on sqlite_plus. Every checksum matched. The phone model was not in the log. Each bar is that row's measured time, on its own linear scale. The gold figure is native time divided by sqlite_plus time. This is one sample. Separate statements cross a platform channel in the native app and stay inside one isolate here.

![Memory round, 1000 rows. Bar length matches measured time.](packages/sqlite_plus/doc/bench-time.png)

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

On a file, the same sample was still faster on every operation. Search was 11×, a point lookup 14×, and `VACUUM` 71×. Inserts and separate deletes were closer, from 1.1× to 2.0×. File size is taken before close, so the sqlite_plus file still includes the redo.

![File round, 1000 rows. Bar length matches measured time.](packages/sqlite_plus/doc/bench-file.png)

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

## Packages

| Package | What you open |
|---|---|
| [`sqlite_plus`](packages/sqlite_plus) | `openInMemory`, bound SQL, JSON, FTS5, R-tree, `exportImage` |
| [`sqlite_plus_orm`](packages/sqlite_plus_orm) | `saveChanges`, revisions, JSON paths, relationships, reviewed migrations |
| [`sqlite_plus_generator`](packages/sqlite_plus_generator) | `filter`, `path`, `search`, `bounds` from ordinary classes |

`examples/compare` is Bench, the Flutter screen behind the tables. `examples/notes` is Margin, a notes desk on the ORM. Their Android packages are local build output and are not stored in this repository.

From a checkout, after `dart pub get`:

| Example | Command | Prints |
|---|---|---|
| Engine | `(cd packages/sqlite_plus/example && dart run bin/main.dart)` | `Kept Garden (320 pages)` and a reopened image of `40960` bytes |
| ORM | `(cd packages/sqlite_plus_orm/example && dart run bin/main.dart)` | `Kept Garden Revised on north, revision 1` |
| Generator | `(cd packages/sqlite_plus_generator/example && dart run bin/main.dart)` | `Ada bought [22.5, 30.0]; {"title":"kept"}; alpha kept; place 1 of 2` |

## SQL surface

| Area | Available |
|---|---|
| Queries | `INNER` `LEFT` `RIGHT` `FULL` `CROSS` `NATURAL` joins, subqueries, `EXISTS`, `IN`, `UNION` `INTERSECT` `EXCEPT`, CTEs, `GROUP BY`, `HAVING` |
| Windows | `ROW_NUMBER` `RANK` `DENSE_RANK` `PERCENT_RANK` `CUME_DIST` `NTILE` `LAG` `LEAD` `FIRST_VALUE` `LAST_VALUE` `NTH_VALUE` |
| Writes | `INSERT` `UPDATE` `DELETE`, multi-row `VALUES`, `OR IGNORE` `REPLACE` `FAIL` `ROLLBACK`, `ON CONFLICT`, `RETURNING`, `BEGIN` `COMMIT` `ROLLBACK`, savepoints |
| Schema | Tables, indexes, views, triggers, `ALTER TABLE`, `CHECK`, `STRICT`, foreign keys, expression and partial indexes, generated columns |
| JSON | `json` `jsonb` `json_array` `json_extract` `json_object` `json_set` `json_patch` and the rest of that family, plus `->` and `->>` |
| Search | FTS5 `MATCH` `highlight` `snippet` `bm25`, R-tree, geopoly, `generate_series` |
| Values | `BigInt` integers, bound `?` `:name` `@name` `$name`, `DATE` `TIME` `DATETIME` `STRFTIME`, math, `median`, `percentile` |
| Your code | `registerScalar`, `registerAggregate`, `createCollation` |

`docs/REFERENCE.md` is the statement reference. `docs/ENGINE_SUPPORT.md` is the baseline behind this table.

## Android

A debug APK ran on an Android 15 emulator, API 35, `x86_64`, with Flutter 3.47.8 and Dart 3.13.7. The log is `packages/sqlite_plus/tool/android_probe_api35_x86_64.log`.

| Check | Result |
|---|---|
| Memory SQL | JSON card `Kept Garden` / `320`, FTS5 highlight, finite `bm25`, R-tree id `1`, `user_version` `7` after reopen, `40960` bytes |
| ORM | insert `2`, update `1`, idle `0`, title `Kept Garden Revised`, revision `1` |
| File | `DatabaseOwner` in the app cache, version `7`, title `Kept Garden` |

An iOS simulator run is planned.

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

The current measurement is the 10000-row Linux AOT file `benchmark_results/scenarios_10k_linux_x64.json`. `COMPATIBILITY_MATRIX.md` is the test record.

## Develop

The workspace lockfile is at the repository root. Packages require Dart >=3.6.0. CI uses Dart 3.13.7.

```sh
dart pub get --enforce-lockfile
dart format .
python3 tool/generate_fixtures.py --verify
for package in sqlite_plus sqlite_plus_orm sqlite_plus_generator; do
  (cd packages/$package && dart analyze --fatal-infos && dart test) || exit
  (cd packages/$package/example && dart analyze --fatal-infos && dart test && dart run bin/main.dart) || exit
done
```

The Linux GitHub job runs every `tool/generate_*.py --verify` script. A checksum mismatch fails that job. Those scripts compare fixture hashes. The macOS and Windows jobs run format, fatal-info analysis, package tests, and the example project check. `CHANGELOG.md` records this version.
