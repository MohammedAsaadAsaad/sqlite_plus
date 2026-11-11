# Optional prepared statements: measurements and boundaries

Linux x64, Dart 3.13.7, pure Dart AOT. Five fresh processes per variant,
sequential with alternating order; no tests or compilers running during timed
samples. In-memory storage, single connection. Setup/preparation excluded from
execution timing; first execution included (no hidden warm-up). These are local
micro/workload measurements, not a universal speed guarantee.

## Reuse on the current engine

Times are median milliseconds for the entire loop. Full ranges are in
[summary.json](summary.json), all samples/counters/RSS in [runs.json](runs.json).

| Workload | Ordinary | Prepared | Effect |
| --- | ---: | ---: | --- |
| Pure expression SELECT, 10,000 calls | 347.487 | 125.393 | 2.77x faster |
| Filter/order/limit scan over 100 rows, 3,000 calls | 2524.043 | 2549.538 | 1.0% slower; overlapping ranges |
| Guarded UPDATE over 100 rows, 3,000 calls in transaction | 1702.534 | 1630.393 | 4.2% less time |
| Typed no-tracking ORM read over 100 rows, 3,000 calls | 3704.420 | 3603.698 | 2.7% less time |
| Same ORM read, automatic cache capacity 16 | 3704.420 | 3625.679 | 2.1% less time |

The pure SELECT parsed its statement **once**, expression parsing remained at
10 across 10,000 bindings. The guarded update reused expression AST nodes;
see counters in raw samples. Preparation retains syntax, not bytecode or a
physical execution plan. Scan, validation, sorting, constraints, tracking and
binding-aware planning costs remain. The scan result demonstrates that less
parsing does not necessarily improve end-to-end time.

## Existing unprepared paths, before and after

The baseline is the working source immediately before this feature, including
preceding Jobs/import optimizations. It is **not** the older Git HEAD. Recorded
hashes are in [before_manifest.json](before_manifest.json), after libraries and
binary sizes/hashes in [after_manifest.json](after_manifest.json).

| Existing workload | Before median ms | After median ms | Before range | After range |
| --- | ---: | ---: | --- | --- |
| 10,000 rowid reads, 1,000 rows | 37.863 | 36.820 | 36.103–40.861 | 36.745–45.877 |
| 1,000 inserts in transaction | 1.818 | 1.747 | 1.607–1.879 | 1.665–2.003 |
| 1,000 simple updates in transaction | 3.965 | 3.590 | 3.530–4.597 | 3.377–4.001 |
| 1,000 guarded updates in transaction | 172.832 | 171.757 | 170.644–190.921 | 165.413–188.232 |
| 3,000 normal no-tracking ORM reads, cache disabled | 2943.249 | 2998.171 | 2875.880–3119.013 | 2850.588–3131.705 |

All ranges overlap. The ORM median increased **1.9%**; this experiment does not
establish a material regression or guarantee zero overhead on every workload.
No automatic cache or persistent registry is installed by default. Existing
simple hot paths remain. Identical logical hashes and database-image hashes
were verified for all before/after ordinary engine samples. Prepared and
ordinary variants have identical result checksums, final logical hashes and
image sizes. No schema/index/persistent cache pages were added.

The ordinary AOT engine driver grew from 10,170,344 to 10,170,768 bytes (+424);
the ORM ordinary driver from 10,304,808 to 10,372,472 (+67,664). This reflects
compiled code in these drivers, not a guarantee of application bundle size or
per-handle retained memory. Handles retain bounded syntax; SQL is capped at
65,536 code units, expression memo entries at 2,048. ORM cache defaults to 0,
can be set to 0..128 entries; explicit handles must be closed. No heap-allocation
profile or browser timing benchmark was performed.

## Reproduction

From the repository root, with Dart 3.13.7, installed locked dependencies,
Python 3 and GNU patch:

```sh
python3 tool/prepared_benchmark/build.py
python3 tool/prepared_benchmark/run.py
python3 tool/prepared_benchmark/summarize.py
```

`build.py` reconstructs pre-feature libraries in a temporary directory by
reversing [baseline.patch](baseline.patch), without editing working libraries.
The patch is a benchmark fixture relative to the current feature implementation;
future source changes may require refreshing it. Ordinary drivers use identical
source and package dependencies, with only core/ORM library locations changed.
The scripts fail on differing checksums/images. Raw data will be replaced by a
new run. Keep tests/compilers stopped while running `run.py`.

## Validation and API boundaries

- Full core suite: 10,695 passed, one optional skip, before final prepared-only
  temp-routing/boolean-scope guard; final focused rerun covers those guards.
- Full ORM/Changes/Sync/Branch/Inspector/Jobs suites: 510 passed. Two additional
  ORM tests cover nullable SQL equality and adapter interception/fallback.
- Full Search suite: 86 passed; generator: 78 passed. Final prepared tests
  together with Reactive/Geo/Vec/Arabic: 82 passed. Exact suite results are
  recorded in [validation.json](validation.json).
- Pinned official SQLite differential SELECT/DML/constraint/integrity tests in
  UTF-8/UTF-16le/UTF-16be. Native SQLite is development-only.
- Every storage failure point tested for prepared autocommit in delete/persist
  journaling with immediate persistence on/off.
- ALTER/drop/rollback, temp shadow routing, fresh data/bindings, BLOB snapshots,
  functions rebound for DML, close/overlap, strict binding counts/types,
  tracking/version/trigger/Changes/Reactive/cache lifecycle.
- Assertion example runs on VM and compiled JavaScript; CI includes both.

Supported preparation is deliberately narrower than normal SQL execution.
Complex SELECTs and non-opted-in adapters retain the adapter pipeline; captured
writes remain captured. See [core API](../../packages/sqlite_plus/doc/PREPARED.md)
and [ORM API](../../packages/sqlite_plus_orm/doc/PREPARED.md).

## Exactly 1,000 distinct bindings (requested follow-up)

Driver: `tool/prepared_benchmark/thousand.dart`. Create 1,000 products with
`id=1..1000`, `name='Product <id>'`, `price=id*10`. Execute:

```sql
SELECT id,name,price FROM products WHERE id=? AND price>=0
```

Bind each id exactly once, 1..1000, for each variant. Five fresh AOT processes
per variant in alternating order, no warm-up; database setup and one-time
preparation excluded from query timing. Each query is individually timed;
results are checked after stopping its timer. Both variants use the same
in-memory/materialized database. No schema/index changes between variants.

| Metric | Ordinary | Prepared |
| --- | ---: | ---: |
| Median sum of 1,000 query times | 106.886 ms | 102.902 ms |
| Average query time in median sum | 106.886 us | 102.902 us |
| Sum range across five processes | 102.078–113.644 ms | 99.646–105.582 ms |
| Median one-time preparation | 0 | 0.191 ms |
| Median loop including checks/bookkeeping | 107.579 ms | 103.592 ms |

Prepared query sum is 3.7% lower in these samples; ranges overlap. Preparation
parsed the SELECT once. All 10,000 returned rows across the ten processes were
validated against the distinct binding, name and price. Per-call microsecond
measurements include stopwatch overhead and rounding, equally for both variants.
Every call's timing is in [thousand_runs.json](thousand_runs.json); summary in
[thousand_summary.json](thousand_summary.json). This is an indexed table lookup,
not the earlier pure-expression benchmark, so the benefit differs.

```sh
dart compile exe tool/prepared_benchmark/thousand.dart -o /tmp/prepared-thousand
/tmp/prepared-thousand ordinary
/tmp/prepared-thousand prepared
```
