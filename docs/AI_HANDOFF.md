# AI handoff — sqlite_plus optimizer continuation

Checkpoint: 2026-11-11. This document is the continuation entry point; no prior
chat, original execution machine, credentials or preserved `/tmp` directory is
required. Read the current GitHub branch/PR and CI before making new claims.

## Latest completed item — 3, explicit diagnostics

**Accepted for tested local scope and documented control tradeoff**, not a release
or whole-roadmap acceptance. Read
[diagnostic evidence](../benchmark_results/optimizer_diagnostics/README.md) and
its validation/source/binary manifests. Initial negative results remain archived
under `initial_candidate/`; no zero-overhead guarantee is made. Inspector's
longer linked-OFF control has median paired ratio 1.0108 (ratio of medians1.0503).

Final-source core **10,719 passed / optional skip1**, Inspector55, focused/native14
(144 native result comparisons), VM/JS assertion example, packages/tool fatal-info
analysis and 548-file format all pass. Prior add-ons578/Search86 remain identified
as prior checks. Expanded OFF controls, enabled costs, trace bounds, privacy and
actual-row/page equivalence are recorded. Direct 20-pair BLOB comparison gives
median paired final/initial ratios0.3617 reader /0.6215 mutable. Unused ordinary,
ORM and update AOT binaries remain byte-identical to the initial candidate.

Read-only diagnosis relies on _prepareQuery's synchronous pre-await copy; parsing
and support checks before it must remain callback-free/synchronous. Mutable's
pre-routing copy remains required. Parameter-list/BLOB mutation tests protect
this boundary. Current reverse patch reconstructs the frozen baseline without
old /tmp files; default portable verifier passes for the accepted source.

**Active item: 14, IN/OR multiple-seek or union paths.** Item 13 is
correctness-verified and not cost-accepted. An automatic plan may use a
partial index when a numeric comparison is stronger than the index predicate.
`a >= 0`, an equality that fails the predicate, and `COLLATE` stay on the
table scan. `INDEXED BY` still requires the exact predicate, matching SQLite
3.53.1. Automatic results match that SQLite. No AOT sample is recorded yet.

Item 12 is correctness-verified and not cost-accepted. Inclusive `BETWEEN` is
planned as `>=` and `<=` bounds. A composite index can equality-seek its
prefix and range-seek the next column, and that range can already yield
`ORDER BY` on the range column. `NOT BETWEEN` stays a filter. Pinned SQLite
3.53.1 matches the new comparisons. No AOT sample is recorded yet.

Item 11 is correctness-verified and not cost-accepted. Equal `sqlite_stat1`
estimates, including indexes with no statistics, prefer an index that already
yields `ORDER BY`, then a covering index, then a longer ordered prefix, then
the previous score. A lower estimate still wins. `SELECT a, b FROM t WHERE a
= 1` and the same query with `ORDER BY b` use covering index `iab`. Pinned
SQLite 3.53.1 matches those queries. No AOT sample is recorded yet.

Item 10 is correctness-verified and not cost-accepted. A non-covering secondary
index whose `sqlite_stat1` estimate visits at least as many rows as the table,
and which does not already supply `ORDER BY`, loses to the table scan.
Covering plans, `INDEXED BY`, and order-providing indexes stay. A zero index
cardinality is not treated as the population. Pinned SQLite 3.53.1 matches
`WHERE b = 1` after that stat is forced to `1000 1000`. No AOT sample is
recorded yet.

Item 9 is correctness-verified and not cost-accepted. A unique rowid or full
primary key makes later `ORDER BY` terms redundant. A chosen index that groups
a proper bare-column prefix block-sorts each run. Pinned SQLite 3.53.1 matches
those queries. No AOT sample is recorded yet.

**Item 8 remains accepted for its ordered LIMIT scope.** Item 8 is accepted only for a scan
that already yields `ORDER BY` and has no `WHERE`, aggregate, window,
`DISTINCT`, grouping, compound, or CTE. On 10,000 rows, `ORDER BY id DESC
LIMIT 1` median ratio is 0.011224 with separated ranges. The filtered control
median is 1.014597 with overlapping ranges, so there is no zero-cost claim.
Evidence: `benchmark_results/optimizer_early_stop/`.

