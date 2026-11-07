# Built-in pagination AOT evidence

Linux x64, Dart 3.13.7, 2026-11-07. The benchmark runs the integrated engine
API; no native database executes production queries. The raw results and source/
binary fingerprints are stored alongside this report.

## Workload

Each fresh AOT process creates 1000 or 10000 in-memory rows in
`items(id INTEGER PRIMARY KEY,n INTEGER)`. It obtains a continuation boundary
at 90% of the table, then alternates OFFSET and cursor reads of 30 rows seven
times (order reversed on alternate repetitions). Checks assert the first/last
IDs and length for every result. Both variants project the same columns; the
cursor variant includes API validation/hash/row maps and reads one extra row.
The table has only its normal rowid primary key; no added pagination index.
Three fresh processes per size. The table is warmed by population/anchor setup;
iteration zero is the first measured statement shape, not a cold database.
All raw samples are retained. Each process median below excludes iteration zero,
and the summary takes the median of the three process medians.

| Rows | OFFSET | Cursor API | OFFSET / cursor | Image bytes |
|---:|---:|---:|---:|---:|
| 1000 | 3.6155 ms | 0.7955 ms | 4.54× | 20480 |
| 10000 | 43.294 ms | 3.578 ms | 12.10× | 98304 |

At 1000 rows, per-process warm medians (microseconds) were OFFSET
`[3565,3615.5,3938]`, cursor `[791.5,795.5,925]`. At 10000 they were OFFSET
`[41345.5,43294,44209.5]`, cursor `[3577.5,3451.5,3794]`.
The captured plan was `SEARCH items USING INTEGER PRIMARY KEY (rowid>?)`.
The driver literalizes its integer-only parameters solely for diagnostic
EXPLAIN because the current mutable EXPLAIN API rejects binds; timed reads
always use bound parameters.

The database image is hashed before and after all reads and must match exactly.
No rows, tables, triggers or indexes are added by paging. Image sizes above are
whole database sizes, not incremental cursor overhead. Tokens live in application
memory or wherever the caller chooses to persist them.

## Limits

This demonstrates one indexed integer-key late-page workload. It does not prove
constant-time execution, general multi-column/index/collation performance,
100k/1m scalability, file I/O or real device/browser latency. OR predicates,
explicit NULL placement and mixed ordering may require sorting/scanning in the
current engine. Review the actual plan for your query. Plain SQL may be cheaper
than the helper on small/first pages because the helper validates, fingerprints
and constructs row maps. No disabled-path timing comparison was run in this
milestone; existing engine execution files are unchanged (only public exports
and new helpers), and normal ORM queries never call the page method. This is a
structural statement, not a universal zero-overhead measurement.

RSS/peak RSS in raw results include population, anchor setup, engine caches and
both variants. They do not isolate per-page allocations; row limits do not bound
BLOB bytes or the engine's sort/materialization memory.

## Reproduction

From the workspace root with Dart dependencies resolved:

```sh
dart compile exe tool/pagination_benchmark/main.dart -o /tmp/pagination-benchmark
/tmp/pagination-benchmark 1000
/tmp/pagination-benchmark 10000
```

Repeat each command in three fresh processes. The JSON contains all timing
samples, query plan, image size/hash and memory observations. Run without other
CPU-heavy work; recorded samples were collected after regression tests finished.
Binary is local (fingerprinted, not committed). No physical power-loss test,
production publishing or remote CI run was performed.
