# Optimizer roadmap and acceptance ledger

## Active correctness repairs — 2026-11-12

Branch: `fix/optimizer-correctness-20261112`. Baseline: `91a8545`.
The independent review found correctness regressions; the earlier closeout is historical, not a current passing gate.
Correctness checkpoints: 35, 33.
Still under repair: 32, 37, 21, 11, 31, 13, 14, 34, 22, 29.
Each checkpoint has focused/native regressions in `benchmark_results/optimizer_correctness/`.
Full final regressions and cost acceptance are separate and pending; no merge or publication is authorized by a checkpoint.

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
| 7 | Reverse index scans | Implemented/unaccepted; full-scan reverse matches SQLite 3.53.1; AOT ranges overlap |
| 8 | Safe early termination | Accepted for ordered LIMIT/OFFSET with no WHERE; filtered control median 1.0146 overlaps |
| 9 | Partial/block sorting | Correctness verified for a unique key tail and an index-prefix block sort; cost not yet separated |
| 10 | Table/index/lookup/sort cost comparison | Implemented/unaccepted; non-covering full-index visits stay on the table scan; no AOT sample |
| 11 | Broader covering-index reads and costing | Implemented/unaccepted; equal-estimate ties prefer order, then covering; no AOT sample |
| 12 | Composite equality/range/order planning | Implemented/unaccepted; inclusive BETWEEN becomes index bounds; no AOT sample |
| 13 | Partial/expression index eligibility | Implemented/unaccepted; stronger numeric bounds prove a partial predicate for automatic plans; no AOT sample |
| 14 | IN/OR multiple-seek/union paths | Implemented/unaccepted; constant IN and same-column OR seek each value; no AOT sample |
| 15 | WITHOUT ROWID access planning | Implemented/unaccepted; secondary equality and range seeks; primary tree is not pretended to be a seek; no AOT sample |
| 16 | Evaluate intersection and skip-scan | Rejected; a non-leading column stays a table scan, and two indexes are not intersected |
| 17 | Improve STAT1 estimates | Implemented/unaccepted; a range estimate is at least the next equality average; no AOT sample |
| 18 | Evaluate skew-aware/STAT4 samples | Rejected; sqlite_stat4 is stored and ignored, stat1 remains the estimate |
| 19 | Stale/missing statistics safeguards | Implemented/unaccepted; a recorded table cardinality is not inflated by a sibling index; no AOT sample |
| 20 | Statistics gathering/loading cost | Implemented/unaccepted; stat text longer than 65536 is ignored; no loading AOT sample |
| 21 | Broader safe predicate pushdown | Implemented/unaccepted; AND/OR skip the right side once the left side decides; no AOT sample |
| 22 | Bounded join-order search | Implemented/unaccepted; stat1 reorder covers 2–4 cross joins; 5 stays written order; no AOT sample |
| 23 | Indexed inner join access | Implemented/unaccepted; INNER JOIN equality on a leading index column seeks; OR and LEFT stay scans; no AOT sample |
| 24 | Evaluate alternative join algorithms | Rejected; nested-loop order matches SQLite 3.53.1, so a hash join is not used |
| 25 | Bounded temporary lookup structures | Implemented/unaccepted; inner-join lookup keeps at most 1024 distinct keys; no AOT sample |
| 26 | EXISTS early exit | Implemented/unaccepted; uncorrelated single-table EXISTS stops at the first match; no AOT sample |
| 27 | Safe reuse of uncorrelated subqueries | Implemented/unaccepted; an uncorrelated scalar subquery runs once; correlated counts stay per row; no AOT sample |
| 28 | Correlated query transformations | Rejected; a correlated subquery stays per outer row and is not flattened into a join |
| 29 | CTE/derived pushdown and materialization choices | Implemented/unaccepted; a repeated CTE runs once, NOT MATERIALIZED runs per use, derived LIMIT stays inside; no AOT sample |
| 30 | Ordered DISTINCT/GROUP BY | Implemented/unaccepted; ordered DISTINCT compares the previous row, and GROUP BY sorts only when a group arrives out of order; no AOT sample |
| 31 | MIN/MAX/COUNT shortcuts | Implemented/unaccepted; MIN/MAX of an integer primary key read one end; COUNT and filtered MIN stay full reads; no AOT sample |
| 32 | Streaming aggregation | Implemented/unaccepted; count/sum/avg/total/min/max keep a running value; bare columns still retain the group; no AOT sample |
| 33 | Safe constant-expression simplification | Correctness repair checkpoint; focused/native regressions pass; final suite/cost gate pending |
| 34 | Predicate simplification/contradictions | Implemented/unaccepted; a false direct-table filter skips the scan; count stays 0; functions still run; no AOT sample |
| 35 | Intermediate projection pruning | Correctness repair checkpoint; focused/native regressions pass; final suite/cost gate pending |
| 36 | Broader streaming execution | Implemented/unaccepted; an unordered table scan stops after LIMIT; a filter still scans; no AOT sample |
| 37 | Safe per-execution common work reuse | Implemented/unaccepted; identical uncorrelated scalars are reused; probe stays separate; no AOT sample |
| 38 | Bound planning complexity | Implemented/unaccepted; IN stays capped at 32 and join reorder at 4 sources; rows match SQLite; no AOT sample |
| 39 | Prepared statement integration | Implemented/unaccepted; a bound `a = ?` still chooses the index; rows match SQLite; no AOT sample |
| 40 | Evaluate plan caching, default off | Implemented/unaccepted; plans are not stored; ANALYZE changes the next explain; no AOT sample |
| 41 | Inspector integration | Implemented/unaccepted; diagnoseQuery shows an index seek, one-end MIN/MAX, and an inner-join SEARCH; item 3 manifests unchanged; no AOT sample |
| 42 | Whole-roadmap regression/release documentation | Closed as documentation; not a release acceptance and not a compatibility-matrix claim |

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

