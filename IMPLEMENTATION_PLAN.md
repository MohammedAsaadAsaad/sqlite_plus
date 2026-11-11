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
  reads, including parentheses, and contentful writes whose rebuilt segment
  passes the pinned `integrity_check`; R-tree rectangles and
  geopoly for the pinned polygons; ORM `search` and `Bounds.intersects`.
  Gate: 10,438 engine and 163 ORM tests, format, fatal-info analysis, and the
  pinned JSON and search checksums on Dart 3.13.7/Linux x64. Generator tests and
  native schema, journal, and WAL oracles were not re-run. This checkbox does
  not claim every FTS5 or FTS3/4 option, `json_pretty`, or any M9 platform.
- [ ] M9: Browser adapters, platform matrix, AOT benchmarks, hardening and release gates.
  Items 51–76, including one Linux page-write sample at 10,000 and 100,000 rows, stay outside this checkbox.
  Items 77–82 add an unpromised browser-storage subset: capability flags, a memory fallback, an in-process image round trip, a compiled `dart:js_interop` OPFS/IndexedDB file, and an ORM save/filter reopen. They do not check this box. Power loss is not promised.
  Items 83–90 record a reprinted Linux x64 gate, one Chrome page on Linux, and separate macOS, Windows, Android, and iOS rows. They do not check this box. Android was not run. iOS was not run. macOS CI passed for commit `e320528` in run 40494640309: 10490 engine tests with 6 skipped, 167 ORM tests, and 53 generator tests. Windows CI for that commit passed ORM (167) and the generator (53), and failed one engine test, `database_owner` tearDown `PathAccessException` errno 32, with 10489 passed, 1 failed, and 6 skipped. Windows CI for commit `7afaaba` in run 40538509306 passed: 10490 engine tests with 6 skipped, 169 ORM tests, and 53 generator tests. The stale-sidecar test passed. That run does not check this box, and it is not a result for later heads. Items 91–98 record `benchmark_results/scenarios_10k_linux_x64.json`: Linux x64 AOT, 10000 rows, three samples. 100000 and 1000000 were not run. That file does not check this box. Items 99–107 add generated JSON, FTS, and R-tree helpers and the release notes below. They do not check this box. Package READMEs, examples, and pub.dev metadata at `0.0.1-dev.1` are prepared and not published. That preparation does not check this box. Item 108 stays outside this checkbox.

## DB Browser readiness

A Flutter browser can list schema, page rows, edit cells, and run SQL only for files and statements this engine already opens. The items below are the engine gaps that block the same actions on an arbitrary official SQLite file. B1, B2, B3, and B4 passed their gates for the parts listed under them. B5 is not done. M9 stays unchecked. Item 108 stays open. Each item needs its own pinned SQLite 3.53.1 comparison before it can be checked. Do not reduce the measured cost of the current read and write paths. This is not a claim of full SQLite.

