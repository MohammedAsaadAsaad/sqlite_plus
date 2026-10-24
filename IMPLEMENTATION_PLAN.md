# Milestones

- [x] M0: Repository skeleton, pure Dart memory storage interface and tests (verified on Dart 3.13.7/Linux x64).
- [x] M1: Pin SQLite version/configuration, test oracle, binary fixtures, page/header decoder and tests.
- [x] M2: Read-only pager and B-tree traversal; open SQLite-created files and compare records.
- [x] M3: Catalog, tokenizer, parser, single-table SELECT execution and differential tests (M3 subset; full semantics remain M6).
- [x] M4: Write pager, rowid B-tree mutation, INSERT/UPDATE/DELETE and rollback journal (simple unindexed tables; durability requires pre-provisioned storage contract).
- [x] M5: Transactions, savepoints, locking, WAL writes/checkpoints and recovery tests under a single exclusive owner isolate. External concurrent SQLite readers/shared wal-index mode and hard-link aliases are unsupported; see compatibility matrix.
- [ ] M6: Complete SQL semantics, indexes, planner, functions and PRAGMAs. Verified expansion: joins/subqueries/compounds/CTEs, expressions/collations/grouping, bounded windows, schema/index reconstruction, constraints/foreign keys/row triggers, secondary equality planning and metadata/header PRAGMAs. UPSERT/RETURNING and safe table renaming also verified. Broader SQL conformance, Grouped windows, connection-local scalar/aggregate functions, date/time/math/string functions, dynamic defaults, range/multi-column plans and integrity/FK PRAGMAs are also verified. Remaining column ALTER/dependency rewrites, partial/expression indexes, trigger shapes and broader SQL/function/PRAGMA conformance remain open.
- [ ] M7: ORM metadata, generator, DbContext, CRUD, change tracking and safe migrations.
- [ ] M8: Advanced extensions, JSON/JSONB, FTS, R-tree, virtual tables.
- [ ] M9: Browser adapters, platform matrix, AOT benchmarks, hardening and release gates.

Every milestone must include `dart format`, `dart analyze`, tests, documented discrepancies and a compatibility matrix update. ORM metadata can be developed in parallel after the engine API contract is stable.