**Item 7 remains implemented and unaccepted.**
A full scan can walk backward when `ORDER BY` is the exact reverse of the
primary or covering index. Range seeks still sort. Pinned SQLite 3.53.1 matches
the new DESC queries. 10,000-row AOT median ratios are 0.911461 for
`ORDER BY id DESC` and 0.757401 for covering `ORDER BY a DESC`; both ranges
overlap, so this is not acceptance. Evidence:
`benchmark_results/optimizer_reverse_order/`. Item 6 remains unaccepted.

**Item 6, index-order reuse, remains partial and unaccepted.** The direct
single-table reader can keep a forward primary or index order and can scan a
covering index when the primary tree does not already supply that order.
Aliases, qualified names, non-covering order-only scans, and unproved partial
or expression indexes still sort. Full-scan reversal is item 7. Preliminary 20,000-row
AOT medians: covering index order 0.752 with non-overlapping ranges; rowid
0.962; plain sort 0.988; non-covering order 1.035; 200 updates 1.041. The last
three ranges overlap, which is not a zero-cost result. Evidence:
`benchmark_results/optimizer_index_order/`. Do not start item 7, merge main, or
publish packages.

Repeat, from a clean checkout of this item's branch:

`python3 tool/verify_optimizer_handoff.py` now fails on
`packages/sqlite_plus/lib/src/sql/database.dart` because this item edits that
file. Leave the item 3 source manifest unchanged. Re-run the verifier on
`8ae5144` to confirm the accepted diagnostic source.

```sh
git fetch origin
git switch feature/optimizer-index-order-20261111
git worktree add --detach /tmp/opt-item3-verify 8ae5144
python3 /tmp/opt-item3-verify/tool/verify_optimizer_handoff.py
git worktree remove /tmp/opt-item3-verify
# Rebuild /tmp/sqlite-build/sqlite3 only if the pinned 3.53.1 binary is absent.
cd packages/sqlite_plus && dart test
cd ../..
# Rebuild both AOT probes against the item 3 baseline and this tree, then:
python3 tool/optimizer_benchmark/index_order_cost.py \
  /tmp/index-order-baseline.exe /tmp/index-order-candidate.exe \
  20000 8 benchmark_results/optimizer_index_order/preliminary.json
```

Archive `preliminary.json` before replacing it. Acceptance still needs wider row
counts and a decision on the update and non-covering medians.

## CI inspection, 2026-11-11

PR #44 at `a4fc3a9` was inspected before item 6. `packages/sqlite_plus_orm/example/prepared.dart`
failed `dart analyze --fatal-infos` on five `curly_braces_in_flow_control_structures`
infos. Those `if` bodies are now blocks, and the example analysis is clean.
Windows `sqlite_plus` failed one `app_database_test` with socket errno 10013, and
Windows Branches failed a draft lock with errno 33. The same ORM and Branches
jobs already fail on main `056e964`. Those two Windows results are environment
failures, not an item 3 product regression. Item 3's local acceptance is unchanged.
The reusable Arabic prompt is [AI_CONTINUATION_PROMPT.md](AI_CONTINUATION_PROMPT.md).

## 1. Get the actual work

Repository: https://github.com/MohammedAsaadAsaad/sqlite_plus

PR #43 has been merged into `main` as
`056e9644fafb94de180dc6b761545be31e4a83f3`. The original upload commit was
`73617cdf23b3f0d76dbf985b7daaa0a1afe6473f`.

**Active continuation:** `feature/optimizer-diagnostics-20261111`, item 3,
**item3 accepted for measured local scope; next item6 queued**. Start by inspecting this branch and its PR;
main contains the completed previous checkpoint. Avoid simultaneous edits by
multiple AI clients; inspect the latest handoff/commit before resuming.

```sh
git clone https://github.com/MohammedAsaadAsaad/sqlite_plus.git
cd sqlite_plus
git fetch origin
git switch --track origin/feature/optimizer-diagnostics-20261111
git status --short
git rev-parse HEAD
```