- [x] B1 Open the file. Read `auto_vacuum` pointer maps, open a database that contains `sqlite_stat4` without using those samples, recover a pending WAL and a hot journal on the read path, and accept write version 2 only after that recovery. Shrink the file when the freelist allows it. Share the SQLite lock protocol with another process. Gate: official images that include `auto_vacuum` or `sqlite_stat4` return the same rows as the pinned CLI.
- [x] B2 Page the grid. A browse `SELECT` must not materialize the whole table. Records larger than the current 16 MiB bound need the same success or the same explicit limit as the pinned CLI. Gate: a paged read matches the CLI window, and an unbounded read is not required for the grid.
- [x] B3 Run the pasted statement. Native `EXPLAIN` bytecode, closer `EXPLAIN QUERY PLAN` text, `json_pretty`, correlated `json_each`, a double-quoted-string mode, ICU and locale collations, FTS3/FTS4 writes, FTS5 porter, trigram, detail, tokendata, locale, and multi-page leaves, `VACUUM INTO`, `journal_mode` switches, `auto_vacuum` writes, and one durable commit across two attached databases. Remaining DML syntax stays in this item. Gate: each recorded difference in the gap ledger becomes a match, or stays listed with the CLI result beside it. The parts below are checked. Differences that remain are named inside those parts. This is not full SQLite.
  - [x] `json_pretty`. The gap-ledger case `json-pretty` matches pinned SQLite 3.53.1. NULL, empty containers, nested arrays and objects, duplicate keys, comments, escapes, a custom indent, a NULL indent, numeric and blob indents, and a NUL truncated indent match `/tmp/sqlite-build/sqlite3`. Malformed JSON is rejected. The engine's arity text is `Invalid arguments to json_pretty`; the CLI text is `wrong number of arguments`. JSON input stays capped at 1 MiB. Pretty output stays capped at 16 MiB. An indent byte `0xFF` is kept as a code unit. Storing that string was not compared.
  - [x] Native `EXPLAIN` bytecode for the gap-ledger statement `EXPLAIN SELECT 1`. A SELECT whose every result column is one literal opcode matches `/tmp/sqlite-build/sqlite3`, including the columns `addr`, `opcode`, `p1`, `p2`, `p3`, `p4`, `p5`, and `comment`. The compared shapes are an integer inside signed 32 bits, `Int64` outside that range through signed 64 bits, a hex literal, `NULL`, a string, `TRUE` and `FALSE`, a real including `Inf`, a blob, and several literal columns. Constant arithmetic and concatenation, a constant `WHERE`, one ordinary table scan, and one `INSERT` or `REPLACE` of constants match `/tmp/sqlite-build/sqlite3` in `db_browser_b3_explain_test.dart`. `EXPLAIN SELECT 1+1` is `Add` with the literal coded once. `EXPLAIN SELECT 1 WHERE 0` is `Goto`. `EXPLAIN SELECT 1 WHERE 0.0` is `IfNot`. `CREATE TABLE t(a); EXPLAIN SELECT a FROM t` is `OpenRead` on root 2 with `Transaction` p3 `1`. `EXPLAIN INSERT INTO t VALUES (1)` is `OpenWrite`, `NewRowid`, `MakeRecord`, and `Insert` p5 `57`. `EXPLAIN SELECT 1 FROM (SELECT 1)` is a coroutine whose unused inner column is `Null`. `EXPLAIN SELECT a FROM t` on `INTEGER PRIMARY KEY` is `Rowid` with `OpenRead` p4 `0`. `WITHOUT ROWID` opens cursor 1 with key info `k(1,)`, and `COLLATE binary` is `k(1,B)`. `SELECT *` from `b AS (a+1)` is `IfNullRow` then `Add`. `INSERT INTO t(a INT) VALUES (1)` puts `D` on `MakeRecord`. `INSERT INTO t VALUES (1),(2)` is `InitCoroutine`. Those rows match `/tmp/sqlite-build/sqlite3` in `db_browser_b3_explain_test.dart`. An `INTEGER PRIMARY KEY` insert, a join of two subqueries, and `EXPLAIN SELECT 1 WHERE NOT 0.0` still throw `EXPLAIN bytecode is not implemented`. `EXPLAIN SELECT title` is `no such column: title` on the CLI. This is not a VDBE.
  - [x] Closer `EXPLAIN QUERY PLAN` text. The gap-ledger case `explain-query-plan` matches `/tmp/sqlite-build/sqlite3`: `id=2`, `parent=0`, `notused=33`, `detail=SEARCH t USING INTEGER PRIMARY KEY (rowid=?)`. A full scan of the same table is `2,0,216,'SCAN t'`. `WHERE a>1` is `2,0,196,'SEARCH t USING INTEGER PRIMARY KEY (rowid>?)'`. `WHERE a>=1` uses the same cost and `rowid>?`. `WHERE a<1` and `WHERE a<=1` are `2,0,196,'SEARCH t USING INTEGER PRIMARY KEY (rowid<?)'`. `WHERE a>1 AND a<9` is `2,0,156,'SEARCH t USING INTEGER PRIMARY KEY (rowid>? AND rowid<?)'`. `EXPLAIN QUERY PLAN SELECT 1` is `1,0,0,'SCAN CONSTANT ROW'`. `EXPLAIN QUERY PLAN SELECT * FROM missing` is `no such table: missing`. A covering index on `(a, b)` for `SELECT a, b ... WHERE a=1` is `2,0,55,'SEARCH wide USING COVERING INDEX i (a=?)'`. The same predicate selecting `c` is `3,0,62,'SEARCH wide USING INDEX i (a=?)'`. `SELECT *` from an INTEGER PRIMARY KEY table through an index on the other column is `2,0,56,'SEARCH keyed USING COVERING INDEX ib (b=?)'`. That label does not change the read path. Multi-table addresses and stat1-adjusted costs were not compared. The compared `EXPLAIN` opcode rows are in the bytecode bullet above.
  - [x] Correlated `json_each` and `json_tree`. A column, a nested `json_each(j.value)`, and a scalar subquery are evaluated per row. Comma joins, `INNER JOIN`, `LEFT JOIN`, `docs RIGHT JOIN json_each`, and `FULL JOIN` match `/tmp/sqlite-build/sqlite3`. `generate_series` still rejects a non-constant argument.
  - [x] `json_each(docs.label) RIGHT JOIN docs` when the argument names the preserved table. The pinned CLI returns 0 rows, including a NULL label, an empty array, and malformed JSON that is not read. `json_tree`, `FULL JOIN`, `LEFT JOIN`, an unqualified `label`, and `main.docs.label` also return 0. `json_each(missing)` and `json_each(docs.nope)` still raise `No such column`. The CLI text is `no such column: missing` and `no such column: docs.nope`.
  - [x] A double-quoted-string mode. The connection flag defaults to off, so the gap-ledger case `dqs-fallback` stays rejected. The CLI result is `'missing'`. When the flag is on, an unresolved unqualified double-quoted identifier is a string. `db_browser_b3_dqs_test.dart` matches `/tmp/sqlite-build/sqlite3` for a missing name, its original spelling, an empty identifier, an escaped quote, a space, a keyword, a real column including a different case, concatenation, `count(*)`, `GROUP BY`, `typeof`, a `CHECK`, a scalar subquery, a column whose name contains a dot, and a keyword or spaced column name. Brackets, backticks, qualified names, and `INSERT` column lists stay identifiers. Turning the flag off restores `No such column: missing`. The engine says `Ambiguous column: title`. The CLI says `ambiguous column name: title`. A `CHECK` failure is `CHECK constraint failed`. The CLI appends the expression.
  - [x] Unquoted `a.title` when table `a` has columns `title` and `"a.title"`. The qualified name is column `title` (`bare`). `"a.title"` and `a."a.title"` are the dotted column. `main.a.title`, `SELECT *`, a join, and `title INT` plus one match `/tmp/sqlite-build/sqlite3`. Unquoted `a.title` when the only column is named `a.title` raises `No such column: a.title`. The CLI text is `no such column: a.title`.
  - [x] ICU and locale collations. The pinned CLI has no ICU library. `CREATE TABLE t(v TEXT COLLATE ICU)` and `'a'='A' COLLATE ICU` fail with `no such collation sequence: ICU`. `COLLATE en_US` fails with `no such collation sequence: en_US`. `COLLATE Icu` keeps that spelling. An empty name fails with `no such collation sequence:`. `SELECT 'a' COLLATE ICU` returns `a`. `PRAGMA collation_list` is `decimal`, `BINARY`, `NOCASE`, `RTRIM`, `uint`. `decimal` and `uint` comparisons, `ORDER BY`, and `GROUP BY` match `/tmp/sqlite-build/sqlite3`, including `'1.50'='1.5'`, `'1E-2'='0.01'` which is `0`, and `'a10'<'a2'` which is `0`. `BINARY`, `NOCASE`, and `RTRIM` still match. A duplicate `UNIQUE` spelling is rejected. The pin appends `: t.v` to `UNIQUE constraint failed`; this engine keeps its existing `UNIQUE constraint failed` text. Strings longer than 10,000,000 decimal digits were not compared.
  - [x] FTS3/FTS4 writes. `CREATE VIRTUAL TABLE` using `fts3` and `fts4` succeeds. `db_browser_b3_fts34_test.dart` matches `/tmp/sqlite-build/sqlite3`. FTS4 `MATCH 'hello'` returns `hello world`. FTS3 returns `hello`. An empty FTS4 insert leaves `count(*)` = 1. A `MATCH` delete leaves `count(*)` = 0. `CREATE VIRTUAL TABLE f USING fts4()` uses the column `content`. An image this engine writes has `integrity_check` `ok` on that CLI, and `MATCH 'hello'` returns the same row that CLI returns for a file it wrote. A native FTS4 file opens here. A later insert keeps `integrity_check` `ok`, and `MATCH` returns the original row and the new row. A damaged root leaf is `malformed inverted index for FTS4 table main.f` on that CLI. A crash during an FTS4 insert recovers the old image or the new image, and that CLI's `integrity_check` is `ok`. Contentless FTS4 matches that CLI: `content=''` stores no `f_content` table, `INSERT` of docid 7 and `hello world` returns rowid 7 for `MATCH 'hello'`, a second insert is visible, a missing term returns no row, and `integrity_check` is `unable to validate the inverted index for FTS4 table main.f: SQL logic error`. A scan without `MATCH`, a read of `body`, and `DELETE` are `SQL logic error`. An insert without a docid is `constraint failed`. A native contentless file opens here and a later insert is visible to `MATCH`. FTS3 `content=''` is a column named `content`, not a contentless table. An FTS5 insert still matches. This is one rebuilt segment. Byte-identical segment bytes were not compared.
  - [x] FTS5 porter, trigram, detail, tokendata, locale, and multi-page leaves. Porter `MATCH 'run'` returns `running`. Trigram `MATCH 'bcd'` returns `abcdef`, and `MATCH 'zz'` returns `0`. `detail=none` returns `hello`. `tokendata=1` and `locale=1` succeed, and a later `MATCH 'hello'` returns `hello`. A 2000-token `unicode61` insert returns the same `length(body)`. `db_browser_b3_fts5_test.dart` matches `/tmp/sqlite-build/sqlite3` for those rows and for `no such tokenizer: nope`, `no such tokenizer: simple`, `error in tokenizer constructor`, `malformed detail=... directive`, `malformed tokendata=... directive`, `malformed locale=... directive`, `fts5: phrase queries are not supported (detail!=full)`, `fts5: NEAR queries are not supported (detail!=full)`, and `fts5: column queries are not supported (detail=none)`. The `f_data` blocks for porter `running`, trigram `abcdef`, `detail=none` `hello`, `detail=columns` `hello`, `tokendata=1` `hello`, `locale=1` `hello`, and that 2000-token insert match the pin. Each exported image's `integrity_check` is `ok`. `detail=none` stores no token positions. A token shorter than 3 bytes or longer than 64 bytes is not stemmed.
  - [x] `VACUUM INTO`. `db_browser_b3_vacuum_into_test.dart` matches `/tmp/sqlite-build/sqlite3`. The statement writes a new file, `integrity_check` is `ok`, and the source rows stay. A second write is `output file already exists`. `VACUUM INTO NULL`, `VACUUM INTO 1`, `VACUUM INTO x'61'`, and an unbound `VACUUM INTO ?` are `non-text filename`. A missing directory and a directory path are `unable to open database:`. Inside a transaction the error is `cannot VACUUM from within a transaction`. `VACUUM main INTO` and `('dir/' || 'name')` write the file. An empty filename writes no file. A zero-length existing file is replaced. `VACUUM temp` and `VACUUM temp INTO` succeed and write no file. `VACUUM aux INTO` copies the attached rows. A crash after the temporary file is flushed and before rename leaves the destination absent. The temporary file's `integrity_check` is `ok`, and a retry writes the destination. Plain `VACUUM` still returns the rows. Page bytes of the output file were not compared.
  - [x] `journal_mode` switches. `db_browser_b3_journal_test.dart` matches `/tmp/sqlite-build/sqlite3`. On `:memory:`, `PRAGMA journal_mode` and assignments to `memory`, `off`, `delete`, `wal`, `persist`, `truncate`, `rollback`, and an unknown name all return `memory`. The image bytes stay. Header byte 18 is still 1, so a read-only open of that image still says `rollback`. On a file, the mode starts at `delete`, `journal_mode=off` stays `delete`, and `journal_mode=memory` returns `memory` while `v` stays `1`. Header bytes 18 and 19 stay 1, which is what the pin file shows after `journal_mode=memory`. `journal_mode=delete` returns `delete` and the row stays. File `wal` returns `wal`, header bytes 18 and 19 become 2, the change counter and the version-valid-for field each increase by 1, and no `-wal` file remains. The pinned CLI reads that file as `wal`, the row, and `integrity_check` `ok`. Inside a transaction the errors are `cannot change into wal mode from within a transaction` and `cannot change out of wal mode from within a transaction`. Leaving `wal` restores bytes 18 and 19 to 1. File `persist` returns `persist`. The next commit leaves a journal whose first 28 bytes are 0 and whose length is one 512-byte sector plus the changed pages. Header bytes 18 and 19 stay 1. The pinned CLI reads the new row and `integrity_check` `ok`. File `truncate` returns `truncate`, the journal length is 0, and the pinned CLI reads the new row. A hot official journal rolls the file back and is then removed. An invalidated header does not roll back. `temp.journal_mode` starts at `delete`, `off` stays `delete`, `memory` returns `memory`, `wal` stays `delete`, and `persist` and `truncate` switch. This commit path is not a multi-frame WAL log. Page order inside the persist journal was not compared with the pin.
  - [x] `auto_vacuum` writes. The gap-ledger case `auto-vacuum-full` matches. `PRAGMA auto_vacuum=FULL` is an empty result, then the same session reads `1`. `INCREMENTAL` reads `2`. `NONE` and `auto_vacuum=3` read `0`. `incremental_vacuum` adds no row in the recorded empty case. A fresh connection can turn auto-vacuum on until the first stored page image. An opened NONE file stays `0`. Once the mode is `1` or `2`, `NONE` does not turn it off, and `1` and `2` switch. `db_browser_b3_autovacuum_test.dart` matches `/tmp/sqlite-build/sqlite3` for those rows, for `page_count`, `freelist_count`, and `integrity_check` of the compared FULL, INCREMENTAL, and NONE images, and for the pointer-map bytes of the index and `zeroblob(5000)` images. A pointer-map type `9` is `*** in database main ***\nFailed to read ptrmap key=3`, and the row is still `1`. An incremental cookie with largest root `0` is `*** in database main ***\nincremental_vacuum enabled with a max rootpage of zero`, and the row is still `1`. A crash during the commit of an insert on a FULL image recovers either the old row or both rows, and `integrity_check` is `ok`. `incremental_vacuum` moves a live page off the end of the file and then truncates free pages. After `INCREMENTAL`, `zeroblob(5000)`, and `DELETE`, `page_count` is 4 and `freelist_count` is 1. `PRAGMA incremental_vacuum`, `(0)`, and `(-1)` then read 3 and 0. `incremental_vacuum(1)` after `zeroblob(20000)` and `DELETE` goes from 7 and 4 to 6 and 3. A native image whose free page sits in front of an overflow page moves that page, and `length(v)` stays 5000. A freelist count of 99 throws `FormatException`, and opening that image for writing is rejected. `db_browser_b3_autovacuum_test.dart` matches `/tmp/sqlite-build/sqlite3` for those rows. NONE reads still skip pointer maps. No AOT timing was run.
  - [x] One durable commit across two attached databases. The gap-ledger case `cross-insert` matches. `INSERT INTO aux.u SELECT v FROM t` is an empty result, then `aux.u` has `count(*)` = 1 and `v` = `m`, and main `t` still holds `m`. `db_browser_b3_cross_insert_test.dart` matches `/tmp/sqlite-build/sqlite3` for that script, for an empty source, for `''` and NULL, for the reverse insert, for `ROLLBACK`, and for reopening both files. The pin reads the reopened engine files as `1`, `m`, `m`, and `integrity_check` `ok`. A transaction that writes both files syncs one schema-commit record. A crash before that record leaves both files old. A crash after it restores both, and `integrity_check` is `ok`. That record is not an official SQLite master journal. `UPDATE aux.u SET v = (SELECT v FROM t)`, `UPDATE aux.u SET v = t.v FROM t`, and `DELETE FROM aux.u WHERE v IN (SELECT v FROM t)` match that CLI, including `changes()`. Without the attachment, `UPDATE aux.u SET v = 1` and `DELETE FROM aux.u` are `no such table: aux.u`. `UPDATE AUX.U SET v = 1` is `no such table: AUX.U`. A file commit of the update reopens both files. A crash between an update of one file and a delete of the other recovers both old or both new, and `integrity_check` is `ok`. `INSERT INTO aux.u VALUES ((SELECT v FROM t))` inserts `m`. `changes()` is 1 and `last_insert_rowid()` is that row. An empty subquery inserts NULL. Two scalar subqueries fill two columns. `ORDER BY` keeps the first row. `main.t` beside `aux.t` keeps both tables. `RETURNING`, two VALUES rows, a CTE, `ON CONFLICT DO UPDATE`, and the reverse insert match `/tmp/sqlite-build/sqlite3`. The copied table is dropped. A missing table is `no such table: missing`. Two subquery columns are `sub-select returns 2 columns - expected 1`. A short VALUES list is `table aux.u has 2 columns but 1 values were supplied`.
  - [x] Remaining DML syntax recorded by the gap ledger. The gap-ledger DML write `cross-insert` matches on its own line. `db_browser_b3_dml_test.dart` matches the pinned CLI for `INSERT DEFAULT VALUES`, `REPLACE`, `ON CONFLICT DO NOTHING`, `UPDATE ... RETURNING`, `DELETE ... RETURNING`, `SET v=v||'x'`, and `INSERT ... SELECT`. This is not a claim that every DML form was compared.
