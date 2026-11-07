# Initial Changes AOT comparison — 2026-11-07

Historical pre-optimization results, retained unchanged. For current workspace
measurements see [trigger snapshot optimization](OPTIMIZATION.md). The 18.6x
enabled-write ratio below describes the earlier engine path.

Linux x64, Dart 3.13.7 AOT, in-memory database; five fresh-process pairs per size,
alternating before/disabled order. No concurrent agent tests/builds during samples;
host load and GC remain uncontrolled. This is the working-tree baseline captured
before this package was added, including the existing search/fuzzy/precision work.

`before` does not import Changes. `disabled` links a runtime-reachable activation
demo but does not execute it. Both call the same workload source. No existing
engine/search runtime file changed: all 97 SHA-256 values match the captured
baseline. This comparison does not prove every platform/workload has zero cost.

## Disabled timings

All times are totals per named workload, not per operation. Values are medians
in milliseconds. Export timings near a few microseconds are below useful
comparative precision. Inserts and search indexing include setup for that phase.

| Rows | Workload | Before ms | Disabled ms | Delta |
|---:|---|---:|---:|---:|
| 1000 | insert | 32.418 | 27.292 | -15.81% |
| 1000 | point_500 | 2.407 | 2.398 | -0.37% |
| 1000 | range_50 | 21.120 | 21.011 | -0.52% |
| 1000 | update_batch_200 | 840.005 | 830.014 | -1.19% |
| 1000 | update_auto_20 | 86.926 | 82.196 | -5.44% |
| 1000 | search_index | 154.713 | 148.245 | -4.18% |
| 1000 | search_20 | 43.413 | 42.881 | -1.23% |
| 1000 | export | 0.009 | 0.010 | +11.11% |
| 10000 | insert | 626.285 | 593.187 | -5.28% |
| 10000 | point_500 | 2.993 | 3.089 | +3.21% |
| 10000 | range_50 | 22.457 | 22.682 | +1.00% |
| 10000 | update_batch_200 | 7994.609 | 7900.916 | -1.17% |
| 10000 | update_auto_20 | 797.233 | 811.784 | +1.83% |
| 10000 | search_index | 3433.981 | 3300.206 | -3.90% |
| 10000 | search_20 | 191.990 | 181.991 | -5.21% |
| 10000 | export | 0.815 | 0.322 | -60.49% |

No timing slowdown falls outside the min/max sample overlap. Faster samples
are not attributed to the package: linking changes AOT layout, and the host is
uncontrolled. Full ranges and every process result are retained in the raw files.

## Disabled data and memory

For each size, every image hash matches across all ten processes:

- 1000 rows: 172,032 bytes; SHA-256 identical before/disabled.
- 10000 rows: 1,155,072 bytes; SHA-256 identical before/disabled.

No Changes tables/triggers/settings are created in disabled mode. RSS is sampled
at process end without forcing GC; peak RSS includes all earlier phases.

| Rows | RSS median before/disabled bytes | Peak RSS median before/disabled bytes |
|---:|---:|---:|
| 1000 | 47,906,816 / 49,537,024 | 54,353,920 / 54,566,912 |
| 10000 | 63,111,168 / 62,578,688 | 214,786,048 / 215,560,192 |

Memory is not claimed identical. At 10k rows peak ranges overlap (about
207–231 MB); end-RSS has GC-sensitive outliers. The higher disabled peak median
is preserved above rather than hidden; a controlled heap study would be needed
for a strict memory-equivalence claim. No new per-write engine path was added.

The linked disabled binary is 88,728 bytes larger on this Linux build
(reachable optional code retained deliberately). This is executable size, not
a change in database size and not an Android APK measurement.

## Enabled capture: important limitation

Five alternating samples per mode in one AOT process, 1,000 source rows, 100
individual UPDATE statements in one transaction. Both modes enable recursive
triggers explicitly. Tracked mode monitors the primary key and `n`, stores keys
only, reads/acks one consumer batch and prunes it. Not a file-I/O/device sample.

| Metric | No tracking | Tracking enabled |
|---|---:|---:|
| Open + track + consumer | 0.000 ms | 44.745 ms |
| 100 UPDATE statements | 465.668 ms | 8,676.980 ms |
| Read 100 events | 0.000 ms | 7.844 ms |
| Source image | 61,440 bytes | 61,440 bytes |
| Ready image | 61,440 bytes | 90,112 bytes |
| Image after writes | 61,440 bytes | 98,304 bytes |
| Image after prune | 61,440 bytes | 90,112 bytes |

**Enabled capture is not ready for high write throughput.** On this sample it
is about 18.6x slower for those 100 separate statements. The development milestone
establishes semantics, fault recovery and the disabled gate; it does not pass an
enabled-performance release gate. Existing apps/search logs have not migrated.
Trigger dispatch and metadata writes need profiling/optimization before adoption.

The sample adds 28 KiB for activation and 8 KiB for 100 events. The in-memory
image returns to the ready size after prune here; physical-file shrinking is not
promised. Size depends on keys, columns, source schemas and retained event counts.

## Reproduce

From repository root, use the same SDK for both binaries:

```sh
dart compile exe tool/changes_benchmark/before.dart -o /tmp/changes-before
dart compile exe tool/changes_benchmark/after.dart -o /tmp/changes-after
dart compile exe packages/sqlite_plus_changes/benchmark/enabled.dart -o /tmp/changes-enabled
python3 tool/changes_benchmark/compare.py
```

Runtime hashes guard against silently reusing the baseline after engine/search
code changes. Initial baseline evidence, paired results, summaries, binary
hashes and enabled raw data are in [benchmark_results/changes](../../../benchmark_results/changes).
Initial baseline executable was compiled before package implementation.
