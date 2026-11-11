# Item 7 preliminary reverse-scan cost

Status: **correctness verified, unaccepted**. A full primary or covering-index
scan can walk from its last key when every requested direction is the opposite
of the stored key. Range seeks, mixed directions, aliases, and non-covering
order-only scans still sort. Do not delete `preliminary.json`.

## Correctness

`packages/sqlite_plus` `dart test` on this machine: 10,711 passed, 1 skipped.
Nine FTS3/FTS4 failures in that run were `no such table` from a local
`/tmp/sqlite-build/sqlite3` built without `SQLITE_ENABLE_FTS4`. Rebuilding with
`tool/build_sqlite_reference.sh` makes FTS4 available, and
`search_engine_test.dart` plus `db_browser_b3_fts34_test.dart` then passed.
`index_order_test`, `query_diagnostics_test`, and `top_k_native_test` passed
against SQLite 3.53.1 before the full run. `dart analyze --fatal-infos` was
clean for the reader, planner, and the order test.

## Measurement

10,000 rows, 8 alternating fresh-process pairs, Dart 3.13.7 AOT, Linux x64.
Baseline is `2e9ed46`. Candidate is this tree. Checksums matched inside each
mode. The probe is `tool/optimizer_benchmark/reverse_order_probe.dart`.

| mode | median ratio | baseline min–max µs | candidate min–max µs |
| --- | ---: | --- | --- |
| `SELECT id ORDER BY id DESC` | 0.911461 | 70685–75946 | 66449–72427 |
| `SELECT a ORDER BY a DESC`, covering index | 0.757401 | 94504–99053 | 71371–107905 |

Both ranges overlap. The index sample 107905 sits above the baseline maximum,
so the median is not a separated speedup. Overlap is not zero cost and is not
acceptance.
