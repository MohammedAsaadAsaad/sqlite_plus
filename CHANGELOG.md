# Changelog

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

- `json_pretty`, correlated `json_each`, EXPLAIN bytecode, STAT4, and
  `auto_vacuum`.
- A durable commit across two databases, and more journal modes.
- FTS5 multi-page leaves, porter, trigram, detail, tokendata, locale, and
  FTS3/FTS4 writes.
- ICU and locale collations, and further virtual-table modules.
- A durable browser store, Android, and iOS.
- Benchmarks at 100000 and 1000000 rows. The current AOT file measures 10000
  rows.
- A fresh macOS and Windows run for each new revision. The recorded desktop
  pass is commit `7afaaba`.
- Publication on pub.dev when requested.
