# Explicit query diagnostics — measured local scope

Item 3 is **accepted for the tested scope and documented control tradeoff**
(2026-11-11), not a whole-roadmap/release acceptance. Frozen baseline: merged
main `056e9644fafb94de180dc6b761545be31e4a83f3`; review PR #44.

Explicit `diagnoseQuery` / Inspector `profile` reuse the real planner/evaluator
once. They support scalar ordinary single-source and constant SELECTs, including
filter/order/limit and optional DISTINCT. Unsupported joins, CTEs, views, virtual
or generated sources, aggregates/windows reject before SQL callbacks. Normal SQL
coverage remains unchanged. ORM profiling respects connection leases and capture.

## Correctness and cost decision

Final-source full core: **10,719 passed / one optional skip**; full Inspector55,
focused/native14 (144 native result comparisons across three encodings), and
VM/compiled-JS assertion example pass. Packages/tool fatal-info analysis and
548-file format check pass. Prior full add-ons578/Search86 are retained as prior
checks, not falsely described as rerun after the diagnostic-only copy reduction.

All primary OFF/ON result hashes, row counts, image sizes and available page
counts match. Trace-cap, privacy, actual-counter and unavailable-counter gates
pass. Default-path observations were expanded rather than judged from five
samples or overlapping ranges. Initial higher medians and every raw sample are
preserved in `initial_candidate/`; they are not rewritten into a clean baseline.

The decision accepts an explicit developer diagnostic feature with measured
costs, not a speed optimization or a guarantee of zero disabled overhead. In the
longer pinned Inspector point control the median paired ratio is **1.0108**;
medians considered separately are 93.168 / 97.8555 ms (**+5.03%**). These are
different statistics; neither is hidden. This small observed control tradeoff
is retained in acceptance. No user-approved universal percentage budget was
invented. Other expanded controls vary in both directions; do not interpret
negative ratios as an optimizer speedup or range overlap as equivalence.

## Expanded controls

Unpinned follow-up: original five plus fifteen further processes per variant.
No affinity was applied and these are not pooled with pinned measurements.

| Control | Baseline median ms | Linked OFF median ms | Ratio of medians |
| --- | ---: | ---: | ---: |
| unused-read | 38.9905 | 38.7540 | 0.9939 |
| linked-point-reader | 45.5910 | 45.8520 | 1.0057 |
| linked-point-mutable | 4.6410 | 4.0255 | 0.8674 |
| linked-large-sort | 1318.5590 | 1285.8930 | 0.9752 |

Separate CPU-0 paired investigations. Paired ratios use each alternating pair,
then take the median; they are not the ratio of two independently taken medians.
Unrelated sizes, trial counts and affinity regimes are never pooled.

| Control | Pairs | Median paired OFF/baseline |
| --- | ---: | ---: |
| unused-read | 30 | 0.9888 |
| mutable-point-1000 | 30 | 0.9836 |
| ordinary insert 10000 | 20 | 0.9877 |
| ordinary update 10000 | 20 | 0.8984 |
| orm  | 10 | 0.9940 |
| update  | 20 | 0.9809 |
| linked case 1 (reader, scan) | 20 | 0.9729 |
| linked case 6 (reader, index) | 20 | 0.9356 |
| linked case 9 (inspected, point) | 20 | 1.0108 |

## Enabled cost and BLOB improvement

`summary.json` contains the complete 11-case × three-variant × five-process
matrix. Example short-read totals: point500 baseline/OFF/ON
46.512 / 43.365 / 52.277 ms; Inspector point100
10.011 / 10.848 / 14.391 ms. ON costs are expected and explicitly opt-in.
Some scan/sort ON medians are lower, partly because diagnostic parsing differs;
this is not evidence that diagnostics speeds up normal queries.