- [x] B4 Edit the schema. A structure-dialog rebuild creates the replacement table, copies the kept columns, drops the old table, renames the replacement, and recreates the index. `db_browser_b4_test.dart` matches `/tmp/sqlite-build/sqlite3` for `integrity_check`, the rows, and `sqlite_schema`. The engine image opens in that CLI. A CLI image built with `auto_vacuum=NONE` opens here, and a later insert still passes the CLI `integrity_check`. Renaming fails with `error in view v: no such table: main.t` when a view names a table that was dropped, and the bytes stay unchanged. The same script with a trigger is `error in trigger tr: no such table: main.t`. `DROP COLUMN` matches the pin for a primary key, a column `UNIQUE`, the last column, a secondary index, a table `UNIQUE`, a table `CHECK`, a generated column, a column-level foreign key, a table foreign key, an `INSERT` or `UPDATE` target the pin does not resolve, and an edit beside an FTS5 table. This is not every schema form.
- [ ] B5 Leave plots and CSV import or export to the Flutter application. They do not change the engine. `examples/notes` exports CSV, imports those rows as new notes, and plots one bar per UTC update day. `examples/notes/tool/note_exchange_check.dart` passed. This machine has no Flutter SDK, so the widgets were not executed. That does not check this box.

Every milestone must include `dart format`, `dart analyze`, tests, documented discrepancies and a compatibility matrix update. ORM metadata can be developed in parallel after the engine API contract is stable.

