# Reactive ORM AOT measurements

Linux x64, Dart 3.13.7, 2026-11-07. Experimental workspace implementation.
Five fresh-process alternating before/after pairs at each row count; three
watch-enabled samples. Medians below are milliseconds. Each process creates
a database, batch-inserts mapped rows, performs 100 no-tracking reads (20 rows),
updates every tracked row in one save, then performs 100 counts. Final sum is
asserted, and the database image hash/size is recorded. The enabled variant has
one list watch capped at 20 rows, without Changes capture; it flushes explicitly
after setup and after the workload. Timing columns exclude those explicit flushes.
Scheduled watch work can interleave with operations. Notifications were three
in each enabled run (initial, insert, update). These samples do not measure
Changes/Sync capture overhead, file I/O, device rendering or large subscriptions.

| Rows | Variant | Insert | 100 reads | Batch update | 100 counts |
|---:|---|---:|---:|---:|---:|
| 100 | before | 3.418 | 39.870 | 164.928 | 95.058 |
| 100 | after | 3.399 | 40.696 | 167.049 | 97.504 |
| 100 | enabled | 3.561 | 42.180 | 170.542 | 94.619 |
| 1000 | before | 33.876 | 327.143 | 14133.720 | 875.103 |
| 1000 | after | 34.876 | 330.767 | 15033.058 | 926.204 |
| 1000 | enabled | 35.085 | 345.269 | 14921.979 | 913.217 |

`before`: original ORM, captured before changes. `after`: feature code linked,
watch runtime branch disabled. `enabled`: same after binary with `--watch`.
At 100 rows the disabled medians differ from baseline by about −0.6% to +2.6%.
At 1000 rows they are +1.1% reads, +3.0% insert, +6.4% update and +5.8% counts.
This does **not** establish a zero-regression performance gate. The host is shared;
example compilation overlapped two later pairs and the raw samples show outliers.
Repeat on controlled target hardware before adopting a strict latency budget.
We retain all samples and do not attribute the entire timing difference to
notification logic. The existing 1000-row tracked-update workload itself takes
about 14–15 seconds and remains a separate ORM optimization opportunity.

All variants produced byte-identical final images: 12288 bytes at 100 rows and
24576 at 1000 rows, with the same checksum at each scale. Ordinary ORM watches
add no persistent tables/indexes. Changes mode intentionally has its existing
capture metadata/log overhead; see the Changes/Sync benchmark directories.

Median RSS at 1000 rows: before 76894208 bytes, disabled 76795904, enabled
78184448. RSS fluctuates with allocator/GC; it is not a bound. The retained-row
cap does not limit SQL temporary memory or BLOB bytes. AOT binaries were
10393328 bytes before and 10479216 after (+85888); the after binary deliberately
keeps a runtime-reachable watch branch. This is not an APK or an import-only size
guarantee. No baseline/feature engine or Sync runtime source changed (hash checked).

## Evidence and reproduction

- [isolated_runs.json](isolated_runs.json): follow-up data used above; the name
  denotes separation from the main regression run, not a dedicated physical host.
- [runs.json](runs.json): original overlapping-test run, retained to show variance;
  do not use it as an isolated performance comparison.
- [runtime_before.json](runtime_before.json): pre-feature runtime hashes.
- [manifest.json](manifest.json): final source/binary hashes and environment.

Baseline ORM matches Git revision `b918a160249069d8b5fc206a3ee609826562a2d3`.
The core is the matching current workspace engine, including previously accepted
Changes optimizations. Reproduction copies only workspace source/configuration
into a temporary directory, checks old ORM hashes, and restores old ORM there:

```sh
python3 tool/reactive_benchmark/reproduce.py --runs
```

Configure Dart and PUB_CACHE first; dependencies must already be cached for
`dart pub get --offline`. Builds and raw results are written to the printed temp
directory. The working checkout is never rewritten. Before and after drivers
are in `tool/reactive_benchmark`; the pre-feature driver cannot reference watch APIs.
AOT executables remain local and are fingerprinted rather than committed.
