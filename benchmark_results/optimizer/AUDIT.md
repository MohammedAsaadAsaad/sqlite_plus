# Execution/planning audit, initial milestone

This is an inventory, not acceptance of all roadmap optimizations.

| Area | Current implementation | Verified boundary / next gap |
| --- | --- | --- |
| Access | database.dart::_plan | rowid equality/range, secondary prefix/range and eligible partial/expression indexes; not full cost enumeration |
| Statistics | planner_statistics.dart::estimate | STAT1 average equality-prefix estimates and heuristic range reductions; no STAT4 distribution samples |
| Covering | database.dart::_coveredByIndex/_plannedRows | eligible ordinary covered columns avoid table lookups; broaden eligibility/costing separately |
| Join order | database.dart::_orderedJoinSources | 2–3 simple CROSS sources, ORDER BY, known counts; not a general join optimizer |
| Correlation | _orderCorrelatedTableFunctions | JSON table function dependency ordering preserves barriers |
| Sorting | database.dart::_evaluate | explicit non-DISTINCT LIMIT already retains K=limit+positive offset; finds worst by linear search on every candidate |
| Final ordering | same evaluator | sorts retained entries with sequence tie-breaking; DISTINCT and unsupported scalar-consumer cases preserve their path |
| Streaming | _QueryExecution, browse, relational/CTE paths | several bounded/streamed subsets exist; not all reads stop at LIMIT or avoid materialization |
| Recursive queue | relational.dart::_CteWorkQueue | CTE priority queue; distinct from ordinary ORDER BY top-K selection |
| Explain | QueryPlan/explain/explainQueryPlan | exposes existing access paths; not complete actual execution counters or rejected-plan reasons |

Initial targeted change replaces repeated worst-row O(K) search and removal
with an in-place max-heap for K>=32, built only when the retained set fills.
Small K, no LIMIT, DISTINCT, unsorted queries, and huge LIMIT over short inputs
keep their existing paths. Existing scalar projection eligibility/evaluation
order and sequence tie-breaking are retained. This improves selection CPU;
it does not reduce table reads or total input materialization. The old path was
already bounded in retained result count: no general O(N)-to-O(K) memory claim.

Cost instrumentation for this milestone is in the benchmark wrapper, not a new
per-row production diagnostics hook: storage reads/bytes, query wall time,
RSS/high-water RSS, optional custom-collation comparison counts and scalar visit/
projection traces. `explain_us` measures that API only, NOT isolated complete
planning time. Roadmap item 3 remains open for richer opt-in diagnostics.