## sqlite_plus_search Phase 1

- [x] Repository integration inspection; see packages/sqlite_plus_search/doc/ARCHITECTURE.md.
- [ ] Search release acceptance. Core keyword/vector/hybrid, feedback and incremental
  indexing are implemented; real-model, large-scale physical persistence, real-device recovery and broader
  platform gates remain open. VM/Node search assertions now pass. See packages/sqlite_plus_search/doc/IMPLEMENTATION_PLAN.md.

## Changes package development milestone

- [x] Independent opt-in key/column change log; no engine/search runtime hooks.
- [x] Scoped producer transactions, savepoints, typed keys and named consumers.
- [x] Read budgets, retention/expiry and explicit generation rotation.
- [x] Native SQL/file comparisons, crash injection and VM/Node assertions.
- [x] Baseline AOT captured before package addition; paired disabled comparison.
- [x] Reduce temporary trigger-read reconstruction and repeat paired AOT checks.
- [x] User-approved development baseline and package README prepared.
- [ ] Enabled-write production gate: persisted/device and larger retained-log
  workloads remain unmeasured; see benchmark/OPTIMIZATION.md.
- [x] Atomic database-local consumer processing for Sync.
- [ ] Engine/ORM interception, shared search log and automatic age/size quotas. No existing application has been switched over.