## Item 7 partial checkpoint, 2026-11-11

Not accepted. A direct full scan walks backward when every `ORDER BY` direction
is the opposite of the stored primary or covering-index key. Equality and range
seeks are not reversed. `index_order_test` matches pinned SQLite 3.53.1,
including `ORDER BY id DESC`, `ORDER BY a DESC`, and `ORDER BY b` on a DESC
index. The package suite passed 10,711 with one skip after the nine FTS failures
were traced to a local SQLite built without FTS4 and then rerun green.

Preliminary 10,000-row AOT median ratios: rowid DESC 0.911461, covering
`ORDER BY a DESC` 0.757401. Both sample ranges overlap, including one covering
candidate slower than every baseline sample. Raw rows:
`benchmark_results/optimizer_reverse_order/preliminary.json`.

Item 8 may start. Its early stop must preserve these orders. No package
publication.

## Item 8 accepted scope, 2026-11-11

A scan that already yields `ORDER BY` stops after `OFFSET + LIMIT` when there
is no `WHERE`, aggregate, window, `DISTINCT`, grouping, compound, or CTE.
`ORDER BY id DESC LIMIT 1` on 10,000 rows has median ratio 0.011224 and the
sample ranges do not overlap (47905–52367 vs 525–709 µs). The same limit with
`WHERE b = 'v0'` has median ratio 1.014597 and overlapping ranges. That control
is not zero cost. Evidence:
`benchmark_results/optimizer_early_stop/preliminary.json`.

Next is item 9. No package publication.

## Item 9 partial checkpoint, 2026-11-11

Not a cost acceptance. A rowid or a complete WITHOUT ROWID primary key already
determines `ORDER BY`, so later terms do not cause a sort. When a chosen index
scan groups a proper bare-column prefix, each equal run is sorted by the
remaining terms. `index_order_test` matches SQLite 3.53.1 for `ORDER BY id, b
DESC`, `ORDER BY id, a DESC` on a WITHOUT ROWID key, and `INDEXED BY iab WHERE
a = 1 ORDER BY b, id`. No fresh AOT sample is recorded for this shape yet.

