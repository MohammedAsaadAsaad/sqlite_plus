# Changelog

## 0.0.1-dev.1

This version stays `0.0.1-dev.1` in `sqlite_plus`, `sqlite_plus_orm`, and
`sqlite_plus_generator`. It is not a 1.0 release. M9 stays unchecked.

### Verified in this tree

- Pure Dart engine, ORM, and generator for the subsets named in
  `COMPATIBILITY_MATRIX.md`. Production runtime has no FFI, native SQLite, or
  WASM SQLite.
- Linux x64 on Dart 3.13.7: 10,496 engine tests, 167 ORM tests, and 53
  generator tests. The pinned SQLite CLI was present for the engine run.
- Generated `@DbJson` path, FTS `search`, and R-tree `bounds`. The example
  passes `--check`. The compiled consumer saves, searches, and reads through
  `sqlite_plus_orm` only.
- One Chrome page on Linux: `packages/sqlite_plus_orm/tool/chrome_orm_linux_x64.log`.
  `durabilityPromised` is false.
- macOS CI passed for commit `9989846` in GitHub Actions run 40487224654.
  The six tests that need the pinned SQLite CLI skip on that runner.
- Linux CI runs `tool/generate_*.py --verify`. A checksum mismatch fails the
  job. Those steps do not execute SQLite.

### Not done

- Items 91–98, the scale and platform performance matrix, are deferred.
- Item 108 and the M9 checkbox are open.
- Windows CI failed for commit `9989846`. This revision changes the locked
  temp-directory delete and the CR LF comparisons. A Windows pass is not
  recorded until the next `windows-latest` job succeeds.
- The macOS pass above is commit `9989846`, not this later revision.
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
