# Optimizer item 3 — explicit bounded diagnostics

Status: implementation contract, unaccepted. Base runtime: main 056e9644
(PR #43 merge), frozen in benchmark_results/optimizer_diagnostics/before_manifest.json.
Active branch/PR and continuation policy: docs/AI_HANDOFF.md, PR #44.

## Contract and boundary

- Add an explicit read-only engine diagnostic query returning its normal result
  plus immutable bounded plan decisions, estimates and actual-work metrics.
  Reuse the existing planner/evaluator: no second execution, rewritten predicates,
  changed choices, permanent registry or parameter/SQL capture in metadata JSON.
- Initial supported boundary: one ordinary/non-generated physical source or a
  constant SELECT, simple scalar filtering/projection/order/limit, optional
  DISTINCT. No CTE/join/derived/view/virtual/generated/aggregate/window diagnosis.
  Reject unsupported diagnosis before executing SQL callbacks. Normal SQL APIs
  keep existing coverage and paths.
- Plan trace: bounded retained candidates (0..256, default 64), clipped names,
  actual enumerated eligible/rejected candidates, chosen ordinal, existing
  rule/estimate/score rationale. Do not pretend skipped alternatives were costed
  or that STAT1 is a full model. Distinguish missing estimates from zero.
- Actuals: rows loaded into evaluator; rows visited by WHERE; rows passing WHERE
  before downstream LIMIT; returned rows; pager page-read delta. A large loaded
  input with only one visited row is possible because materialization remains.
- Exact counters absent from the initial path (index keys examined, projection/
  sort comparisons, bytes allocated) are explicitly unavailable/null, not zero.
- Timing: parse/support-validation time, actual _plan duration, source preparation
  including reads/metadata, materialization/evaluation time, total diagnostic
  operation. Do not label explain() or all source preparation as planning time.
- Metadata limits do not bound input/result rows or engine SQL allocations.
  No eager buffer proportional to LIMIT and no retained binding values.
- Pager deltas require exclusive use of that reader while diagnosing. Inspector's
  explicit mutable diagnostic operation loans the connection exclusively, routes
  its single schema (including temp shadowing), and creates a private reader; read-only API callers
  loan their reader exclusively. No normal-query global lock/hook is added.
- Inspector reuses existing explicit plan/collector facilities and the engine
  diagnostic operation;
  add explicit profile/diagnose runners, not automatic execution of every query.
  Generic/RPC wrappers without capability report unsupported; never bypass an
  adapter silently. Full ORM automatic report integration remains item 41.

## Disabled path and acceptance

No per-row diagnostic branch or observer is installed on normal evaluation.
Instrumented source/match iterables are selected once per explicit execution.
Plan candidate hooks are optional and only run on the planning path; measure
any disabled overhead rather than assuming it is zero.

Before acceptance: focused semantics/counters/bounds/NULL/collation/parameter/
error/callback/ownership tests, pinned native result comparisons, full core and
relevant add-on suites, VM/JS examples; sequential fresh-process AOT comparisons
of unchanged baseline vs new diagnostics-OFF, plus ON costs. Measure normal
point/scan/sort/ORM/write paths, enabled filter/source/page counters, trace-size
limits and process memory. Preserve raw results and investigate regressions.

Item remains unaccepted until final-source evidence passes. Update handoff/ledger
and upload immediately before moving to item 6. Every partial checkpoint states
unresolved work and next commands; source changes invalidate old checkpoint-only
hash assertions until a new measured checkpoint is established.

Mutable diagnosis must keep _exclusive through callbacks and route the actual
single schema. A main-only copy could silently misdiagnose temp shadowing or
allow a nested write that a normal query rejects. Core mutable diagnosis owns
this routing/lifetime boundary; Inspector delegates explicitly and reports the
outer snapshot overhead separately via its normal operation record. Read-only
report page counters assume an exclusively loaned reader. No callback sandbox
or control of arbitrary external user-function side effects is promised.