Next is item 10. No package publication.

## Item 10 partial checkpoint, 2026-11-11

Not a cost acceptance. When `sqlite_stat1` estimates that a non-covering
secondary index visits at least as many rows as the table, and that index does
not already satisfy `ORDER BY` or a block-sort prefix, the planner keeps the
table scan. A zero index cardinality is not used as the population, so a stale
`0 0` stat still falls through the existing estimate. `INDEXED BY`, covering
plans, and order-providing indexes stay. `planner_statistics_test` matches
`NOT INDEXED` and pinned SQLite 3.53.1 for `WHERE b = 1` after the selective
stat is set to `1000 1000`. No fresh AOT sample is recorded.

Next is item 11. No package publication.

## Item 11 partial checkpoint, 2026-11-11

Not a cost acceptance. When two secondary indexes have the same `sqlite_stat1`
estimate, including when neither has statistics, the planner prefers the index
that already yields `ORDER BY`, then a covering index, then a longer ordered
prefix, then the previous score. A lower estimate still wins, so a selective
non-covering lookup is not replaced by a wider covering index. `SELECT a, b
FROM t WHERE a = 1` and `SELECT a, b FROM t WHERE a = 1 ORDER BY b` now use
covering index `iab`. `index_order_test` matches pinned SQLite 3.53.1. No
fresh AOT sample is recorded.

Next is item 12. No package publication.

## Item 12 partial checkpoint, 2026-11-11

Not a cost acceptance. An inclusive `BETWEEN` is planned as `>=` and `<=`
bounds, so a composite index can equality-seek its prefix and range-seek the
next column. `NOT BETWEEN` stays a filter. `WHERE a = 1 AND b BETWEEN 'a' AND
'c' ORDER BY b` uses index `iab` as a range scan that already yields that
order. `WHERE a BETWEEN 0 AND 2 ORDER BY a` is a range scan on `ia`.
`index_order_test` matches pinned SQLite 3.53.1, including the `NOT BETWEEN`
rows. No fresh AOT sample is recorded.

Next is item 13. No package publication.

## Item 13 partial checkpoint, 2026-11-11

Not a cost acceptance. An automatic plan may use a partial index when a
numeric query comparison is stronger than the index predicate, for example
`a > 1`, `a >= 1`, or `a = 3` against `WHERE a > 0`. `a >= 0`, `a = 0`, and a
`COLLATE` term do not prove it. `INDEXED BY` still requires the existing exact
proof, so `INDEXED BY partial WHERE a > 1` remains an error, matching SQLite
3.53.1. The automatic results match that SQLite. No fresh AOT sample is
recorded.

Next is item 14. No package publication.

## Item 14 partial checkpoint, 2026-11-11

Not a cost acceptance. A rowid table can seek a secondary index once per
distinct non-null constant in `column IN (...)` or `column = a OR column = b`
when that column is the index prefix. `NOT IN`, NULL-only lists, mixed-column
`OR`, subqueries, and lists longer than 32 stay on the previous path. The
residual filter still applies. Results match pinned SQLite 3.53.1, including
duplicate `IN` values and an extra `AND`. No fresh AOT sample is recorded.

Next is item 15. No package publication.

## Item 15 partial checkpoint, 2026-11-11

Not a cost acceptance. A `WITHOUT ROWID` table can use a secondary index for
an equality or range prefix. The table's own primary tree is not selected as
that seek, because reading it still walks the full primary index. `NOT
INDEXED` remains an `index-tree-scan`. `WHERE a = 10`, `a > 10 AND a < 30`,
`id = 2`, and `NOT INDEXED` match pinned SQLite 3.53.1. No fresh AOT sample
is recorded.

Next is item 16. No package publication.

## Item 16 rejected, 2026-11-11

