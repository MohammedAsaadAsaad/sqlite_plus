# Milestones

- [x] M0: Repository skeleton, pure Dart memory storage interface and tests (verified on Dart 3.13.7/Linux x64).
- [x] M1: Pin SQLite version/configuration, test oracle, binary fixtures, page/header decoder and tests.
- [x] M2: Read-only pager and B-tree traversal; open SQLite-created files and compare records.
- [ ] M3: Catalog, tokenizer, parser, SELECT execution and differential tests.
- [ ] M4: Write pager, B-tree mutation, INSERT/UPDATE/DELETE, crash-safe rollback journal.
- [ ] M5: Transactions, savepoints, locking and WAL with recovery tests.
- [ ] M6: Complete SQL semantics, indexes, planner, functions and PRAGMAs.
- [ ] M7: ORM metadata, generator, DbContext, CRUD, change tracking and safe migrations.
- [ ] M8: Advanced extensions, JSON/JSONB, FTS, R-tree, virtual tables.
- [ ] M9: Browser adapters, platform matrix, AOT benchmarks, hardening and release gates.

Every milestone must include `dart format`, `dart analyze`, tests, documented discrepancies and a compatibility matrix update. ORM metadata can be developed in parallel after the engine API contract is stable.