Read-only diagnosis now relies on `_prepareQuery`'s synchronous pre-await value
snapshot, removing a redundant BLOB copy. The mutable outer pre-routing snapshot
remains. Tests mutate argument lists and bytes immediately after calling both
APIs. An await or user callback before `_prepareQuery` requires revisiting this
snapshot boundary. Ordinary/ORM/update binaries are SHA-256 identical to the
initial candidate (`unused_binary_identity.json`), so their previous unused
measurements remain applicable to the final source.

A direct alternating pinned comparison reconstructs the initial candidate from
its archived patch/source hashes and uses the same final driver for both.
Each process runs twenty 1 MiB bindings; twenty process pairs per adapter:

| Adapter | Initial ON median ms | Final ON median ms | Median paired final/initial |
| --- | ---: | ---: | ---: |
| reader | 13.7625 | 4.7270 | 0.3617 |
| mutable | 18.5805 | 11.6925 | 0.6215 |

`blob_summary.json` separately compares final baseline/OFF/ON (five processes
per variant); do not pool it with the twenty-pair initial/final experiment.

## Size, memory and counter semantics

Unused ordinary binaries: 10,171,680 / 10,171,800 bytes (+120). Primary linked
binaries: 10,238,400 / 10,276,968 (+38,568). These are compiler/driver-specific,
not installed package sizes. Reports for 32 candidate indexes serialize to
approximately 6,274 bytes at cap64 versus 760 bytes at cap0 using the driver's
Python json.dumps formatting in this workload;
all 32 candidates are enumerated even at cap0. RSS/peak RSS are process-level
observations including startup/results, not isolated allocation counters.

Trace entries cap at 0–256; index names clip at128 Unicode runes; SQL input caps
at65,536 UTF-16 code units. These bound metadata, not input/result/BLOB memory,
source materialization or mutable image copies. Index-key/projection/sort-
comparison/allocation counters remain null when not actually measured.

Rows loaded means materialized source length, visited means evaluator consumption,
matched means consumed passing rows, returned means final output. Early LIMIT
can separate them. Core source-preparation time includes planning; do not add
these overlapping phases. Core total excludes mutable routing/image opening and
outer report/wrapper work. AOT timers surround the API itself and include those
costs; serialization and result hashing occur afterward. Exclusive-reader use
is required for meaningful pager deltas. Metadata JSON omits SQL, parameters
and result values; the separately returned ordinary result naturally has data.

## Reproduce from a fresh checkout

Dart3.13.7/Linux x64; install dependencies first. No original /tmp is needed.

```sh
python3 tool/verify_optimizer_handoff.py
python3 tool/optimizer_diagnostics_benchmark/build.py
# Stop compilers/tests before all sequential measurements below.
python3 tool/optimizer_diagnostics_benchmark/run.py
python3 tool/optimizer_diagnostics_benchmark/summarize.py
python3 tool/optimizer_diagnostics_benchmark/unused_controls.py
python3 tool/optimizer_diagnostics_benchmark/followup.py
python3 tool/optimizer_diagnostics_benchmark/affinity_controls.py
python3 tool/optimizer_diagnostics_benchmark/blob_run.py
python3 tool/optimizer_diagnostics_benchmark/extended_controls.py
python3 tool/optimizer_diagnostics_benchmark/linked_controls.py
# Compile, then stop compilation before timing this separate experiment.
python3 tool/optimizer_diagnostics_benchmark/build_initial_blob.py
python3 tool/optimizer_diagnostics_benchmark/copy_comparison.py
```

Archive current evidence before regenerating it. The builder reconstructs main
with the reverse patch and checks source hashes; initial-candidate reconstruction
also validates its exact archived source hashes. Binary/driver hashes and seed
image hashes are retained. Per-query result hashes guard changing bindings.
The long write controls include dataset setup outside query timers; execution
numbers are not end-to-end startup times.

Limits: memory images on this machine, not file I/O, device performance,
durability, a full cost model, real-browser certification or package publication.
CI is tracked on PR #44; local evidence does not imply remote CI passed.