Skip-scan and index intersection are not implemented. An index on `(a, b)` is
not used for `WHERE b = 2`, because the leading column is unconstrained and
this planner does not read `sqlite_stat4` samples. A query with both `ia` and
`ib` still uses one index and the residual predicate. Both shapes match
pinned SQLite 3.53.1. No AOT sample is recorded.

Next is item 17. No package publication.

## Item 17 partial checkpoint, 2026-11-11

Not a cost acceptance. A `sqlite_stat1` range estimate stays at least as large
as the average for equality on the next index column. With `broad` forced to
`1000 900 800` and `selective` forced to `1000 400`, `WHERE a>0 AND b=1`
chooses `selective`. Rows match `NOT INDEXED` and pinned SQLite 3.53.1. No
fresh AOT sample is recorded.

Next is item 18. No package publication.

## Item 18 rejected, 2026-11-11

`sqlite_stat4` rows are stored and are not read. A sample that says the big
table has one row does not change the stat1 join order or its page reads.
`engine_gap_test` and `db_browser_b1_test` cover that. No skew-aware estimate
is claimed.

Next is item 19. No package publication.

## Item 19 partial checkpoint, 2026-11-11

Not a cost acceptance. When `sqlite_stat1` has a table row, another index's
cardinality does not replace it. A wrong-width stat on `selective` still uses
the table cardinality, so `WHERE b=999` keeps that index beside a sibling stat
of `999999 1`. Rows match `NOT INDEXED`. No fresh AOT sample is recorded.

Next is item 20. No package publication.

## Item 20 partial checkpoint, 2026-11-11

Not a cost acceptance. Loading `sqlite_stat1` ignores a stat string longer
than 65536 characters and falls back to the prefix heuristic. The invalid-stat
test covers a 65537-character value and still returns the matching row. No
loading-time AOT sample is recorded.

Next is item 21. No package publication.

## Item 21 partial checkpoint, 2026-11-11

Not a cost acceptance. `AND` does not evaluate its right side when the left
side is false. `OR` does not evaluate its right side when the left side is
true. NULL on the left still evaluates the right side. Results for constant
`AND`/`OR` match pinned SQLite 3.53.1. No fresh AOT sample is recorded.

Next is item 22. No package publication.

## Item 22 partial checkpoint, 2026-11-11

Not a cost acceptance. Comma joins of two, three, or four simple sources with
`ORDER BY` and `sqlite_stat1` row counts are ordered from the smallest table.
Five sources stay in the written order. The four-table result matches pinned
SQLite 3.53.1. No fresh AOT sample is recorded.

Next is item 23. No package publication.

## Item 23 partial checkpoint, 2026-11-11

Not a cost acceptance. An `INNER JOIN` seeks the inner table when an `AND`-level
`ON` equality names the leading column of a non-partial index and both sides
share affinity and collation. `OR`, `LEFT JOIN`, and `NOT INDEXED` stay scans.
The probe matches pinned SQLite 3.53.1, including NULL keys and an extra `AND`.
No fresh AOT sample is recorded.

Next is item 24. No package publication.

## Item 24 partial checkpoint, 2026-11-11

Rejected. The join stays a nested loop, including the indexed inner probe,
so each outer row's matches stay in inner-table order. An unordered indexed
join and an unordered comma join match pinned SQLite 3.53.1. A hash join is
not introduced.

Next is item 25. No package publication.

## Item 25 partial checkpoint, 2026-11-11

Not a cost acceptance. An inner-join lookup keeps at most 1024 distinct
keys. When `sqlite_stat1` records more, the plan stays a scan. A runtime
build that passes the cap also scans. 1024 keys still seek. Both sizes
match pinned SQLite 3.53.1. No fresh AOT sample is recorded.

Next is item 26. No package publication.

## Item 26 partial checkpoint, 2026-11-11