See packages/sqlite_plus_changes/README.md and its benchmark/OPTIMIZATION.md. This does
not advance M9 or claim a production-ready changes engine.


## Sync development milestone 1

- [x] Plan bounded state-based client/server synchronization with explicit runOnce.
- [x] Add Changes scoped atomic consumption and origin-marker inspection.
- [x] Durable frozen outbox, monotonic server revisions, pull cursor and tombstones.
- [x] Default conflict rejection and explicit keepLocal/acceptRemote resolution.
- [x] Simulated storage-failure recovery and native SQLite/image comparisons.
- [x] Final VM/Node, package regressions, AOT size/cost evidence and README.
- [ ] Production server adapter/authentication, real-device/browser persistence,
  large-retained-log/scalability and automatic resnapshot/retention gates.

See packages/sqlite_plus_sync/IMPLEMENTATION_PLAN.md. Existing apps are unchanged;
no server is deployed and no package is published by this milestone.

## Reactive ORM milestone (2026-11-07)

- [x] Preserve original ORM AOT baseline and pre-feature runtime hashes.
- [x] Stateless Changes reads, optional post-commit/reset hints and serialized scopes;
  preserve durable consumers and stored feed format.
- [x] Lazy shared registry with dependencies, distinct/diff snapshots, coalescing,
  row budgets, error recovery and pause/cancel/owner-close lifecycle.