If this active branch is already merged, read the newest main handoff instead.
Make a separate working branch for the next milestone; do not force-push or
discard another contributor's work. Package publication and automatic main
merges remain outside the authorized scope.

Read, in order:

1. [AGENTS.md](../AGENTS.md), [MASTER_SPEC.md](../MASTER_SPEC.md).
2. [42-item optimizer ledger](plans/OPTIMIZER.md).
3. [Optimizer audit](../benchmark_results/optimizer/AUDIT.md).
4. [Results and costs](../benchmark_results/optimizer/README.md), including
   negative controls, follow-ups and the cancelled/rejected experiments.
5. [Compatibility](../COMPATIBILITY_MATRIX.md), [implementation plan](../IMPLEMENTATION_PLAN.md),
   and the newest entries in [development log](../DEVELOPMENT_LOG.md).

## 2. User requirements — preserve these across clients

The user's instruction was: prepare a comprehensive plan, do not advance/accept
an item before sufficient performance AND cost tests, and report progress
regularly. The user subsequently acknowledged the initial measured result and
asked to preserve all work and continuation instructions on GitHub.

- **New user requirement (2026-11-11): upload every completed item immediately.**
  Update this handoff and the stable-ID ledger, commit code/tests/raw evidence,
  push the checkpoint and open/update its review PR before starting the next
  item. Report actual CI status. Do not wait to accumulate several milestones.
  When interrupted mid-item, upload an explicitly partial checkpoint with
  completed checks, unresolved work and the exact next commands; never label
  incomplete work accepted. Routine checkpoint uploads are authorized.
- Work autonomously on the approved roadmap, one reviewable milestone at a time.
  Routine implementation/testing does not need repeated permission questions.
- Give concise progress updates while working, normally at least once per minute:
  current item, findings, checks, measured costs, what is still uncertain.
- Preserve existing behavior and default paths. Keep optional features opt-in;
  avoid global hooks/cache/write overhead for unused features.
- Pure Dart production execution. Native SQLite is a development oracle only;
  no FFI, native/WASM SQLite or platform-channel database execution.
- Do not add packages just to inflate the package count. Strengthen existing
  engine/ORM/Inspector/Branch facilities where appropriate.
- ORM must use public engine interfaces and keep tracking, codecs, managed
  versions, dirty-state protection, Changes/Reactive/Inspector interception,
  transactions, constraints, triggers and rollback behavior.
- Do not silently migrate destructive schemas, publish packages, automatically
  merge main, or broaden device/durability/release claims.
- Another client is not evidence that a step was accepted. Use the ledger and
  actual artifacts; preserve stable item IDs and honest partial statuses.

## 3. Exact current optimizer state

The authoritative 42-row state table is [plans/OPTIMIZER.md](plans/OPTIMIZER.md).

| Item | State at this checkpoint |
| --- | --- |
| 1, audit | Complete |
| 2, source baseline | Complete, reverse reconstruction verified |
| 3, richer opt-in runtime diagnostics/plan decisions | **Accepted for tested scope and documented control tradeoff** |
| 4, regression matrix | Initial matrix complete; must expand for later changes |
| 5, bounded Top-K | Accepted **for tested scope and documented tradeoff** |
| 6–41 | Queued; some underlying facilities existed earlier, extensions are not complete |
| 42, whole-roadmap/release acceptance | Queued |

### What item 5 actually changes

`packages/sqlite_plus/lib/src/sql/database.dart::_evaluate` already bounded
ordinary explicit-LIMIT/non-DISTINCT result candidates to
`K=LIMIT+max(OFFSET,0)`. It found the last worst row by scanning K entries on
every later candidate. It was incorrect to describe all of these as full-input
sorts. The implemented change uses
`lib/src/sql/bounded_sort_heap.dart::BoundedSortHeap` for **K>=32**, created only
on overflow of the retained set. It shares the same list, keeps sequence ties,
preserves candidate projection decisions, and still sorts the final retained
entries. Tiny K, DISTINCT, unlimited and unsupported shapes keep their paths.

