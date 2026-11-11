# Item 6 preliminary index-order cost

Status: **implemented and unaccepted**. These rows are the first measurement of
the direct-path change. They are not an acceptance record. Do not delete or
overwrite `preliminary.json`; copy it aside before a later run replaces it.

## What the candidate changes

A direct single-table reader skips the later sort when a forward primary or
index scan already yields `ORDER BY`. It may also scan a covering secondary
index when the primary tree does not already provide that order. Descending
reversal, aliases, qualified names, non-covering order-only scans, expression
indexes, and partial indexes whose predicate is not proved stay on the existing
sort.

## Correctness recorded with this checkpoint

- `packages/sqlite_plus` `dart test`: 10,629 passed, 30 skipped. The 21 failures
  in that run were `ProcessException` for a missing `/tmp/sqlite-build/sqlite3`.
- After compiling SQLite 3.53.1, source id
  `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`,
  `index_order_test` and these native suites passed: query diagnostics, top-k,
  utf collation, pagination, prepared, upsert resident, rowid conjunct, schema
  roots, trigger snapshot.
- `dart analyze --fatal-infos` was clean for `packages/sqlite_plus` and
  `packages/sqlite_plus_orm/example`.
- `python3 tool/verify_optimizer_handoff.py` fails on
  `packages/sqlite_plus/lib/src/sql/database.dart` because this item edits it.
  The item 3 manifest is unchanged. Re-run the verifier at `8ae5144`.

## Measurement

Command:

```sh
python3 tool/optimizer_benchmark/index_order_cost.py \
  /tmp/index-order-baseline.exe /tmp/index-order-candidate.exe \
  20000 8 benchmark_results/optimizer_index_order/preliminary.json
```

The baseline binary was compiled from a detached worktree at `a4fc3a9`. The
candidate binary was compiled from the dirty tree that produced this checkpoint.
Both are Dart 3.13.7 AOT, Linux x64. Each pair alternates which binary starts
first. Each process inserts 20,000 rows, then times one workload. The stopwatch
starts after the insert. Checksums matched inside every mode.

Median candidate/baseline ratios and sample ranges in microseconds:

| mode | ratio | baseline min–max | candidate min–max |
| --- | ---: | --- | --- |
| index, `SELECT a ORDER BY a`, covering | 0.751990 | 193103–233539 | 145855–187808 |
| rowid, `SELECT id ORDER BY id` | 0.961977 | 143520–185938 | 140811–153901 |
| sort, `SELECT b ORDER BY b` | 0.988371 | 273962–355728 | 280830–342551 |
| update, 200 single-row updates | 1.040938 | 16093924–17558517 | 16709028–17723173 |
| wide, `SELECT a, b ORDER BY a, b`, not covering | 1.034583 | 213494–220992 | 218746–249066 |

The covering-index ranges do not overlap. The other four ranges do. Overlap is
not evidence of zero cost. The update and wide medians are slower, so this item
stays open. The full optimizer harness was not run, and only one row count was
measured.