- [x] Native ORM watch/watchFirst/watchCount/watchAny; independent entities and
  optional same-engine Changes adapter for ORM/Sync source transactions.
- [x] VM tests, pinned native SQL comparison, generator regressions, simulated
  browser/file reopen checks, VM and Node assertion examples, documentation/CI.
- [x] AOT disabled/enabled comparison with raw data, hashes and reproducible driver.

Development implementation only; no publication. Timing evidence does not prove
zero regression: observed disabled 1000-row medians include +6.4% batch update and
+5.8% counts on a shared host. Strict no-regression approval remains open pending
controlled hardware measurement/optimization. Full limits and evidence:
`packages/sqlite_plus_reactive/README.md`, `benchmark_results/reactive/README.md`.

## Built-in pagination milestone (2026-11-07)

- [x] One shared core implementation; mutable/read-only `.page()` extensions.
- [x] ORM `.page()` with inferred keys, existing filter/codec/identity ownership.
- [x] Lexicographic forward/backward order, mixed directions and NULL placement.
- [x] Versioned typed cursors, scoped query fingerprint, BLOB/64-bit isolation.
- [x] Explicit validation of unsupported query windows/expression ordering.
- [x] Final core/ORM/generator regressions, native differential and platform checks.
- [x] AOT OFFSET/keyset evidence, README/examples/CI and compatibility log.