No schema/API/dependency or write-path change. No claim that this reduces page
reads, removes upstream materialization or makes every LIMIT query stop early.
The recursive CTE heap is a different facility. The cutoff 32 is conservative
and measured, not proven globally optimal.

Existing planner facilities include rowid equality/ranges, eligible secondary/
composite/expression/partial indexes, STAT1 ranking and limited covering reads.
Join reordering is only a narrow simple 2–3-source case, not a full join optimizer.
STAT4 is not consumed. Index recommendation in Inspector is not automatic query
optimization, and prepared syntax reuse is not a full physical-plan cache.

### Evidence and limits — do not omit the control costs

- Full core: **10,705 passed**, one optional skip.
- Full ORM/Changes/Sync/Branch/Inspector/Jobs/Reactive/Geo/Vec/Arabic: **572 passed**;
  two new ORM/cache/prepared ordering tests separately passed.
- Search: **86 passed**. Generator had **78 passed** during the prepared milestone;
  generator was not rerun for Top-K because generator/ORM production sources
  did not change in that milestone.
- 300 pinned native sort/result comparisons across three encodings. VM and
  compiled JS assertions pass. This is not actual browser/device performance.
- 27 paired AOT workloads / 270 processes: matching results/counts, reads/bytes,
  visit counts and projection traces. Comparison counts may differ by design.
- 10k rows/K1000, **three calls**: median 5812.859 -> 425.866 ms (13.65x).
- 100k rows/K1000, **one call**: median 20976.341 -> 1210.557 ms (17.33x).
- Instrumented case: 90,869 -> 4,853 comparisons. Large-case peak RSS roughly
  unchanged. Whole-process RSS is not a precise retained-allocation profile.
- **Costs remain visible:** short ordinary UPDATE median +5.7% over 20 samples;
  amplified 100k-update combined median +1.9% over 20 samples. Ranges overlap,
  which proves neither equivalence nor zero overhead. The user acknowledged
  this disclosed local tradeoff; do not invent a blanket zero-overhead claim.
- Classless representation was tested in temporary copies and rejected after
  worse UPDATE-control performance. It is NOT the shipped implementation.
- An excessively expensive 10k-row DISTINCT negative control was cancelled
  without recording a completed timing; both variants were then measured at
  1k rows/one call. DISTINCT improvement is still queued (item 30).
- These are Linux x64/Dart 3.13.7 AOT samples. No mobile, real browser,
  Windows/macOS optimizer-performance or production-release acceptance.

Original evidence is in `benchmark_results/optimizer/`. Local status in its
validation.json describes the historical run, not current GitHub CI. Existing
`push_merge_publish:false` records mean those tests happened before upload;
do not rewrite historical evidence to pretend remote checks already passed.

## 4. Acceptance protocol for EVERY next item

Use: **queued -> investigating -> implemented/unaccepted -> accepted OR rejected**.

1. State the exact supported SQL/domain, expected saved work and potential costs.
2. Freeze the **current** baseline/source hashes before runtime edits. Do not use
   old Git HEAD or yesterday's binary as the baseline for a new milestone.
3. Add positive/negative/boundary/regression tests. SQL evaluation changes need
   pinned SQLite comparison: values/types, required ordering, NULL, collations,
   duplicates, offsets, changing bindings, callback behavior and exceptions.
4. Preserve optimizer safety barriers: outer/CROSS join semantics, materialization,
   nondeterministic/side-effectful functions and unsupported schemas must not be
   transformed speculatively. Keep a correct fallback.
5. Run affected full suites plus raw/prepared/ORM and VM/JS consumers. Add storage
   corruption/crash recovery tests if touching write/storage protocols.
6. Build AOT variants with identical driver/dependencies. Stop tests/compilers
   while measuring. Use multiple fresh processes, alternate order, record
   setup/warm-up boundaries and full ranges; enlarge samples for unclear results.
7. Measure end-to-end time and actual saved work: reads/bytes, examined rows,
   comparisons, joins, intermediate counts, memory, image/binary growth, and
   planning/disabled-feature costs where applicable. `explain_us` currently
   measures only explain(), NOT isolated complete planning time.
