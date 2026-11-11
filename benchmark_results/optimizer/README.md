# Optimizer: initial measured milestone

Scope: audit/baseline tools and replacing repeated linear worst-row selection
with an in-place max-heap in eligible ORDER BY/LIMIT execution. This is one
milestone, not completion of the 42-item optimizer roadmap. See
[the live ledger](../../docs/plans/OPTIMIZER.md) and [audit](AUDIT.md).

## What the baseline actually did

Non-DISTINCT explicit-LIMIT ordering already retained at most
`K = LIMIT + max(OFFSET, 0)` result candidates, but scanned those K keys to find
the last worst entry for every later input row. The initial audit corrected the
earlier assumption that every such query sorted all results. The new candidate
uses a max-heap for K>=32, constructed lazily only when the retained set fills.
Small K and unsupported shapes retain the existing linear/full-sort behavior.

The heap shares the existing retained-entry list. It retains sequence tie
ordering and evaluates/skips SQL projections at the same candidate decisions.
It reduces worst-case selection work from O(N*K) to O(N log K), followed by the
same final ordering of retained entries. It does NOT skip table pages, improve
index access, change schema/files, or remove upstream row materialization.
The baseline already bounded retained result count: no new general O(N)-to-O(K)
memory benefit is claimed. The conservative threshold 32 is tested, not claimed
to be a globally optimal threshold for every device or query.

## Measurement method

Pure Dart AOT, Dart 3.13.7, Linux x64. Five fresh processes per before/after
variant, alternating order, sequential after tests and compilers stopped. No
hidden warm-up. Each case reports an entire loop (repeat counts in raw data).
Setup, opening the image, explain probe and result hashing are outside query
timing. Queries still include parsing, planning, data reading and execution.
Stable database images are shared across variants; seeded data/hash/size are
recorded in [after_manifest.json](after_manifest.json).

Data: 1k/10k/100k rows; random, ascending, descending and duplicate-heavy sort
keys; tiny/threshold/large/unlimited K, offsets, DISTINCT/unsorted/point reads,
memory/stable file adapters. File results are not guaranteed cold OS-cache
measurements. Supplementary cases exercise tiny inputs and nearly-full limits.

The main query is:

```sql
SELECT id,payload FROM items
WHERE flag>=?
ORDER BY score,id
LIMIT ? OFFSET ?;
```

All rows satisfy the bound flag condition. Comparison counters use a separate
instrumented collation case; visit/projection counters and callback traces use
separate diagnostic queries, not default production hooks. `explain_us` is
only that API's elapsed time, NOT isolated full planning time. This milestone
changes execution selection only; end-to-end timings include normal planning.

[Raw samples](runs.json) and [summary](summary.json) include times, ranges,
result hashes/counts, storage read calls/bytes, RSS/peak RSS and diagnostic
counts. Summary verification requires identical results/IO/visits/projection
traces across variants. Comparison counts may change by design. RSS is whole
process measurement, not an allocation/retained-heap profile.

Existing unprepared read/write/default-ORM workloads are measured separately in
[regression samples](regression_runs.json) and
[regression summary](regression_summary.json).

## Reproduction

From the repository root with installed locked dependencies, Dart 3.13.7,
Python 3 and GNU patch:

```sh
python3 tool/optimizer_benchmark/build.py
# Stop tests and compilers before timing.
python3 tool/optimizer_benchmark/run.py
python3 tool/optimizer_benchmark/regression.py
python3 tool/optimizer_benchmark/edges.py
python3 tool/optimizer_benchmark/summarize.py
```

The baseline is the working source immediately before this optimizer change,
including preceding prepared/Jobs/import work, not older Git HEAD. `build.py`
reverses [baseline.patch](baseline.patch) in temporary copied libraries and
never edits working source. Reconstruction was byte-compared with the saved
baseline. [Before](before_manifest.json) and [after](after_manifest.json)
source/binary hashes make the measured implementation identifiable. The reverse
fixture is relative to this milestone; future source changes may require
refreshing it. Reproduction overwrites raw outputs. The regression driver
sources live under `tool/prepared_benchmark`, reused identically for both builds.

## Correctness gates

- Full engine: 10,705 passed, one optional skip.
- Full ORM/Changes/Sync/Branch/Inspector/Jobs/Reactive/Geo/Vec/Arabic: 572 passed;
  two new ordered ORM/cache/prepared tests passed separately.
- Full Search: 86 passed.
- Pinned official SQLite: 300 sort/result comparisons across three encodings.
- Boundary/full-order reference tests: K=0/1/31/32/33/64/oversized/negative,
  offsets, NULL/mixed values/blob sort keys, collations, ties, alias/ordinal
  ordering, GROUP BY, DISTINCT, windows, CTEs and joins.
- Heap randomized/reference and deterministic comparison-work tests.
- VM and compiled JavaScript assertion consumer passes for raw/prepared/ORM/
  cache queries. CI includes it; format/fatal-info analysis pass.

Storage layout, constraints and public APIs are unchanged. No new storage
fault protocol was added, so no additional storage-fault model was introduced;
existing full regression suites include their recovery tests. Generator code
and ORM production code were not changed by this milestone.

## Results and acceptance decision