No separate package, data migration, implicit index or runtime interception.
See packages/sqlite_plus/doc/PAGINATION.md for scope and consistency limits.

## Main repository integration (PR #40)

- [x] Commit all completed workspace additions and preserve current main changes.
- [x] Resolve version/export/changelog conflicts; integrate file-owner pagination.
- [x] Validate core, ORM/add-ons, Search, generator, catalog and examples together.
- [x] Fix example manifests and reference-test platform scope from GitHub checks.
- [x] Preserve experimental status, benchmark evidence and open performance gates.

## Inspector development milestone (2026-11-07)

- [x] Independent optional package and explicit engine/read-only/file/ORM adapters;
  no changes to existing runtime sources or stored schema.
- [x] Bounded completion history, LRU groups, operation scopes, slow/error/row counts,
  default literal/bind redaction and opt-in bounded previews.
- [x] In-flight/active/depth/history limits with visible skip/eviction counters;
  original query results/errors and clear/disable/close lifecycle preserved.
- [x] Explicit main-image SELECT planning; no automatic diagnostic query replay.
- [x] Changes-driver/Reactive, ownership, file/browser, native plan and VM/Node checks.
- [x] Five-process AOT direct/disabled/enabled evidence, examples, docs and CI setup.

Experimental and unpublished. Only calls through supplied adapters are observed;
no UI/server, automatic engine-wide tracing, exact N+1 proof, CPU attribution,
RPC plan capability or real device/browser gate is claimed.

## Direct ORM writes milestone (2026-11-08)

- [x] Typed immediate partial UPDATE, bound numeric add/subtract, managed versions.
- [x] Explicit unique-target UPSERT and atomic, bounded-batch upsertMany.
- [x] Validate actual unique indexes/collations and duplicate inputs before writes.
- [x] Reject dirty contexts; refresh clean tracking after commit; preserve late edits.
- [x] Changes transaction-driver, Reactive invalidation and Inspector coverage.
- [x] Trigger final-state reads, rollback/commit uncertainty and poisoning tests.
- [x] Native UTF-8/UTF-16 comparisons; fix core built-in collation index ordering.
- [x] Full regressions, VM/Node example, AOT measurements, docs and CI definition.

Local, experimental and unpublished. No remote CI, release or no-overhead gate
is claimed. Existing corrupt UTF-16 collation indexes need explicit REINDEX after
backup; automatic migration is not performed. See ORM doc/DIRECT_WRITES.md.

## Optional full-copy branches milestone (2026-11-08)

- [x] Independent sqlite_plus_branch package; no existing engine/ORM runtime edits.
- [x] Immutable base and independent working image; stable branch/source identity.
- [x] Net row diff, field/row conflicts, explicit resolutions and stale approvals.
- [x] Atomic merge, final expected-state/FK checks and same-transaction receipt.
- [x] Portable checkpoints and two-slot IO store; explicit save/reopen/discard.
- [x] Corruption, interrupted storage, uncertain-commit and process-exit coverage.
- [x] ORM model-to-merge walkthrough with clear descriptor origins; VM/Node checks.
- [x] Pinned SQLite cross-open comparisons on UTF-8/UTF-16LE/UTF-16BE.
- [x] AOT phase/storage evidence, schema/resource limits and optional CI matrix.

First milestone only: complete image copies/scans, same-isolate exclusive source
loan, ordinary primary-keyed tables, no triggers/generated/virtual tables/schema
merges, implicit key remapping, shared pages, branch registry/rebase, receipt
pruning or Changes/Sync/Reactive transaction integration. Existing performance and
release gates remain; package is local, experimental and unpublished.

## Existing-package workflows milestone (2026-11-08)

- [x] Comprehensive scope/API/test plan: docs/plans/PREVIEW_IMPORT_DIAGNOSTICS.md.
- [x] Callback preview within Branch, reviewed-image acceptance and failure cleanup.
- [x] ORM input diagnostics, SQL-collation duplicates, empty policies and atomic apply.
- [x] Complete model/import/preview/accept example, including descriptor origins.
- [x] Explicit snapshot-only Inspector index experiments and native SQL comparison.
- [x] Separate opt-in Inspector capture/replay, bounded sensitive artifacts and
      outcomes/logical-state validation; ordinary records remain redacted.
