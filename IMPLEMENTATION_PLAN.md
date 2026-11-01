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
  Items 77–82 add an unpromised browser-storage subset: capability flags, a memory fallback, an in-process image round trip, a compiled `dart:js_interop` OPFS/IndexedDB file, and an ORM save/filter reopen. They do not check this box. Power loss is not promised.
  Items 83–90 record a reprinted Linux x64 gate, one Chrome page on Linux, and separate macOS, Windows, Android, and iOS rows. They do not check this box. Android was not run. iOS was not run. macOS CI passed for commit `e320528` in run 40494640309: 10490 engine tests with 6 skipped, 167 ORM tests, and 53 generator tests. Windows CI for that commit passed ORM (167) and the generator (53), and failed one engine test, `database_owner` tearDown `PathAccessException` errno 32, with 10489 passed, 1 failed, and 6 skipped. Windows CI for commit `7afaaba` in run 40538509306 passed: 10490 engine tests with 6 skipped, 169 ORM tests, and 53 generator tests. The stale-sidecar test passed. That run does not check this box, and it is not a result for later heads. Items 91–98 record `benchmark_results/scenarios_10k_linux_x64.json`: Linux x64 AOT, 10000 rows, three samples. 100000 and 1000000 were not run. That file does not check this box. Items 99–107 add generated JSON, FTS, and R-tree helpers and the release notes below. They do not check this box. Package READMEs, examples, and pub.dev metadata at `0.0.1-dev.1` are prepared and not published. That preparation does not check this box. Item 108 stays outside this checkbox.

## DB Browser readiness

A Flutter browser can list schema, page rows, edit cells, and run SQL only for files and statements this engine already opens. The items below are the engine gaps that block the same actions on an arbitrary official SQLite file. B1 and B2 passed their gates. B3–B5 are not done. M9 stays unchecked. Item 108 stays open. Each item needs its own pinned SQLite 3.53.1 comparison before it can be checked. Do not reduce the measured cost of the current read and write paths.

- [x] B1 Open the file. Read `auto_vacuum` pointer maps, open a database that contains `sqlite_stat4` without using those samples, recover a pending WAL and a hot journal on the read path, and accept write version 2 only after that recovery. Shrink the file when the freelist allows it. Share the SQLite lock protocol with another process. Gate: official images that include `auto_vacuum` or `sqlite_stat4` return the same rows as the pinned CLI.
- [x] B2 Page the grid. A browse `SELECT` must not materialize the whole table. Records larger than the current 16 MiB bound need the same success or the same explicit limit as the pinned CLI. Gate: a paged read matches the CLI window, and an unbounded read is not required for the grid.
- [ ] B3 Run the pasted statement. Native `EXPLAIN` bytecode, closer `EXPLAIN QUERY PLAN` text, `json_pretty`, correlated `json_each`, a double-quoted-string mode, ICU and locale collations, FTS3/FTS4 writes, FTS5 porter, trigram, detail, tokendata, locale, and multi-page leaves, `VACUUM INTO`, `journal_mode` switches, `auto_vacuum` writes, and one durable commit across two attached databases. Remaining DML syntax stays in this item. Gate: each recorded difference in the gap ledger becomes a match, or stays listed with the CLI result beside it. The box stays open while any part below is open.
  - [x] `json_pretty`. The gap-ledger case `json-pretty` matches pinned SQLite 3.53.1. NULL, empty containers, nested arrays and objects, duplicate keys, comments, escapes, a custom indent, a NULL indent, numeric and blob indents, and a NUL truncated indent match `/tmp/sqlite-build/sqlite3`. Malformed JSON is rejected. The engine's arity text is `Invalid arguments to json_pretty`; the CLI text is `wrong number of arguments`. JSON input stays capped at 1 MiB. Pretty output stays capped at 16 MiB. An indent byte `0xFF` is kept as a code unit. Storing that string was not compared.
  - [ ] Native `EXPLAIN` bytecode.
  - [ ] Closer `EXPLAIN QUERY PLAN` text. The gap-ledger case `explain-query-plan` still differs. The CLI text is stored beside it.
  - [x] Correlated `json_each` and `json_tree`. A column, a nested `json_each(j.value)`, and a scalar subquery are evaluated per row. Comma joins, `INNER JOIN`, `LEFT JOIN`, `docs RIGHT JOIN json_each`, and `FULL JOIN` match `/tmp/sqlite-build/sqlite3`. `generate_series` still rejects a non-constant argument.
  - [x] `json_each(docs.label) RIGHT JOIN docs` when the argument names the preserved table. The pinned CLI returns 0 rows, including a NULL label, an empty array, and malformed JSON that is not read. `json_tree`, `FULL JOIN`, `LEFT JOIN`, an unqualified `label`, and `main.docs.label` also return 0. `json_each(missing)` and `json_each(docs.nope)` still raise `No such column`. The CLI text is `no such column: missing` and `no such column: docs.nope`.
  - [x] A double-quoted-string mode. The connection flag defaults to off, so the gap-ledger case `dqs-fallback` stays rejected. The CLI result is `'missing'`. When the flag is on, an unresolved unqualified double-quoted identifier is a string. `db_browser_b3_dqs_test.dart` matches `/tmp/sqlite-build/sqlite3` for a missing name, its original spelling, an empty identifier, an escaped quote, a space, a keyword, a real column including a different case, concatenation, `count(*)`, `GROUP BY`, `typeof`, a `CHECK`, a scalar subquery, a column whose name contains a dot, and a keyword or spaced column name. Brackets, backticks, qualified names, and `INSERT` column lists stay identifiers. Turning the flag off restores `No such column: missing`. The engine says `Ambiguous column: title`. The CLI says `ambiguous column name: title`. A `CHECK` failure is `CHECK constraint failed`. The CLI appends the expression.
  - [x] Unquoted `a.title` when table `a` has columns `title` and `"a.title"`. The qualified name is column `title` (`bare`). `"a.title"` and `a."a.title"` are the dotted column. `main.a.title`, `SELECT *`, a join, and `title INT` plus one match `/tmp/sqlite-build/sqlite3`. Unquoted `a.title` when the only column is named `a.title` raises `No such column: a.title`. The CLI text is `no such column: a.title`.
  - [ ] ICU and locale collations.
  - [ ] FTS3/FTS4 writes.
  - [ ] FTS5 porter, trigram, detail, tokendata, locale, and multi-page leaves.
  - [ ] `VACUUM INTO`.
  - [ ] `journal_mode` switches. The gap-ledger cases `journal-mode-memory`, `journal-mode-off`, and `journal-mode-read` stay listed with the CLI result beside each one.
  - [ ] `auto_vacuum` writes. The gap-ledger case `auto-vacuum-full` stays rejected. The CLI result is an empty result.
  - [ ] One durable commit across two attached databases. The gap-ledger case `cross-insert` stays rejected. The CLI result is an empty result, and `aux.u` stays empty in this engine.
  - [ ] Remaining DML syntax.
- [ ] B4 Edit the schema. Finish the open schema edge cases and the `DROP` dependency checks so a table rebuild emitted by a structure dialog matches the pinned CLI `integrity_check`. Gate: those snapshots cross-open.
- [ ] B5 Leave plots and CSV import or export to the Flutter application. They do not change the engine.

Every milestone must include `dart format`, `dart analyze`, tests, documented discrepancies and a compatibility matrix update. ORM metadata can be developed in parallel after the engine API contract is stable.
