# sqlite_plus master specification

## Mission

Implement a SQLite3-compatible relational engine **entirely in Dart** with optional Entity Framework-style ORM. Compatible with Dart and Flutter on native platforms, and browser targets where platform adapters can provide required semantics.

## Non-negotiable requirements

- No runtime `dart:ffi`, native SQLite, WASM SQLite, platform channels, C/C++ or Rust engine components.
- Pin a reference SQLite release and compile-time options before asserting compatibility.
- SQLite database file format, SQL parser/planner/executor, affinity and NULL semantics, indexes, B-trees, rollback journal, WAL, transactions, savepoints, triggers, views, foreign keys, PRAGMAs, JSON/JSONB, FTS, R-tree, and relevant virtual-table behavior are targets, **not implemented claims**.
- In-memory databases, durable file-backed databases, and browser-backed databases through separate capability-aware backends.
- ORM: convention-first Dart classes, optional annotations, generated metadata, DbContext, typed query expressions, relationships, snapshot change tracking, safe automatic schema changes, and explicit approval for ambiguous/destructive changes.
- Tests: unit, integration, differential SQL, cross-open SQLite file compatibility, fuzz, corruption, crash recovery, concurrency, cross-platform, and reproducible AOT benchmarks.
- Benchmark raw SQL versus ORM, file versus memory, cold versus warm cache, and workloads of 1k/10k/100k/1m rows. Report wall time, throughput, peak memory, database size, and repeated-run variation.
- Preserve honest per-feature status; do not promise complete compatibility until verified.

## Engineering architecture

`StorageBackend` -> pager -> B-tree -> record codec -> catalog -> SQL parser -> planner -> execution -> public API. ORM and generator consume the public API and stable metadata interfaces, never private storage internals.

## Definition of done

Each claimed feature must have passing tests, relevant differential verification, and documented platform guarantees. SQLite binary extensions and C ABI are out of scope for a Pure Dart runtime.