Not a cost acceptance. An uncorrelated `EXISTS` over one ordinary table, with
no aggregate, window, `ORDER BY`, compound, or nested query, stops reading at
the first match. A second use of that table, a correlated predicate, and
`EXISTS (SELECT count(*))` keep the full load. The probe runs once on 4000
rows, the stopped read uses fewer pages than `count(*)`, and the correlated
rows match pinned SQLite 3.53.1. No fresh AOT sample is recorded.

Next is item 27. No package publication.

## Item 27 partial checkpoint, 2026-11-11

Not a cost acceptance. An uncorrelated scalar subquery is executed once and
reused for every outer row. A correlated `count(*)` still follows the outer
row and matches pinned SQLite 3.53.1. No fresh AOT sample is recorded.

Next is item 28. No package publication.

## Item 28 partial checkpoint, 2026-11-11

Rejected. A correlated scalar subquery is not rewritten as a join. It runs
for the current outer row, so three outer rows call the inner probe three
times. The plain values match pinned SQLite 3.53.1.

Next is item 29. No package publication.

## Item 29 partial checkpoint, 2026-11-11

Not a cost acceptance. A CTE referenced more than once, including the two
sides of `UNION ALL`, runs once. `NOT MATERIALIZED` runs once per use.
`MATERIALIZED` runs once and the outer `WHERE` filters afterward. A derived
table applies its `LIMIT` before the outer `WHERE`. Rows match pinned SQLite
3.53.1. No fresh AOT sample is recorded.

Next is item 30. No package publication.

## Item 30 partial checkpoint, 2026-11-11

Not a cost acceptance. When `ORDER BY` begins with the selected expressions,
`DISTINCT` compares a row with the previous output row. `GROUP BY` extends
the current group when the key matches and sorts the groups only if a new
key arrives before the previous one. NULL and duplicate rows match pinned
SQLite 3.53.1. No fresh AOT sample is recorded.

Next is item 31. No package publication.

## Item 31 partial checkpoint, 2026-11-11

Not a cost acceptance. `MIN` and `MAX` of an integer primary key with no
filter read one end of the primary tree. `WHERE`, a non-key column, and
`COUNT` keep the full read. Empty `MIN`/`MAX` is NULL and empty `COUNT` is
0. Rows match pinned SQLite 3.53.1. `MAX(id)` touches fewer pages than
`count(*)` on 4000 rows. No fresh AOT sample is recorded.

Next is item 32. No package publication.

## Item 32 partial checkpoint, 2026-11-11

Not a cost acceptance. `count`, `sum`, `avg`, `total`, `min`, and `max`
without `DISTINCT` or an internal `ORDER BY` keep a running value. A group
stores its rows when a bare column, `HAVING`, or window reads them.
`sum(probe(b))` calls the probe once per row. Results match pinned SQLite
3.53.1, including NULL and `group_concat`. No fresh AOT sample is recorded.

Next is item 33. No package publication.

## Item 33 partial checkpoint, 2026-11-11

Not a cost acceptance. A select item, `WHERE`, or `HAVING` that contains no
column, parameter, or function is replaced by the value of that expression.
`probe()+1` still calls the probe. `1+2`, `8/2`, `3*4`, and `WHERE 1=0`
match pinned SQLite 3.53.1. No fresh AOT sample is recorded.

Next is item 34. No package publication.

## Item 34 partial checkpoint, 2026-11-11

Not a cost acceptance. The direct single-table reader skips a scan when
`WHERE` is a false literal or an `AND` of numeric comparisons with an empty
range. `count(*)` of that filter is 0. `(a > 1 AND a < 1) OR id = 2` still
returns id 2. A function inside the filter is not skipped. Results match
pinned SQLite 3.53.1, and the skipped scan reads fewer pages than
`count(*)`. No fresh AOT sample is recorded.

Next is item 35. No package publication.

## Item 35 partial checkpoint, 2026-11-11

Not a cost acceptance. A derived query that stays as its own input replaces
an unused bare column with NULL. A function in the same select list stays,
so `probe(b)` still runs. The kept columns match pinned SQLite 3.53.1. No
fresh AOT sample is recorded.