8. Test losing cases too: tiny/large inputs, skew, no/many matches, no/stale stats,
   small/large K, no LIMIT, missing/covering indexes, normal reads/writes, defaults.
9. Investigate repeatable regressions and document tradeoffs. There is **no user-
   approved universal 3% or 5% threshold**. Do not hide slow cases, cherry-pick,
   claim significance from overlapping ranges, or change both workload and label
   without recording it. Reject or leave unaccepted if benefit/cost is unresolved.
10. Only accept based on sufficient correctness/performance/cost evidence for the
    **final source**. Source changes after timing need fresh relevant evidence.
    Update ledger, compatibility, development log and cost report together.
11. Preserve existing artifacts; create a new milestone/run directory or worktree.
    Scripts below overwrite historical paths if run in-place: back up/version the
    evidence before timing. Do not mutate recorded hashes to silence a failure.

Every stop/checkpoint must state active item, what changed, checks completed,
known costs, unresolved failures and the exact next command. Keep work reviewable
and sync checkpoints when requested; never claim pending work complete.

## 5. Fresh-machine setup and correctness commands

Linux is the reference environment for the following commands. Requirements:
Dart **3.13.7**, Python 3, Git, GNU patch, Node.js; C compiler/curl/unzip for the
native test oracle. Install tools using the new client's environment facilities;
there is no dependency on the old `/workspace/toolchains` shell script.

```sh
dart --version
dart pub get --enforce-lockfile
python3 tool/verify_optimizer_handoff.py
bash tool/build_sqlite_reference.sh
export SQLITE_PLUS_SQLITE3=/tmp/sqlite-build/sqlite3
```

The reference source ID must be
`2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`.
The shell script checks it. Native SQLite never executes production queries.

```sh
dart format --output=none --set-exit-if-changed packages/sqlite_plus packages/sqlite_plus_orm tool/optimizer_benchmark
dart analyze --fatal-infos packages/sqlite_plus packages/sqlite_plus_orm tool/optimizer_benchmark
(cd packages/sqlite_plus && dart test)
dart test packages/sqlite_plus_orm/test packages/sqlite_plus_changes/test packages/sqlite_plus_sync/test packages/sqlite_plus_branch/test packages/sqlite_plus_inspector/test packages/sqlite_plus_jobs/test packages/sqlite_plus_reactive/test packages/sqlite_plus_geo/test packages/sqlite_plus_vec/test packages/sqlite_plus_arabic/test
(cd packages/sqlite_plus_search && dart test)
dart run tool/optimizer_benchmark/assertions.dart
dart compile js tool/optimizer_benchmark/assertions.dart -o /tmp/optimizer-assertions.js
node -e 'globalThis.self=globalThis;require(process.argv[1])' /tmp/optimizer-assertions.js
```

For the complete pure-Dart workspace upload check, use
`dart analyze --fatal-infos packages tool` and
`dart format --output=none --set-exit-if-changed packages tool`.
Both passed at synchronization (536 Dart files format-clean). A root-wide
`dart analyze` also traverses the separate `browser/` and `examples/` Flutter
apps: without their own `flutter pub get` it reports missing Flutter imports.
The attempted root check was NOT green (7,367 diagnostics); root format check
also reported seven pre-existing formatting differences in unchanged comparison/
notes app files. No Flutter app file was changed by this sync. Resolve each
app's own dependencies and use its Flutter checks if touching it; do not mistake
these environment/scope results for successful whole-repository validation.

Core and Search fixture suites require their package working directory. Generator
uses the normal `dart test` launcher (some tests spawn `Platform.resolvedExecutable`
for formatting); rerun it if relevant. Network-restricted harnesses may need
localhost IPC access for Dart tests. Do not confuse a harness/tool failure with
a product failure; record both accurately. The existing GitHub workflow runs the
broader platform/package matrix; inspect actual remote status before merge.

## 6. Rebuild measurements without preserved /tmp artifacts

