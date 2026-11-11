# Optimizer roadmap and acceptance ledger

Continuation entry point: [AI handoff](../AI_HANDOFF.md).

Authorized roadmap: correctness plus measured execution/planning/memory/IO cost
before accepting each item. One milestone at a time; preserve preceding local
changes. Statuses: queued, investigating, implemented/unaccepted, accepted,
rejected. Nothing becomes accepted solely because tests pass or asymptotics look
better. No universal zero-overhead or SQLite optimizer equivalence claim.

| ID | Item | Status |
| --- | --- | --- |
| 1 | Audit existing planning/execution paths | Complete; see AUDIT.md |
| 2 | Preserve source baseline and reproducible workloads | Complete; reverse fixture verified |
| 3 | Opt-in diagnostic instrumentation and plan decisions | Accepted tested local scope/control tradeoff on PR #44; see diagnostics evidence |
| 4 | Performance regression matrix | Initial matrix complete; expand per future item |
| 5 | Bounded Top-K selection | Accepted for tested scope; measured control costs documented |
| 6 | Use index ordering to avoid sorting | Implemented/unaccepted; direct-path forward order only; preliminary AOT recorded |
| 7 | Reverse index scans | Queued |
| 8 | Safe early termination | Queued |
| 9 | Partial/block sorting | Queued |
| 10 | Table/index/lookup/sort cost comparison | Queued |
| 11 | Broader covering-index reads and costing | Queued |
| 12 | Composite equality/range/order planning | Queued |
| 13 | Partial/expression index eligibility | Queued |
| 14 | IN/OR multiple-seek/union paths | Queued |
| 15 | WITHOUT ROWID access planning | Queued |
| 16 | Evaluate intersection and skip-scan | Queued |
| 17 | Improve STAT1 estimates | Queued |
| 18 | Evaluate skew-aware/STAT4 samples | Queued |
| 19 | Stale/missing statistics safeguards | Queued |
| 20 | Statistics gathering/loading cost | Queued |
| 21 | Broader safe predicate pushdown | Queued |
| 22 | Bounded join-order search | Queued |
| 23 | Indexed inner join access | Queued |
| 24 | Evaluate alternative join algorithms | Queued |
| 25 | Bounded temporary lookup structures | Queued |
| 26 | EXISTS early exit | Queued |
| 27 | Safe reuse of uncorrelated subqueries | Queued |
| 28 | Correlated query transformations | Queued |
| 29 | CTE/derived pushdown and materialization choices | Queued |
| 30 | Ordered DISTINCT/GROUP BY | Queued |
| 31 | MIN/MAX/COUNT shortcuts | Queued |
| 32 | Streaming aggregation | Queued |
| 33 | Safe constant-expression simplification | Queued |
| 34 | Predicate simplification/contradictions | Queued |
| 35 | Intermediate projection pruning | Queued |
| 36 | Broader streaming execution | Queued |
| 37 | Safe per-execution common work reuse | Queued |
| 38 | Bound planning complexity | Queued |
| 39 | Prepared statement integration | Queued |
| 40 | Evaluate plan caching, default off | Queued |
| 41 | Inspector integration | Queued |
| 42 | Whole-roadmap regression/release documentation | Queued |

## Acceptance per item

Record target queries and baseline first. Test results/types, required ordering,
NULL/collation/duplicate/offset/parameter boundaries and callback behavior;
pinned native differential where SQL execution changes. Run relevant full
regressions and VM/JavaScript assertions. Compare sequential fresh-process AOT
variants with alternating order, identical data/results, multiple samples,
execution time, memory and IO; report planning-cost limits honestly. Investigate
regressions; accept only evidenced benefit for documented eligible workloads.
Do not treat overlapping timing ranges as conclusive speedups.

## Audit finding: bounded sorting already exists

`database.dart::_evaluate` already prunes ordinary non-DISTINCT explicit-LIMIT
ORDER BY candidates to LIMIT+positive OFFSET and skips projection of rejected
candidates. The preserved baseline scanned retained keys to find the last worst entry per
candidate: O(N*K), not necessarily a full O(N log N) sort. Final retained entries
are sorted with sequence tie-breaking. Item 5 evaluates a max-heap replacement,
preserving equal-key rejection, earliest tie retention and projection timing.
The heap in relational.dart is a recursive CTE work queue, not this selection.

Current planner: rowid lookup/ranges, eligible secondary/composite/partial/
expression indexes with STAT1 ranking, bounded covering paths. Existing join
reordering is restricted to 2–3 simple CROSS sources with ORDER BY and counts;
it is not general join costing. STAT4 is not consumed. Do not overstate these
as complete facilities or mark their extensions accepted without measurements.

