# Library tour

One in-memory database for the sqlite_plus engine.

| Step | SQL | Result |
|---|---|---|
| Insert two cards | `json_object` with bound title and page count | `Kept Garden` has `320` pages |
| Roll back a third card | `BEGIN`, insert, `ROLLBACK` | `COUNT(*)` stays `2` |
| Read a path | `json_extract` with a bound path | title `Kept Garden`, pages `320` |
| Full text | `fts5`, `highlight`, `bm25`, `MATCH` | `a garden [kept] in the margin` and a finite rank |
| Unicode token | `MATCH` on an Arabic token | title `Arabic Shelf`, count `1` |
| Spatial | `rtree` unit box | shelf id `1` |
| Reopen | `PRAGMA user_version=7`, `exportImage`, `fromImage` | title and version `7`, `40960` bytes |

This example ships with the package.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

| File | Role |
|---|---|
| `lib/library_tour.dart` | The tour |
| `bin/main.dart` | Prints the line below |
| `test/library_tour_test.dart` | Checks every row in the table |

```text
Kept Garden (320 pages) | a garden [kept] in the margin | Arabic Shelf x1 | place 1 | cards 2 | version 7 | reopen Kept Garden v7 | 40960 bytes
```

The rest of the SQL surface is in the [package README](../README.md).
