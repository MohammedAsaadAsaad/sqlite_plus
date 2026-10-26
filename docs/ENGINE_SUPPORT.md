# Engine support contract

The master specification describes the full project target. This document
defines the engine baseline consumed by the ORM and extensions. Passing its
verification gate does not establish complete SQLite 3.53.1 compatibility.

## Supported baseline

The engine executes the documented main-schema SQL grammar in Pure Dart. The
compatibility matrix records the tested expressions, joins, subqueries, CTEs,
aggregates, windows, schema operations, constraints, triggers, DML, indexes,
maintenance operations, functions and PRAGMAs. Unsupported syntax fails
explicitly. SQL INTEGER values use BigInt. Public query results are materialized;
internal row execution can resume between consumer writes.

INSERT SELECT streams eligible source expressions into the writer. Reads of
the target, target INSERT triggers and RETURNING introduce materialization
boundaries. Ordering, grouping, set operations, recursive queues and windows
can also require buffering. Physical relation records remain snapshot-loaded.
Ordinary/NOT MATERIALIZED relations can substitute expressions at references;
MATERIALIZED explicitly retains computed values. Unused CTE definitions do not
resolve function signatures or read their sources. Scalar/EXISTS evaluation
must preserve lazy preparation and the documented native regression cases.

VIRTUAL generated columns evaluate at read references; STORED generated columns
retain their persisted values. SQL pattern operators dispatch through their
connection-local functions. Numeric coercion uses SQLite's ASCII whitespace,
signed-integer prefixes and verified storage-class boundaries.

## Remaining SQLite targets

These omissions remain project requirements or compatibility limits. They are
not implemented by closing a bounded engine milestone.

| Area | Remaining capability |
|---|---|
| Schema state | TEMP/TEMPORARY tables and ATTACH/DETACH databases; cross-database atomic transactions |
| PRAGMA state | Controls outside the listed subset, including native journal-mode switching, cache/busy/synchronous and auto-vacuum configuration |
| Planning | Native EXPLAIN bytecode, full native costing, join reordering, STAT4 and covering-index equivalence |
| Collations | General custom-collation registration; current collations are BINARY/NOCASE/RTRIM |
| Grammar and errors | SQL beyond the documented grammar, DQS fallback, exact native error text and permissive malformed-text decoding |
| Table functions | General virtual-table modules; metadata PRAGMA sources have explicit join-order and hidden-argument limits |
| Windows | Bounded execution; callback-bearing WHERE filtering can be buffered before window output, and native planner/coroutine equivalence is not general |
| Extensions | JSON/JSONB, FTS, R-tree and applicable virtual-table behavior belong to M8 |
| Platforms and release | Browser storage, non-Linux execution, full-scale benchmark evidence and release qualification belong to M9 |

Binary extension loading and the native SQLite C ABI are outside the Pure Dart
runtime target. Existing durability and resource bounds remain in the
compatibility matrix: exclusive ownership, pre-provisioned durable entries,
bounded full-image writes, and no external concurrent SQLite/shared wal-index
mode. Browser-safe imports alone do not establish browser durability.

## Verification gate

Before committing an engine baseline, run locked dependency installation,
formatting, fatal-info analysis, package tests and every fixture checksum.
Compare SQL behavior with the pinned native source ID and compile options in
the fixture manifest. Cross-open exported images with native integrity checks;
retain mutation, dependency, metadata, journal and WAL recovery regressions.
Record exact results in DEVELOPMENT_LOG.md and keep the compatibility matrix
and README consistent with them. All production runtime execution remains
Pure Dart.