## Initial milestone progress, 2026-11-08

- Source baseline frozen before this optimizer change (including previous
  prepared/Jobs/import work). Reverse fixture reconstruction byte-matches it.
- 10,705 core tests passed / one optional skip; 572 full add-on tests, 86 Search
  tests, two new ORM tests; native sort differential has 300 comparisons across
  three encodings. VM/JS assertion consumer and fatal-info analysis pass.
- AOT comparisons run sequentially AFTER tests/compilers stop. Include small K,
  threshold boundaries, large LIMIT, unlimited/DISTINCT/unordered/point reads,
  1k/10k/100k rows, ordered/reverse/tie-heavy data, stable files, callback traces,
  comparison/visit counts, RSS, IO and ordinary read/write/ORM regressions.
- Tiny/almost-full K cases were added before acceptance. Nothing is accepted based on
  provisional headline speedups. Rich runtime diagnostics (item3) are accepted separately below;
  current measurement wrappers have no new production instrumentation hook.

## Initial milestone outcome

- 27 paired workload cases / 270 fresh processes passed result/IO/visit/projection
  equivalence gates; ordinary read/write/default-ORM regressions and targeted
  follow-up probes completed. Evidence: benchmark_results/optimizer/README.md.
- Accepted item 5 as a measured benefit/cost tradeoff: 10k/K1000 13.65x and
  100k/K1000 17.33x faster in documented loops; small K stays linear, no LIMIT/
  DISTINCT retain paths, memory remains bounded by the existing retained list.
- Keep all control costs visible: short ordinary UPDATE median +5.7%; combined
  amplified long probe +1.9%, overlapping ranges. Do not claim zero overhead.
- Rejected an isolated classless representation after worse control performance.
- Index ordering (6) and later extensions remain
  NOT implemented/accepted by this milestone. Roadmap-wide/release acceptance
  remains queued. No push, publication or merge performed.

## Continuation policy, 2026-11-11

PR #43 merged into main 056e9644. Item3 is accepted below; item5 remains accepted only
for its documented scope/costs. The user requires immediate GitHub upload and
handoff/ledger updates after EVERY completed item, before starting the next.
Partial checkpoints must identify incomplete work and never imply acceptance.
See docs/AI_HANDOFF.md for the active branch and exact next steps.

## Item3 accepted local checkpoint

Explicit core/Inspector diagnosis, bounded decisions/actual counters, routing,
privacy/ownership and pre-await binding isolation are verified. Final core10719
(optional skip1), Inspector55, focused/native14 (144 result comparisons), VM/JS,
packages/tool analysis/format pass. Expanded OFF/ON and unused-control AOT data
and direct BLOB copy comparisons are retained. Inspector point OFF median paired
ratio1.0108 is a documented tradeoff; no zero-overhead or release claim.
See benchmark_results/optimizer_diagnostics/README.md and docs/AI_HANDOFF.md.
Initial negative evidence is archived. Next item6 remains queued until this
completed checkpoint is uploaded; no main merge or package publication.

## Item 6 partial checkpoint, 2026-11-11

Not accepted. A direct single-table forward scan may skip the later sort when
the primary tree or the chosen index already yields the requested order. A
covering secondary index may be selected for `ORDER BY` only when the primary
scan does not already provide that order. Descending reversal, qualified or
aliased sources, non-covering order-only scans, expression indexes, and partial
indexes whose predicate is not proved stay on the existing sort.

Correctness on this machine: `packages/sqlite_plus` `dart test` passed 10,629
with 30 skips. The 21 failures were `ProcessException` for a missing
`/tmp/sqlite-build/sqlite3` before that binary was built. After building SQLite
3.53.1, source id
`2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`,
`index_order_test` and the pinned native suites named in the evidence README
passed. `dart analyze --fatal-infos` was clean for `packages/sqlite_plus` and
the ORM example.

Preliminary AOT, Dart 3.13.7, Linux x64, 20,000 rows, 8 alternating fresh-process
pairs, one query after the insert. Checksums matched inside each mode. Covering
`ORDER BY a` median ratio 0.752 and the sample ranges do not overlap. `ORDER BY
id` ratio 0.962, unordered `ORDER BY b` ratio 0.988, non-covering `ORDER BY a, b`
ratio 1.035, and 200 updates ratio 1.041. The last three ranges overlap. Overlap
is not a zero-cost result. Raw rows:
`benchmark_results/optimizer_index_order/preliminary.json`.

Do not start item 7. Repeat the probe at more sizes, then decide whether the
update and non-covering medians are noise or a planning cost that must be
removed. No main merge and no package publication.
