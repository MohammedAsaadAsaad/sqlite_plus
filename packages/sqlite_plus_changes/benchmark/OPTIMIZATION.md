# Trigger snapshot optimization — 2026-11-07

These are the current workspace measurements. [Initial results](RESULTS.md) are
retained separately. This change needs the unreleased workspace engine revision;
it is not a performance claim for published sqlite_plus 0.1.9.

## What changed

Before each small trigger read, the engine rebuilt a temporary image containing
all application tables and indexes. A tracked row could repeat this for the guard,
changed-column condition and batch-id subquery. Simple trigger reads now copy only
the ordinary unindexed rowid tables they depend on; source-free conditions need
no table rows. The same reader, SQL binding, functions and trigger contexts run.
Views, indexes, WITHOUT ROWID, virtual/schema tables, CTEs, joins and compounds
conservatively retain the full snapshot path. No persistent index/table, log
format, trigger definition, transaction boundary or public API changed.

## Enabled capture

Linux x64, Dart 3.13.7 AOT, in-memory. Five fresh-process old/new pairs at each
size, alternating revision order. Each process runs one untracked control and one
tracked case. Both explicitly enable recursive triggers. Each workload uses
individual UPDATE statements inside one transaction, then reads and checks all
event keys/columns, acknowledges and prunes. Timings below include the write
transaction only. All values are medians in milliseconds.

**The 10k-row case uses 10 updates; the 1k-row case uses 100.** Do not compare
those raw totals as equal workloads. No tests/builds ran concurrently with these
samples; host load and GC remain uncontrolled.

| Source rows | Updates | Old untracked ms | Old tracked ms | New untracked ms | New tracked ms | Tracked speedup |
|---:|---:|---:|---:|---:|---:|---:|
| 1000 | 100 | 464.296 | 8,989.797 | 466.953 | 444.681 | 20.2x |
| 10000 | 10 | 456.201 | 6,849.543 | 448.560 | 554.848 | 12.3x |

The control measures general write cost in the same build; the old/new tracked
comparison measures this optimization. Ratios here are workload-specific, not a
phone or sustained-throughput guarantee. Min/max samples are preserved in the
raw summary. High-write-volume adoption still needs persisted/device and larger
retained-log measurements. Single-row transactions and multiple tracked tables
are not benchmarked here.

## Disabled gate

The same existing mixed workload runs with Changes linked and never activated:
inserts, 500 point reads, 50 range reads, 200 updates in one transaction, 20
autocommit updates, search-index creation, 20 warmed searches and export. Five
fresh-process pairs per size. Search uses its own existing log.

| Rows | Workload | Before ms | After ms | Delta |
|---:|---|---:|---:|---:|
| 1000 | insert | 27.531 | 29.847 | +8.41% |
| 1000 | point_500 | 2.290 | 2.455 | +7.21% |
| 1000 | range_50 | 20.302 | 22.120 | +8.95% |
| 1000 | update_batch_200 | 798.624 | 859.470 | +7.62% |
| 1000 | update_auto_20 | 80.637 | 88.067 | +9.21% |
| 1000 | search_index | 141.738 | 153.033 | +7.97% |
| 1000 | search_20 | 41.256 | 42.687 | +3.47% |
| 1000 | export | 0.010 | 0.009 | -10.00% |
| 10000 | insert | 584.113 | 624.782 | +6.96% |
| 10000 | point_500 | 3.198 | 3.291 | +2.91% |
| 10000 | range_50 | 22.380 | 23.325 | +4.22% |
| 10000 | update_batch_200 | 7,864.007 | 8,170.971 | +3.90% |
| 10000 | update_auto_20 | 788.177 | 802.091 | +1.77% |
| 10000 | search_index | 3,345.854 | 3,438.864 | +2.78% |
| 10000 | search_20 | 208.073 | 190.683 | -8.36% |
| 10000 | export | 0.244 | 0.274 | +12.30% |

No timing increase outside min/max sample overlap was observed. Faster results
are not attributed to the package; AOT layout and host variation affect timings.
Microsecond export totals are below useful comparative precision.

Every disabled image SHA-256 matches across all ten processes at each size:

- 1000 rows: 172,032 bytes, identical before/after.
- 10000 rows: 1,155,072 bytes, identical before/after.