Next is item 36. No package publication.

## Item 36 partial checkpoint, 2026-11-11

Not a cost acceptance. A direct `table-scan` or `index-tree-scan` with
`LIMIT` and no `WHERE`, `ORDER BY`, aggregate, window, or `DISTINCT` stops
after `OFFSET + LIMIT`. `WHERE id > 10 LIMIT 3` still returns the filtered
rows. Results match pinned SQLite 3.53.1, and `LIMIT 3` reads fewer pages
than `count(*)`. The btree scan remains an asynchronous loop. No fresh AOT
sample is recorded.

Next is item 37. No package publication.

## Item 37 partial checkpoint, 2026-11-11

Not a cost acceptance. Two identical uncorrelated scalar subqueries share
one result when the text has no user function and no non-deterministic
built-in. `SELECT probe(), probe()` calls the probe twice. Two subqueries
that call `probe()` also stay separate. Two `count(*)` subqueries of the
same table read fewer pages than counts of two different tables. The value
matches pinned SQLite 3.53.1. No fresh AOT sample is recorded.

Next is item 38. No package publication.

## Item 38 partial checkpoint, 2026-11-11

Not a cost acceptance. The existing caps stay: 32 constant `IN` probes and
four sources for join reordering. A list of 33 values does not use the
index, and its rows match pinned SQLite 3.53.1. Four comma-joined tables
with statistics start at the smallest table. Five stay in written order.
No fresh AOT sample is recorded.

Next is item 39. No package publication.

## Item 39 partial checkpoint, 2026-11-11

Not a cost acceptance. Planning sees the bound parameter. `WHERE a = ?`
chooses index `ia`, and the rows match `WHERE a = 2` on pinned SQLite
3.53.1. No fresh AOT sample is recorded.

Next is item 40. No package publication.

## Item 40 partial checkpoint, 2026-11-11

Not a cost acceptance. Each statement is planned from the catalog visible
at that moment. The plan is not stored. Before `ANALYZE`, `WHERE a = 1`
uses the index. After `ANALYZE` on the same connection, the next explain
is a table scan. The rows match pinned SQLite 3.53.1. No plan cache is
enabled. No fresh AOT sample is recorded.

Next is item 41. No package publication.

## Item 41 partial checkpoint, 2026-11-11

Not a cost acceptance. `diagnoseQuery` reports `secondary-index-lookup` for
an index equality, a `primary-key-extreme` decision for `MAX` of the
integer primary key, and `inner-join-search` for a plain inner join. A
join that calls a function still rejects before the callback. Item 3's
accepted manifests are unchanged. No fresh AOT sample is recorded.

Next is item 42. No package publication.

## Item 42 closeout, 2026-11-11

This closes the 42-item ledger. It is not a release acceptance, and
`COMPATIBILITY_MATRIX.md` is unchanged.

Accepted only in the scope already recorded:

- Item 3, opt-in diagnostics, on the archived local measurement.
- Item 5, bounded Top-K, for its tested scope.
- Item 8, early stop, only for an ordered `LIMIT`/`OFFSET` with no `WHERE`.

Implemented and checked against pinned SQLite 3.53.1, without a separated
AOT cost acceptance: items 6, 7, 9, 10, 11, 12, 13, 14, 15, 17, 19, 20, 21,
22, 23, 25, 26, 27, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, and 41.
Items 6 and 7 have archived AOT samples whose ranges overlap, so those
samples are not an acceptance. Items 9 through 15, 17, 19 through 23, 25
through 27, and 29 through 41 have no new cost-acceptance sample.

Rejected: item 16 (skip-scan and index intersection), item 18 (`sqlite_stat4`
stays unused), item 24 (no hash join), and item 28 (a correlated subquery
is not flattened).

Items 1, 2, and 4 stay at their earlier complete/initial-matrix notes.
No package is published.