`python3 tool/verify_optimizer_handoff.py` checks the 42 IDs, measured runtime
hashes, all recorded result/IO/callback gates and reconstructs historical
optimizer/prepared baselines in temporary copies. It requires Python/patch only.
Default verification checks the accepted current runtime manifest and the
historical baseline/result chain. It does not rerun diagnostic timings; the
diagnostic summarizer and recorded control assertions supply those separate
gates. The optional --allow-unaccepted-diagnostics flag only permits baseline
reconstruction for a future partial candidate; it never means acceptance. A
later feature needs its own frozen baseline/evidence.

For the optimizer, in a separate worktree/evidence copy (outputs overwrite files):

```sh
python3 tool/optimizer_benchmark/build.py
# All compilation/seeding must finish; stop other tests/compilers before timing.
python3 tool/optimizer_benchmark/run.py
python3 tool/optimizer_benchmark/regression.py
python3 tool/optimizer_benchmark/edges.py
python3 tool/optimizer_benchmark/summarize.py
python3 tool/optimizer_benchmark/followup.py
python3 tool/optimizer_benchmark/update_probe.py
```

The builder copies libraries, reverses the committed optimizer patch in those
copies, builds baseline/current AOT executables, and recreates all seed images.
The original baseline included previous Jobs/import/prepared work; Git HEAD was
not that baseline. Record new source/binary hashes when collecting a new run.
The original combined long UPDATE summary used two batches including the
three-way experiment; `update_probe.py` makes a fresh 20-pair run instead.

Historical prepared baselines require undoing optimizer FIRST, then prepared.
The verifier proves that chain against committed hashes. The older
`tool/prepared_benchmark/build.py` reverses prepared only: on this later snapshot
it must not be assumed to recreate the original pre-optimizer measurement.
Use a temporary pre-optimizer copy or extend the builder with both snapshots
and hash checks before relying on historical reproduction. Never reverse patches
in the working production tree. `/tmp` paths in manifests are historical labels,
not required downloads. Rejected classless source is preserved as a patch,
not active production code. Older Jobs/import performance fixtures are likewise
milestone-relative: reconstruct in reverse chronological order and verify hashes
before treating them as exact historical baselines.

## 7. All pending work included in this synchronization

This upload includes earlier local work as well as optimizer changes:

| Work | Entry point |
| --- | --- |
| Branch preview, ORM import, Inspector advisor/record/replay | [PREVIEW_IMPORT_DIAGNOSTICS](plans/PREVIEW_IMPORT_DIAGNOSTICS.md) |
| Import/UPSERT performance | [IMPORT_PERFORMANCE](plans/IMPORT_PERFORMANCE.md), `benchmark_results/import_performance/` |
| Embedded Jobs | [JOBS](plans/JOBS.md), `packages/sqlite_plus_jobs/README.md` |
| Jobs/core performance | [JOBS_PERFORMANCE](plans/JOBS_PERFORMANCE.md), `benchmark_results/jobs_performance/` |
| Engine/ORM prepared statements | [PREPARED](plans/PREPARED.md), `packages/sqlite_plus_orm/doc/PREPARED.md` |
| Optimizer and remaining 42-item roadmap | [OPTIMIZER](plans/OPTIMIZER.md), `benchmark_results/optimizer/` |

Preserve all of it. Packages/CI must use workspace versions; do not infer
independent publication readiness. Jobs needs the relevant core fixes released
before an independent dependency-floor decision. Optional ORM cache defaults to
0, wrapper adapters preserve interception, Changes-backed prepared writes use
the capture path, and Branch keeps its existing schema/ownership restrictions.
Detailed release/device/ownership limits remain in each package README.

## 8. Next concrete work — item6, after uploading item3

1. Inspect the latest branch/main/PR and CI; avoid simultaneous client edits.
   Run `python3 tool/verify_optimizer_handoff.py` before changing runtime.
2. Read stable item6 in [OPTIMIZER.md](plans/OPTIMIZER.md), the existing planner
   audit and source. Item6 is queued, not implemented by the diagnostic work.