### Additional disabled confirmation

Positive 1k medians in the first five pairs prompted ten additional alternating
fresh-process pairs with identical binaries/workload and no concurrent tests.
Both data sets are retained; this is not a replacement for inconvenient samples.
Every repeated image hash also agrees. The repeat medians are:

| Workload (1k rows) | Before ms | After ms | Delta |
|---|---:|---:|---:|
| insert | 28.588 | 29.495 | +3.17% |
| point_500 | 2.345 | 2.436 | +3.88% |
| range_50 | 20.792 | 21.448 | +3.16% |
| update_batch_200 | 828.639 | 840.863 | +1.48% |
| update_auto_20 | 82.903 | 83.138 | +0.28% |
| search_index | 146.404 | 150.867 | +3.05% |
| search_20 | 42.142 | 43.175 | +2.45% |
| export | 0.010 | 0.010 | +0.00% |

Whole-process CPU seconds (median before/after): 1.321 / 1.325; wall seconds: 1.204 / 1.217. These include setup and all phases, unlike the per-phase wall timings. A strict zero-cost claim is not established by these host-dependent measurements.

## Size and memory

The enabled before/after image sizes agree for every corresponding sample.
No additional persistent structure was introduced by this optimization.

| Rows | Source bytes | Ready bytes | After writes bytes | After prune bytes |
|---:|---:|---:|---:|---:|
| 1000 | 61,440 | 90,112 | 98,304 | 90,112 |
| 10000 | 520,192 | 548,864 | 548,864 | 548,864 |

These are in-memory image sizes. Physical file shrinking and APK size are not
measured. RSS below is from disabled mixed-workload processes; GC is not forced.
Peak RSS includes all phases. Neither equal nor lower heap use is established.

| Rows | End RSS median before/after bytes | Peak RSS median before/after bytes |
|---:|---:|---:|
| 1000 | 49,737,728 / 49,594,368 | 54,349,824 / 54,337,536 |
| 10000 | 65,748,992 / 62,115,840 | 218,058,752 / 216,739,840 |

The linked Linux disabled executable changes by +18,608 bytes. This is
compiled code size, separate from database size.

## Verification and limits

- Engine: 10,630 tests pass; one SQLCipher CLI test skipped because that tool is
  absent. Twelve trigger snapshot tests compare with pinned official SQLite
  3.53.1 and check exported image integrity/reopen, including nested writes,
  generated/Unicode values, 512-byte UTF-8/UTF-16 pages and conservative fallbacks.
- Changes: 35 tests pass, including 80 injected storage-operation fault points
  across capture/ack/prune/track. Existing search: 86 pass; Flutter catalog: 17.
- VM and compiled JavaScript/Node shared assertions pass. Analysis is clean.
- The initial sandboxed engine/app runs could not bind local sockets; complete
  engine and app reruns with local networking pass. Remote CI was not run.
- No app activation, file migration, new package release, physical-device timing,
  real browser persistence or new WAL-specific Changes recovery claim.

Only image_mutations.dart changed among the 97 previously recorded engine/search
runtime files. The existing search edits and metadata workarounds are preserved.
This optimizes a general trigger read path; it does not install Changes hooks in
ordinary writes. The scoped producer API and all existing limitations remain.

## Reproduce

Use Dart 3.13.7 from repository root at this workspace revision. Reconstruct the
old engine file into a separate output (without changing the working source):

```sh
patch --reverse --output=/tmp/changes-baseline.dart \
  packages/sqlite_plus/lib/src/sql/image_mutations.dart \
  < benchmark_results/changes_optimization/engine_optimization.patch
python3 tool/changes_benchmark/build_optimization.py /tmp/changes-baseline.dart
python3 tool/changes_benchmark/optimize.py \
  /tmp/changes-opt-old-enabled /tmp/changes-opt-new-enabled \
  /tmp/changes-opt-old-disabled /tmp/changes-opt-new-disabled
python3 tool/changes_benchmark/report_optimization.py
```

The build helper temporarily substitutes the baseline source and restores the
current file in finally. Do not run other builds/tests during that step or during
measurement. Source hashes are checked before compiling and before/after runs.
All process results, ranges, hashes, sizes and the isolated source patch are in
[benchmark_results/changes_optimization](../../../benchmark_results/changes_optimization).
