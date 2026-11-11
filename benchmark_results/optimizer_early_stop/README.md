# Item 8 ordered-prefix early stop

Status: **accepted for one documented shape**, with the filtered control left
visible. A direct scan that already yields `ORDER BY` stops after `OFFSET +
LIMIT` rows when the statement has no `WHERE`, aggregate, window, `DISTINCT`,
`GROUP BY`, compound, or CTE. Every other shape still reads its input.

## Correctness

`index_order_test` matches pinned SQLite 3.53.1 for `ORDER BY id DESC LIMIT 1
OFFSET 1` and for `WHERE b = 'a' ORDER BY id LIMIT 1`. The DESC limit loads 1
row. The filtered limit loads more than one row and returns id 3.
`query_diagnostics_test` and `pagination_test` passed.
`dart analyze --fatal-infos` was clean for the planner and the order test.

## Measurement

10,000 rows, 6 alternating fresh-process pairs, Dart 3.13.7 AOT, Linux x64.
Baseline is `3b16f19` (reverse scans, no early stop). Checksums matched.

| mode | median ratio | baseline min–max µs | candidate min–max µs |
| --- | ---: | --- | --- |
| `SELECT id ORDER BY id DESC LIMIT 1` | 0.011224 | 47905–52367 | 525–709 |
| `WHERE b = 'v0' ORDER BY id LIMIT 1` | 1.014597 | 48519–53586 | 49156–51636 |

The ordered ranges do not overlap. The filtered ranges do. The filtered median
is 1.46% slower, which is not a zero-cost result and is not a claimed speedup.
Raw rows: `preliminary.json`.
