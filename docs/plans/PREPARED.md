# Prepared statements and ORM integration

| Step | Status |
| --- | --- |
| Baseline and contract | Complete |
| Reusable core syntax and connection-bound handles | Complete |
| ORM typed parameters, prepared reads/updates and optional bounded cache | Complete |
| Lifecycle/schema/native/rollback/Changes/Reactive regressions | Complete |
| AOT comparisons, documentation and CI | Complete |

Preserve preceding uncommitted work. Pure Dart, public package boundaries. No
publication/push/merge or schema migration. Existing APIs retain their paths;
ORM automatic query cache defaults to zero (explicit opt-in).

Core prepare supports ordinary single-schema SELECT and ordinary unqualified
DML targets. Reuse safe SELECT syntax and positional DML expression AST/token
programs. Do not cache result rows, bound values, mutable relational/subquery/
function AST, or parameter-dependent physical plans. Remaining validation and
binding-aware access planning still run; this is not SQLite bytecode. Complex
unsupported prepared SELECT shapes can keep using normal query.

Handles are connection-bound, single in-flight, explicitly closed; schema/search
scope changes and rollback invalidate preparation. Bindings copied per call.
No permanent prepared registry or default cache in the engine. Limit retained
SQL to 64Ki code units, expression memo entries 2048, cache capacity 0..128.

ORM explicit typed query/update preparation preserves context queue, codecs,
tracking/no-tracking, managed versions, dirty-state rejection and direct-write
transaction/refresh/observer pipeline. Optional cache reuses normal read-command
shapes. Adapter fallback is explicit via usesEnginePreparation=false, retaining
owner/RPC/Inspector/Changes behavior. Changes-backed prepared writes must NOT
bypass capture; use its existing execute path. Context close disposes resources.

Acceptance: positive/negative/boundary/native tests; schema alter/drop/rollback,
current data and bindings, BLOB copy, close/concurrency, callbacks, null and
named/gapped params, cache bounds, tracking/version/trigger/Changes/Reactive,
VM/JS examples. Full affected regressions and fresh AOT prepared vs unprepared
plus before/after ordinary workloads. Report actual benefits and limitations.

Implemented and validated locally. See `benchmark_results/prepared/README.md`
for the measured benefit, ordinary-path baseline comparison, and explicit limits.
No publication, push or merge performed in this task.
