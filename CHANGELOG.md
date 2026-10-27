# Changelog

## 0.0.1-dev.1

This version stays `0.0.1-dev.1` in `sqlite_plus`, `sqlite_plus_orm`, and
`sqlite_plus_generator`. It is not a 1.0 release. M9 stays unchecked. The
three packages are prepared for pub.dev and are not published.

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

### Not done

- Item 108 and the M9 checkbox are open. The 10000-row AOT file does not close
  them. 100000 and 1000000 rows were not run.
- Windows CI for the earlier commit `e320528` passed 167 ORM tests and 53
  generator tests. The engine job passed 10489, failed 1, and skipped 6. The
  failure was `database_owner` tearDown `PathAccessException` errno 32. Commit
  `7afaaba` is the Windows pass recorded above. Heads after that commit wait
  for their own jobs.
- The macOS and Windows passes above are commit `7afaaba`, not every later
  revision.
- Android was not run. iOS was not run. A macOS Dart VM job is not iOS.
- Power loss is not claimed. Browser storage does not promise durability.
- DQS stays off.
- `json_pretty` is not implemented. Correlated `json_each(other.column)` is
  rejected. JSON text is capped at 1 MiB, depth at 1000, and function output
  at 16 MiB.
- EXPLAIN bytecode throws. STAT4 fails at open. `auto_vacuum` writes are
  rejected. A non-zero largest root page fails at open.
- A statement cannot mutate two schemas. A durable commit of two databases is
  not implemented.
- Journal modes other than reading rollback/wal and rewriting the current mode
  are rejected.
- FTS5 multi-page leaves, porter, trigram, detail, tokendata, and locale are
  not implemented. FTS3 and FTS4 writes are rejected.
- ICU and locale collations are absent.
- General virtual-table modules beyond the verified subset are not claimed.
- The macOS and Windows CI jobs do not run the Python checksum verifiers.