3. Specify supported index-order reuse, tie/NULL/collation/direction/partial/
   expression-index and fallback cases before implementation. Preserve existing
   projection decisions, LIMIT/OFFSET membership and bindings; do not assume an
   index satisfies ordering solely because it shares a column name.
4. Freeze the accepted item3 source as the new baseline; keep earlier reverse
   patches/manifests/raw results unchanged. Add positive/negative/boundary tests,
   pinned SQLite differential coverage and relevant complete regression suites.
5. Build sequential fresh-process AOT benchmarks for positive and negative
   controls (small/large data, LIMITs, missing indexes, fallback paths, ORM/write
   controls, result/page/size/memory costs). Investigate regressions and record
   tradeoffs; no fixed unapproved percentage budget or headline-only acceptance.
6. Update validation/ledger/compatibility/log/handoff, commit and upload item6
   immediately with actual CI state before moving to item7. Partial work must
   be labelled unaccepted with exact next commands. No merge/publication.

To repeat item3 evidence, use its README commands; stop tests/compilers before
timing, archive results before regeneration, and preserve affinity distinctions.

## 9. Paste this to a new AI client

> Fetch the latest MohammedAsaadAsaad/sqlite_plus main and active branch named
> at the top of this handoff. Read AGENTS.md, docs/AI_HANDOFF.md and the 42-item
> ledger before edits. Use the newest checkpoint, not a chat assumption.
> Complete the active item's remaining correctness/performance/cost gates;
> item3 is accepted for its documented tested scope; item6 is next. Preserve default behavior,
> pure Dart, ORM ownership/Changes/Reactive and all negative evidence. Report
> progress regularly. After EACH completed item update handoff/ledger/evidence,
> commit/upload/open or update its PR immediately before moving on. If stopping
> early, upload an honest partial checkpoint with exact next commands. Do not
> automatically merge main or publish packages.

## Completed checkpoint — item3 (2026-11-11)

- Active PR: https://github.com/MohammedAsaadAsaad/sqlite_plus/pull/44 .
  Initial policy-only checkpoint: aae714e7. Current branch head is authoritative.
- Added explicit read-only/mutable diagnoseQuery APIs and Inspector profile
  capability. Candidate metadata is bounded, names clipped, estimates nullable,
  no SQL/bindings/results in metadata JSON, no retained executable plan closures.
- Counters distinguish upstream rows loaded, predicate visits/matches, returned
  rows and pager reads; sort strategy/retained rows are defined. Unmeasured
  projection/comparison/index-key/allocation counters remain null. Planner
  reasons describe existing rules/STAT1, not a complete cost model.
- Mutable diagnosis routes the actual temp/main/attached schema, holds normal
  connection exclusion through callbacks, rejects cross-schema/unsupported
  sources and closes the private reader. Inspector delegates rather than
  silently inspecting main. ORM explicit profile validates lease/closed state.
- Normal query/evaluation has no unconditional per-row instrumentation; counted
  iterables are selected only for explicit diagnosis. No global observer/cache.
- Correctness: final-source 10,719 core passed / optional skip1; 578 add-ons passed before
  the final Inspector-only lease/async-error refinement; final complete Inspector
  suite 55 passed afterward; Search 86. New focused checks include 144 pinned
  native comparisons, changing bindings, NULL/collation/limits, traces/callbacks,
  privacy/BLOB copy, Unicode clipping, temp/attached routing, overlap/reentrancy,
  ORM ownership/Changes capture. See validation.json in the new evidence folder.
- VM and compiled JS/Node assertions passed on the copy-reduction candidate.
  Node requires globalThis.self=globalThis; a silent Node exit is not a pass.
  Native CLI was rebuilt successfully.
- AOT/cost acceptance is limited to the tested scope and documented Inspector
  control tradeoff. All negative initial results and final repeated data remain.
  Source/binary/driver hashes, reverse patch and portable verifier preserve the
  diagnostics -> Top-K -> prepared chain without old temporary files.
- Final primary/follow-up/pinned/extended/linked/BLOB controls and direct paired
  copy-reduction experiments are complete. See the evidence README and
  validation.json. CI is not presumed green; inspect the latest PR head.
