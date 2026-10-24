# Milestones

- [x] M0: Repository skeleton, pure Dart memory storage interface and tests (verified on Dart 3.13.7/Linux x64).
- [x] M1: Pin SQLite version/configuration, test oracle, binary fixtures, page/header decoder and tests.
- [x] M2: Read-only pager and B-tree traversal; open SQLite-created files and compare records.
- [x] M3: Catalog, tokenizer, parser, single-table SELECT execution and differential tests (M3 subset; full semantics remain M6).
- [x] M4: Write pager, rowid B-tree mutation, INSERT/UPDATE/DELETE and rollback journal (simple unindexed tables; durability requires pre-provisioned storage contract).
- [x] M5: Transactions, savepoints, locking, WAL writes/checkpoints and recovery tests under a single exclusive owner isolate. External concurrent SQLite readers/shared wal-index mode and hard-link aliases are unsupported; see compatibility matrix.
- [ ] M6: Complete SQL semantics, indexes, planner, functions and PRAGMAs.
  Verified: joins/subqueries/compounds/CTEs; grouping and bounded windows;
  scalar/aggregate callbacks and date/time/math/string functions; indexed image
  writes, expression/partial indexes and range/equality plans; constraints/FKs;
  BEFORE/AFTER/INSTEAD OF triggers, recursion and RAISE policies; UPSERT/RETURNING;
  table/column ALTER with dependency guards; generated VIRTUAL/STORED columns;
  schema/statement conflict policies and REPLACE triggers; recursive CTE priority
  queues, LIMIT/OFFSET and duplicate suppression; VALUES queries/CTEs/subqueries/
  trigger bodies; CREATE TABLE AS and REPLACE shorthand; named parameter indices;
  metadata/integrity PRAGMAs.
  Open: dependent view/trigger rewrites and broader ALTER, SQL/function/PRAGMA,
  foreign-key/trigger interaction, planner and differential hardening audit.
- [ ] M7: ORM metadata, generator, DbContext, CRUD, change tracking and safe migrations.
- [ ] M8: Advanced extensions, JSON/JSONB, FTS, R-tree, virtual tables.
- [ ] M9: Browser adapters, platform matrix, AOT benchmarks, hardening and release gates.

Every milestone must include `dart format`, `dart analyze`, tests, documented discrepancies and a compatibility matrix update. ORM metadata can be developed in parallel after the engine API contract is stable.
