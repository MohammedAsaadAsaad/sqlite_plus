# Library tour

One in-memory database that exercises the sqlite_plus engine end to end.

The program builds a library of JSON cards, rolls an insert back, highlights a full-text match, matches an Arabic token, queries an R-tree, and reopens the exported image at the same `user_version`.

| Step | SQL | Result |
|---|---|---|
| Insert two cards | `json_object` with bound title and page count | `Kept Garden` has `320` pages |
| Roll back a third card | `BEGIN`, insert, `ROLLBACK` | `COUNT(*)` stays `2` |
| Read a path | `json_extract` with a bound path | title `Kept Garden`, pages `320` |
| Full text | `fts5`, `highlight`, `bm25`, `MATCH` | `a garden [kept] in the margin` and a finite rank |
| Unicode token | `MATCH` on an Arabic token | title `Arabic Shelf`, count `1` |
| Spatial | `rtree` unit box | shelf id `1` |
| Reopen | `PRAGMA user_version=7`, `exportImage`, `fromImage` | title and version `7` survive, `40960` bytes |

This example is its own Dart project and a workspace member. It stays in the repository. Publication of the packages is planned.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

`lib/library_tour.dart` is the tour. `bin/main.dart` prints it. `test/library_tour_test.dart` checks every value in the table above.

The program prints:

```text
Kept Garden (320 pages) | a garden [kept] in the margin | Arabic Shelf x1 | place 1 | cards 2 | version 7 | reopen Kept Garden v7 | 40960 bytes
```

The engine surface behind these calls — joins, windows, UPSERT, triggers, JSON, FTS5, R-tree, geopoly, and Dart callbacks — is in the [package README](../README.md).