- [x] Affected regressions, native encodings, VM/Node examples and CI definitions.
- [x] AOT source/binary fingerprints, raw runs, normal-write comparison/follow-up.

No new packages or core engine hooks. Import apply at 1000 rows remains expensive
(~13s on this workload); batch probes/SQL simplification did not fix it. This is
an explicit performance gate for production bulk use, not a fast-import claim.
Strict unused-feature zero-regression, actual browser/device and remote CI remain
unverified. Full scope, deferred features and evidence: the plan and
benchmark_results/workflows/README.md. Development only; no publication/merge.


## Import performance follow-up (local, 2026-11-08)

- [x] Profile the 13s apply bottleneck and preserve successful preparation.
- [x] SQL-equivalent statement-local conflicts, lazy slots, conservative FK/trigger/index fallbacks.
- [x] Full core/add-on regressions, pinned native boundaries, VM/JS examples.
- [x] Fresh-process AOT before/after, SKU/10k scope and ordinary operations.
- [x] Source/binary fingerprints, raw samples, documentation and targeted CI definitions.
- [ ] Strict zero-regression ordinary-update gate: follow-up +0.383ms/1000 statements.
- [ ] File-backed/device/large-scale acceptance; nonlinear 10k growth and peak RSS remain.

See docs/plans/IMPORT_PERFORMANCE.md and benchmark_results/import_performance/README.md.


## Embedded jobs milestone (2026-11-08, local)

- [x] Scope/contract/status: docs/plans/JOBS.md.
- [x] Opt-in storage, bounded JSON, transactional monotonic IDs and queue dedup.
- [x] Lease fences, expiry/recovery, fixed retry delay, cancellation/retry/prune.
- [x] Atomic application enqueue and result+ack; explicit runOne worker/example.
- [x] Functional/fault/native/file/VM+JS verification and existing add-on regression.
- [x] Reproducible AOT evidence, README, changelog/license and dedicated CI definition.
- [ ] Large/latency-sensitive production queue performance acceptance.
- [ ] Independent process/connection/isolate and ORM transaction-driver integration.
- [ ] Actual browser/device and remote CI; publication remains disabled.

Evidence: benchmark_results/jobs/README.md. Core runtime untouched by this package.


## Jobs processing performance follow-up

- [x] Preserve baseline sources/binaries and identify CPU costs.
- [x] Metadata-only claim selection, guarded rowid candidates and index-column reuse.
- [x] Repair stale equality-read cache without dropping append-order optimization.
- [x] Full core/add-on/search regressions, targeted pagination/native/fault and VM/JS checks.
- [x] Repeated AOT memory/file/depth/ordinary/import comparisons and reproducible source patches.
- [x] Update README/changelogs/compatibility/log and native CI cases.
- [ ] Physical-device file throughput, real browsers/devices and independent-owner acceptance.
- [ ] Release core fixes and raise Jobs dependency floor before independent publication.

See docs/plans/JOBS_PERFORMANCE.md and benchmark_results/jobs_performance/README.md.

- [x] Optional prepared statement syntax reuse and typed ORM parameters/updates.
  Connection-bound handles, schema invalidation and fresh binding-aware planning;
  opt-in bounded ORM read cache (default 0), adapter/capture fallback. See
  `docs/plans/PREPARED.md`, package preparation docs and
  `benchmark_results/prepared/README.md` for scope, validation and performance.


## Optimizer roadmap

- [x] Audit and freeze the current working-source baseline.
- [x] Initial AOT/result/IO/memory/callback regression matrix and native/VM/JS gates.
- [x] Bounded Top-K worst-row selection, tested scope and control costs documented.
- [ ] Rich opt-in runtime diagnostics and remaining optimizer extensions.
- [ ] Whole-roadmap acceptance and release/device validation.

Detailed 42-item status: docs/plans/OPTIMIZER.md. Initial evidence:
benchmark_results/optimizer/README.md. No global optimizer-completion claim.

## Optimizer continuation — 2026-11-11

- [x] Stable item3: explicit bounded diagnostics/plan decisions accepted for
  tested local scope and documented Inspector OFF control tradeoff. Final-source
  correctness, source/binary baselines, raw AOT controls and copy-reduction
  evidence: benchmark_results/optimizer_diagnostics/README.md.
- [ ] Stable item6: index-order reuse, after item3 checkpoint upload. Preserve
  stable 42-item IDs and per-item correctness/performance/cost gates.
- [ ] Remaining optimizer/release work: authoritative docs/plans/OPTIMIZER.md.

No automatic main merge/publication; docs/AI_HANDOFF.md is the continuation entry.
