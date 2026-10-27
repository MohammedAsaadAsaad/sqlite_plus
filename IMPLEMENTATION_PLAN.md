# Milestones

- [x] M0: Repository skeleton, pure Dart memory storage interface and tests (verified on Dart 3.13.7/Linux x64).
- [x] M1: Pin SQLite version/configuration, test oracle, binary fixtures, page/header decoder and tests.
- [x] M2: Read-only pager and B-tree traversal; open SQLite-created files and compare records.
- [x] M3: Catalog, tokenizer, parser, single-table SELECT execution and differential tests (M3 subset; full semantics remain M6).
- [x] M4: Write pager, rowid B-tree mutation, INSERT/UPDATE/DELETE and rollback journal (simple unindexed tables; durability requires pre-provisioned storage contract).
- [x] M5: Transactions, savepoints, locking, WAL writes/checkpoints and recovery tests under a single exclusive owner isolate. External concurrent SQLite readers/shared wal-index mode and hard-link aliases are unsupported; see compatibility matrix.
- [x] M6: Main-schema SQL execution, indexes, planner, functions and PRAGMAs for the verified engine baseline. Full SQLite conformance remains a target; see `docs/ENGINE_SUPPORT.md` and the compatibility matrix.
  Verified: joins/subqueries/compounds/CTEs; grouping and bounded windows;
  scalar/aggregate callbacks and date/time/math/string functions; indexed image
  writes, expression/partial indexes and range/equality plans; constraints/FKs;
  BEFORE/AFTER/INSTEAD OF triggers, recursion and RAISE policies; UPSERT/RETURNING;
  table/column ALTER with dependency guards; generated VIRTUAL/STORED columns;
  schema/statement conflict policies and REPLACE triggers; recursive CTE priority
  queues, LIMIT/OFFSET and duplicate suppression; VALUES queries/CTEs/subqueries/
  trigger bodies; CREATE TABLE AS and REPLACE shorthand; named parameter indices;
  aggregate ORDER BY/STRING_AGG; resolved table-reference rewrites in dependent
  views/triggers; metadata-only dependent column rewrites/validation, including
  unused named windows; NATURAL/USING merged-column dependency validation,
  join affinity/collation and compound ordering; row values and wildcard-width
  preparation; DML subqueries/CTEs and UPDATE FROM; FK actions invoking row
  triggers; constraint collation/direction metadata; main qualification/index
  hints; core/PRINTF Unicode functions; recursive view metadata/introspection;
  ANALYZE/stat1, REINDEX and VACUUM main; MEDIAN/PERCENTILE aggregate/windows;
  connection counters and trigger/FK save/restore; metadata/integrity PRAGMAs;
  parenthesized join scopes/metadata, UPDATE FROM dependency rewrites, deferred
  views and default-evaluation order, scalar-subquery types/affinity, STAT1 index
  ranking, boolean-name binding, IN table and qualified state PRAGMAs; numeric
  separators/postfix NULL syntax and row-valued UPDATE/UPSERT assignments;
  streaming INSERT SELECT, native single/multi-row VALUES/default evaluation;
  ordinary/NOT MATERIALIZED relation substitution and explicit materialization;
  scalar/EXISTS short-circuiting and uncorrelated caching; table-valued metadata
  PRAGMAs and dependencies; aggregate/window input scheduling; lazy VIRTUAL
  generated reads; registered pattern-function dispatch; stored view/trigger/
  default signature preparation; ASCII/NUL numeric coercion and signed64 affinity.
  Gate: 9,632 tests, all-package format/fatal-info analysis, 23 fixture checksum
  tools and pinned native schema/storage/SQL comparisons pass on Dart 3.13.7/Linux.
  At the M6 gate, TEMP/ATTACH, unlisted PRAGMA state, and broader native
  planner/collation/SQL compatibility stayed open. Items 51–76 later record a
  tested subset in the compatibility matrix. This checkbox does not claim
  complete SQLite support.
- [x] M7: ORM metadata/codecs, resolved convention/annotation generator, typed queries, DbContext/CRUD, snapshot tracking, explicit relationships and safe migrations (155 ORM and 48 generator tests; native cross-open/query/migration gates and JavaScript memory smoke verified).
- [x] M8: Advanced extensions for the verified JSON, virtual-table, FTS, and R-tree subset.
  Verified: connection-local virtual tables and `generate_series`; JSON/JSONB
  scalars, aggregates, and constant `json_each`/`json_tree`; FTS5 unicode61/ascii
  read and write, including `MATCH`, rank, highlight/snippet, prefix indexes,
  content modes, and external content that needs an explicit rebuild; FTS3/FTS4
  reads, including parentheses, with writes rejected; R-tree rectangles and
  geopoly for the pinned polygons; ORM `search` and `Bounds.intersects`.
  Gate: 10,438 engine and 163 ORM tests, format, fatal-info analysis, and the
  pinned JSON and search checksums on Dart 3.13.7/Linux x64. Generator tests and
  native schema, journal, and WAL oracles were not re-run. This checkbox does
  not claim complete FTS5, FTS3/4 writes, `json_pretty`, or any M9 platform.
- [ ] M9: Browser adapters, platform matrix, AOT benchmarks, hardening and release gates.
  Items 51–76, including one Linux page-write sample at 10,000 and 100,000 rows, stay outside this checkbox.

Every milestone must include `dart format`, `dart analyze`, tests, documented discrepancies and a compatibility matrix update. ORM metadata can be developed in parallel after the engine API contract is stable.
