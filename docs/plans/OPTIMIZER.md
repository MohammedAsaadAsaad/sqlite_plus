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
| 3 | Opt-in diagnostic instrumentation and plan decisions | Queued |
| 4 | Performance regression matrix | Initial matrix complete; expand per future item |
| 5 | Bounded Top-K selection | Accepted for tested scope; measured control costs documented |
| 6 | Use index ordering to avoid sorting | Queued |
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
  provisional headline speedups. Rich runtime diagnostics (item 3) remain queued;
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
- Rich runtime diagnostics (3), index ordering (6) and all later extensions are
  NOT implemented/accepted by this milestone. Roadmap-wide/release acceptance
  remains queued. No push, publication or merge performed.
