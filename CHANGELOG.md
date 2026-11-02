# Changelog

## 0.1.4

`sqlite_plus_generator` is version `0.1.4`. `sqlite_plus` and `sqlite_plus_orm` stay `0.1.3`. The generator suite passed 60 tests on Dart 3.13.7, Linux x64. The engine and ORM suites were not re-run.

From the package root:

```sh
dart run sqlite_plus_generator
```

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

@DbEntity()
class Book {
  Book({this.id, required this.title});
  final BigInt? id;
  final String title;
}
```

The command writes `lib/book.orm.g.dart`, adds `part 'book.orm.g.dart';` when it is missing, and writes `lib/sqlite_plus_migrations.g.dart`. A class with only an `id` field is not included.

```dart
import 'package:your_app/book.dart' hide generatedModel;
import 'package:your_app/sqlite_plus_migrations.g.dart';

final context = DbContext(connection, generatedModel);
await context.migrations.ensureCreated();
```

A later run leaves a matching part unchanged and ends with a summary of created, updated, and unchanged files. `--input lib/models.dart` still generates one library. The engine and ORM packages are not part of this release.

## 0.1.3

`sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.3`. The pub.dev API lists `0.1.3` as latest for the three packages. `packages/sqlite_plus` passed 10596 tests on Dart 3.13.7, Linux x64, against pinned SQLite 3.53.1 (`2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`). The ORM package passed 185 tests. The generator package passed 58 tests.

- Incremental auto-vacuum keeps the freelist page after an overflow delete. `incremental_vacuum` moves a live end page, then truncates.
- Contentless FTS4 (`content=''`) stores no content table. `MATCH` returns the pinned docid. A scan or a content-column read is `SQL logic error`. An insert without a docid is `constraint failed`. FTS3 `content=''` is a column named `content`.
- File `journal_mode` `wal`, `persist`, and `truncate` follow the pinned header and journal bytes. `wal` sets header bytes 18 and 19 to 2 and leaves no `-wal` file. `persist` leaves a journal whose first 28 bytes are 0. `truncate` leaves a zero-length journal. A hot official journal rolls back. This is not a multi-frame WAL log.
- Cross-schema `VALUES` errors use the pinned text: `no such table: missing`, `sub-select returns 2 columns - expected 1`, and `table aux.u has 2 columns but 1 values were supplied`.
- `EXPLAIN` matches the pinned opcode rows for a constant subquery, an integer-primary-key scan, `WITHOUT ROWID`, a virtual generated column, a typed `INSERT`, and a multi-row `VALUES` insert. An integer-primary-key insert and a join of two subqueries still throw `EXPLAIN bytecode is not implemented`. This is not a VDBE.
- Margin notes exports CSV, imports those rows as new notes, and plots one bar per UTC update day. `examples/notes/tool/note_exchange_check.dart` passed. The Flutter widgets were not executed on this machine.
- The ORM calls a model method from a query. `@DbScalar() BigInt? twice() => revision * BigInt.two` is `row.twice() > 20`. Engine scalars sit on the column: `row.revision.abs()`, `row.title.upper()`, `row.title.length()`. The generator writes the method onto the query row.

Still open: the two-database commit record is the engine schema-commit file, not an official SQLite master journal. B5 stays unchecked until those Flutter widgets run. M9 stays unchecked. The scenario harness rejects a row count above 10000. iOS, macOS, Windows, and power loss were not run for this revision. Item 108 stays open. The three packages were uploaded as `0.1.3`.

## 0.1.2

`sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.2`. This release records performance work and a Linux desktop experiment: a release build, 1,000 rows, every checksum matched. The package pages show that sample and the new logo.

## 0.1.1

`sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.1`. The package pages lead with practical samples.

## 0.1.0

`sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.0`. `openInMemory` is `MutableSqliteDatabase.create`. `openDatabase` is `DatabaseOwner.open`. The previous names remain.

## 0.0.3

`sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.0.3`. Android APKs are gitignored.

## 0.0.2

`sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.0.2`.

## 0.0.1-dev.1

This version is `0.0.1-dev.1` in `sqlite_plus`, `sqlite_plus_orm`, and
`sqlite_plus_generator`. The three packages are prepared for pub.dev at this
pre-release.

### Verified in this tree

- Pure Dart engine, ORM, and generator for the subsets named in
  `COMPATIBILITY_MATRIX.md`. Production runtime has no FFI, native SQLite, or
  WASM SQLite.
- Linux x64 on Dart 3.13.7: this revision passed 10496 engine tests, 169 ORM
  tests, and 53 generator tests. The pinned SQLite CLI was present. Each
  package has an example project under `example/` with `pubspec.yaml`,
  `lib/`, `bin/main.dart`, and `test/`. Each example passed 1 test and
  `dart run bin/main.dart`. `dart pub publish --dry-run` reported 0 warnings for
  `sqlite_plus` and `sqlite_plus_orm`. The generator reported 2 warnings
  because `analyzer` 6.4.1 and `dart_style` 2.3.6 stay exact. Nothing was
  uploaded.
- `benchmark_results/scenarios_10k_linux_x64.json` is the Linux x64 AOT
  measurement for 10000 rows and three samples. 100000 and 1000000 were not
  run. The file records SDK `3.13.7 (stable) (Thu Oct 22 14:28:57 2026 -0700) on "linux_x64"`,
  hostname `cursor`, and peak RSS `220463104`. Memory SQL insert microseconds
  are `[2601012,2518356,2478439]`. Memory ORM save microseconds are
  `[2934430751,3092578591,2700874993]`. File SQL insert microseconds are
  `[1941990,1996109,2015981]`. File bytes are `[98304,98304,98304]` and
  journal bytes are `[8720,8720,8720]`. The remaining point, range, update,
  and delete arrays are in that file. Cold is the first measured SQL query
  after the fill in the same process. Warm is the next repetition.
- Generated `@DbJson` path, FTS `search`, and R-tree `bounds`. The example
  passes `--check`. The compiled consumer saves, searches, and reads through
  `sqlite_plus_orm` only.
- One Chrome page on Linux: `packages/sqlite_plus_orm/tool/chrome_orm_linux_x64.log`.
  `durabilityPromised` is false.
- macOS and Windows CI passed for commit `7afaaba` in GitHub Actions run
  40538509306. Each OS printed 10490 engine tests with 6 skipped, 169 ORM
  tests, and 53 generator tests. The six skips are the pinned SQLite CLI
  checks. The Windows stale-sidecar test passed. Those counts belong to
  `7afaaba`. Later heads do not have a macOS or Windows result yet.
- macOS CI for the earlier commit `e320528` in run 40494640309 passed 10490
  engine tests with 6 skipped, 167 ORM tests, and 53 generator tests.
- Linux CI runs `tool/generate_*.py --verify`. A checksum mismatch fails the
  job. Those steps do not execute SQLite.

### Planned

The comparisons recorded under Unreleased are in the tree. What remains:

- `EXPLAIN` bytecode for an integer-primary-key insert and a join of two subqueries, plus STAT4. This is not a VDBE.
- An official SQLite master journal for a two-database commit. The current record is the engine schema-commit file.
- A multi-frame WAL log. File `wal`, `persist`, and `truncate` already match the pinned header and journal bytes.
- ICU and locale collations, and further virtual-table modules.
- A durable browser store, Android, and iOS.
- Benchmarks at 100000 and 1000000 rows. The current AOT file measures 10000 rows.
- A fresh macOS and Windows run for each new revision. The recorded desktop pass is commit `7afaaba`.
- Publication on pub.dev when requested.
- Flutter execution of the Margin notes CSV and plot screens. The data check passed. The widgets were not run here.