**Accepted for the tested bounded-selection scope**, with the measured control
costs below explicitly retained. This is a benefit/cost decision, not a claim of
zero overhead or universal optimizer completion. Items 3 and 6–42 remain open;
the initial regression matrix must grow with each future item.

Times below are median milliseconds for the stated entire loop, five processes
per variant. Full ranges and remaining cases are in summary.json.

| Workload | Before ms | After ms | Before/after |
| --- | ---: | ---: | ---: |
| 10k rows, K=1; 3 calls | 364.366 | 365.605 | 1.00x |
| 10k rows, K=20; 3 calls | 468.242 | 467.793 | 1.00x |
| 10k rows, K=32; 3 calls | 540.678 | 355.413 | 1.52x |
| 10k rows, K=1000; 3 calls | 5812.859 | 425.866 | 13.65x |
| 10k rows, K=10010; 3 calls | 540.899 | 547.130 | 0.99x |
| 10k rows, unlimited; 3 calls | 541.133 | 528.415 | 1.02x |
| 10k rows, LIMIT 32 OFFSET 1000; 3 calls | 5882.447 | 420.607 | 13.99x |
| 100k rows, K=32; 1 call | 1748.974 | 1185.258 | 1.48x |
| 100k rows, K=1000; 1 call | 20976.341 | 1210.557 | 17.33x |
| 10k ascending, K=1000; 3 calls | 5572.002 | 365.663 | 15.24x |
| 10k descending, K=1000; 3 calls | 5743.871 | 545.899 | 10.52x |
| 10k duplicate keys, K=1000; 3 calls | 6903.898 | 428.313 | 16.12x |
| 10k stable file, K=1000; 3 calls | 5684.654 | 438.670 | 12.96x |
| 1k DISTINCT negative control; 1 call | 793.120 | 802.124 | 0.99x |
| 33 rows, K=32; 100 calls | 62.759 | 61.443 | 1.02x |
| 64 rows, K=32; 50 calls | 58.899 | 52.918 | 1.11x |
| 64 rows, K=63; 50 calls | 51.876 | 54.166 | 0.96x |
| 1k rows, K=999; 5 calls | 83.519 | 84.635 | 0.99x |

The instrumented 1k-row/K=100 case made **90,869 comparisons before vs 4,853
after**. Results, scalar visit counts, projection trace hashes and storage
read calls/bytes match across all 27 cases / 270 processes. For 100k rows/K=1000,
median peak RSS was approximately **121.32 MB before / 120.89 MB after**;
this shows no growing extra retained-result structure in the tested case, not
an exact allocation guarantee. The ordinary AOT engine driver increased by
**912 bytes**, and the ordinary ORM driver by **1,048 bytes** in these builds.

### Controls, follow-up and costs

Initial ordinary-update samples were slower, so they were investigated rather
than omitted. All original data remains linked above. Fifteen extra paired
processes were added for ordinary read/update and tiny almost-full sorting,
with [follow-up samples](followup_runs.json) and
[combined summary](followup_summary.json):

| Control | Before median ms | After median ms | Change |
| --- | ---: | ---: | ---: |
| 10k ordinary reads, 20 samples each | 36.298 | 36.343 | +0.1% |
| 1k ordinary updates, 20 samples each | 3.443 | 3.639 | +5.7% |
| 64 rows/K=63, 50 calls, 20 samples each | 51.941 | 52.489 | +1.1% |

A separate amplified **100,000 ordinary UPDATE** workload was run in two batches
(20 samples per main variant total): **312.677 -> 318.588 ms**, +**1.9%** median.
Ranges: 298.444–344.042 ms before and 307.855–374.613 ms after. See
[initial long probe](update_probe_runs.json), [three-way experiment](classless_probe_runs.json)
and [combined long-probe summary](update_probe_combined_summary.json).
Ranges overlap, which does NOT prove equivalence or zero overhead. Ordinary
write source was unchanged; no cause is asserted solely from timing. The small
control cost is part of this milestone's documented tradeoff. Default ORM read
median was 3044.125 -> 3007.000 ms in the original five-process comparison.
No publication/release approval is implied by local acceptance.

A classless heap representation was evaluated in copied temporary libraries
and **rejected**, not shipped. Same-batch long UPDATE medians: 313.927 ms
baseline, 317.684 ms retained candidate, 335.861 ms classless variant. See
[classless summary](classless_probe_summary.json) and
[experimental source patch](classless_rejected.patch). This probe assessed
control cost only; the rejected variant did not pass full feature acceptance.

The initial DISTINCT negative control at 10k rows/five calls was cancelled before
returning its first sample because the existing duplicate-checking path was
very expensive. Both variants were then measured at 1k rows/one call. The
incomplete probe is excluded from comparisons and logged in
[experiment notes](experiment_notes.json). DISTINCT optimization remains queued;
its cost is not attributed to the heap change.

To reproduce the extra controls after the main matrix:

```sh
python3 tool/optimizer_benchmark/followup.py
python3 tool/optimizer_benchmark/update_probe.py
```

The latter produces a fresh 20-pair long-probe summary. Historical combined
numbers above include the two recorded batches; new timing runs will vary.
See [validation.json](validation.json) for exact completed verification.
