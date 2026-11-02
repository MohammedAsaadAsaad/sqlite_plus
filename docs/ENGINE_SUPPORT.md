# Engine support contract

The master specification is the planned SQLite target. This document defines
the engine baseline the ORM and extensions use now, and the follow-up that is
still planned.

## Supported baseline

The engine executes the documented main-schema SQL grammar in Pure Dart. The
compatibility matrix records the tested expressions, joins, subqueries, CTEs,
aggregates, windows, schema operations, constraints, triggers, DML, indexes,
maintenance operations, functions and PRAGMAs. Unsupported syntax fails
explicitly. SQL INTEGER values use BigInt. Public `query` results are materialized.
`browse` materializes one single-table `LIMIT`/`OFFSET` window and does not
change `query`. Internal row execution can resume between consumer writes.

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

## Items 51–76

These additions are part of the current baseline. The wider SQLite surface is
planned and listed below.

TEMP tables, indexes, views, and triggers belong to the connection. Reopen
does not see them. An unqualified name resolves temp, then main, then the one
attached database. `ATTACH ':memory:'` is core. A file path uses the optional
`attachFile` callback and must be at most 64 MiB. A second attachment, a
duplicate name, `main`, `temp`, a missing file, and a missing reader are
rejected. `INSERT INTO aux.u SELECT v FROM t` returns no row, then `aux.u` has
one row `m` and main `t` still holds `m`. A file attachment can use its own
rollback journal. A transaction that changes two of those journals syncs one
schema-commit record first. A crash before that record leaves both files
unchanged, and a crash after it restores both. That record is not an official
SQLite master journal. `UPDATE aux.u SET v = (SELECT v FROM t)`, `UPDATE ... FROM`, and `DELETE FROM aux.u WHERE v IN (SELECT v FROM t)` match the pinned CLI, including `changes()`. A file commit reopens both files. A crash between an update and a delete recovers both old or both new. Without the attachment, `UPDATE aux.u SET v = 1` and `DELETE FROM aux.u` are `no such table: aux.u`. `UPDATE AUX.U SET v = 1` is `no such table: AUX.U`. `INSERT INTO aux.u VALUES ((SELECT v FROM t))` inserts `m`. `changes()` is 1 and `last_insert_rowid()` is that row. An empty subquery inserts NULL. `db_browser_b3_cross_insert_test.dart` matches the pinned CLI for that statement, two columns, the first ordered row, a same-named table, `RETURNING`, an upsert, two VALUES rows, a CTE, and the reverse insert. The copied table is dropped. A missing table is `no such table: missing`. Two subquery columns are `sub-select returns 2 columns - expected 1`. A short VALUES list is `table aux.u has 2 columns but 1 values were supplied`.
A cross-schema SELECT is copied into a scratch image. A memory attachment is
not a second durable journal. A transaction snapshots main, temp, and the
attached image together.

`journal_mode` reads header byte 18. Writing the current mode changes nothing.
`memory`, `off`, `delete`, `persist`, `truncate`, and a rollback/wal switch
are rejected before the bytes change. A read-only open accepts write version 2
when it matches the read version. `MutableSqliteDatabase.fromImage` still
rejects any other write version. `cache_size` defaults to -2000, `busy_timeout`
to 0, and `synchronous` to 2. Those three values stay off the image. A read-only
`PRAGMA auto_vacuum` is 0, 1, or 2 from the header. A writer still reads 0, a
write is rejected, and `fromImage` rejects a non-zero largest root page.

`createCollation` registers one connection-local text collation. The test
covers ORDER BY, UNIQUE, and an index on that collation. REINDEX of a custom
collation name has no separate oracle. EXPLAIN QUERY PLAN returns this
engine's `detail` text. `EXPLAIN SELECT 1`, constant arithmetic and concatenation, a constant `WHERE`, one ordinary table scan, and one constant `INSERT` or `REPLACE` match the pinned CLI opcode rows in `db_browser_b3_explain_test.dart`. A constant subquery, an `INTEGER PRIMARY KEY` scan, `WITHOUT ROWID`, a virtual generated column, a typed `INSERT`, and a multi-row `VALUES` insert match the pinned opcode rows in that file. An `INTEGER PRIMARY KEY` insert and a join of two subqueries still throw `EXPLAIN bytecode is not implemented`. This is not a VDBE. Two or three comma joins
with ORDER BY and sqlite_stat1 counts can be reordered; the test compares
rows. A covering index skips the table when every referenced column is in the
index or is a rowid alias, and that read uses fewer pages. `sqlite_stat4` opens
and its samples are not read. A stat1 plan and its query page-read count stayed
the same with an opposite stat4 sample. No wall-clock timing was run. Double
quotes remain identifiers unless `doubleQuotedStrings` is set. The default is
off. With the flag on, an unresolved unqualified double-quoted identifier is a
string and `db_browser_b3_dqs_test.dart` matches the pinned CLI. The engine
says `Ambiguous column: title`. The CLI says `ambiguous column name: title`.
Unquoted `a.title` beside a column named `a.title` returns the `title`
column. `"a.title"` returns the dotted column. Both match the pinned CLI.

The gap ledger has 25 UTF-8 cases from the pinned CLI. A case matches the CLI
or names the rejection. The recorded differences include the default-off DQS
case. `cross-insert`, `auto-vacuum-full`, the compared
`journal_mode` rows, and `explain-query-plan` match. `json_pretty`
matches the pinned CLI, including a custom indent. Its output cap is 16 MiB. The CLI
compiler is gcc-13.3.0. `manifest.json` still records clang-22.1.3. Stable
error codes are `constraint`, `syntax`, and `missingTable`. The wording is not
claimed to be SQLite's. Record decoding rejects UTF-8 byte 0xFF, an unpaired
UTF-16 surrogate, and an odd UTF-16 length.

A rowid insert that splits a page, a delete that empties a tree, and a
same-length overflow update pass the pinned CLI `integrity_check`. The file
does not shrink. Freed pages remain on the freelist and are reused, so a
delete followed by an insert of the same size keeps the page count. An update
that does not change an expression index or a partial index leaves those
index roots byte-identical. A key change uses the compact rebuild, and the new
key is visible through both indexes. Crash recovery for the incremental
insert, delete, and overflow update restores the previous rollback image. A
WAL commit of one row recovers that row after a crash on the next insert.
WITHOUT ROWID, views, triggers, and the other unhandled shapes keep their
existing writers. A valid auto-vacuum image opens for writing. NONE reads
skip pointer maps, and a NONE delete does not shrink. VACUUM does. Compared
FULL images match the pin's page counts. An incremental overflow delete
leaves the pin's freelist page. `incremental_vacuum` moves a live end page
onto that free page when it has to, then truncates. The compared
`zeroblob(5000)` delete is page_count 4 and freelist_count 1 until
`incremental_vacuum`, which reads 3 and 0.

`benchmark_results/page_writes_linux_x64.json` is this revision's Linux x64
AOT sample: three batch inserts of 10,000 rows, one batch insert of 100,000
rows, and 200 single-row inserts. No earlier binary was measured, so the file
is not a before/after delta. One hundred thousand single-row inserts were not
run.

## Items 77–82

These additions are a tested subset. They do not close M9.

`openBrowserStorage` looks up OPFS, then IndexedDB, through `dart:js_interop`.
The IndexedDB database is `sqlite_plus` version 1 and the object store is
`files`. The production packages do not depend on WASM or native SQLite. The
package SDK floor is 3.4.0 because that file uses `JSAny.isA`. On this Linux
VM the conditional import selects the stub, which returns null. `dart compile
js tool/browser_storage_compile.dart` compiles the web file. That compile-only
entry is not a browser run. The Chrome page is recorded under items 83–90.

`OpenedStorage.capabilities` is what the caller reads: `canRead`, `canWrite`,
`durabilityPromised`, and `placement`. Memory and browser placements both set
`durabilityPromised` to false. `requireWritable` rejects a read-only flag and
a browser flag that claims power-loss durability. A missing interface,
including the stub and a null probe, returns a new `MemoryStorageBackend`
with `StoragePlacement.memory`. A later open is empty. A probe that throws is
not turned into a successful open.

The round trip uses `MemoryBrowserByteStore`, an in-process map. Close, then
open, returns the saved row. Bytes stay local until `sync`, and the store
keeps its own copy. This is not OPFS and it is not a power-loss promise.
`BrowserStorageBackend` does not implement `DurableStorageBackend`, so it is
not passed to the rollback or WAL pager. `BrowserDatabaseConnection` uses the
public engine API only. The ORM test saves two notes, filters with
`where(MappedField.equalTo(...))`, closes, reopens, and filters again.

## Items 83–90

The Linux x64 gate was reprinted on Dart 3.13.7: 10,496 engine tests, 165 ORM
tests, and 48 generator tests. Format and fatal-info analysis passed. Those
counts belong to Linux x64. The later reprint is in items 99–107.

Chrome on this Linux host opened `openBrowserStorage`, saved two notes, and
filtered with `where(MappedField.equalTo('kept'))`. Close, then open, returned
`kept`. `placement` was `browser` and `durabilityPromised` was false. The page
text is `packages/sqlite_plus_orm/tool/chrome_orm_linux_x64.log`. Power-loss
durability is planned. The browser was Google Chrome 156.0.8078.47.

GitHub Actions runs format, analysis, package tests, and the example projects
on macOS and Windows. The recorded desktop pass is commit `7afaaba` in run
40538509306. A fresh desktop run is planned for each new revision. Android and
iOS are planned.

## Items 99–107

`@DbJson` on one String field emits `path(String path)`. An `fts5` model emits
`search(String text)` on its query extension. The created table lists the
content columns and keeps `rowid` as the key. An `rtree` model emits `bounds`
for `minX`, `maxX`, `minY`, and `maxY`, with the integer key first. FTS and
R-tree writes in this engine reject `RETURNING`, so a tracked save inserts or
updates and then reads the row. A second migration plan is empty when that
virtual SQL still matches.

The compiled consumer imports `sqlite_plus_orm` and the generated model. It
does not import `sqlite_plus` and its source has no SQL text. It saves six
rows, reads the JSON note whose title is `kept`, the FTS article matching
`kept`, and the R-tree place inside the unit box. `example/lib/models.dart` passes
generator `--check`.

The repository root `LICENSE` is the MIT license. `sqlite_plus` and
`sqlite_plus_orm` are `0.1.3`. `sqlite_plus_generator` is `0.1.4`.
`CHANGELOG.md` records those versions. The pub.dev API lists
`sqlite_plus_generator` `0.1.4` as latest, and `sqlite_plus` and
`sqlite_plus_orm` remain `0.1.3`. A package page can take up to 10 minutes to
show the new version. The Linux CI job checks fixture checksums. macOS and Windows CI run
format, analysis, package tests, and the example projects.

On Linux x64, Dart 3.13.7, the engine suite passed 10596 tests, the ORM suite
passed 185 tests, and the generator suite passed 58 tests. Format and
fatal-info analysis passed for those package runs. The pinned SQLite CLI was
present for the engine run. The example projects were not re-run for `0.1.3`.

Items 91–98 are `benchmark_results/scenarios_10k_linux_x64.json`: Linux x64
AOT, 10000 rows, three samples. Memory SQL insert microseconds are
`[2601012,2518356,2478439]`. Memory ORM save microseconds are
`[2934430751,3092578591,2700874993]`. File SQL insert microseconds are
`[1941990,1996109,2015981]`. Peak RSS is `220463104`. Benchmarks at 100000 and
1000000 rows are planned.

## Planned

| Area | Planned follow-up |
|---|---|
| Schema state | Atomic commit of two durable databases, with temp and attached images included in that plan |
| PRAGMA state | File `journal_mode=wal`, `persist`, and `truncate` match the compared rows. A multi-frame WAL log is not written. Per-database cache, busy, and synchronous values stay connection-local |
| Planning | EXPLAIN bytecode for an `INTEGER PRIMARY KEY` insert and a join of two subqueries; fuller native costing, wider join reorder, built STAT4 statistics, and covering reads of a star or a generated column. A constant subquery, an integer-primary-key scan, `WITHOUT ROWID`, a virtual generated column, a typed `INSERT`, and a multi-row `VALUES` insert match the pinned opcode rows |
| Collations | ICU and locale collations. The pinned CLI says `no such collation sequence: ICU` and `no such collation sequence: en_US`. This engine says `Unknown collation` or `No such collation: ICU`. `decimal` and `uint` are on the pin's collation list and are not implemented. REINDEX of a custom collation still has no separate oracle |
| Grammar and errors | Closer native error text. Opt-in double-quoted strings match the pinned CLI in `db_browser_b3_dqs_test.dart`. The default stays off. Unquoted `a.title` beside a column named `a.title` returns the `title` column |
| Table functions | More virtual-table modules |
| Windows | Wider window execution and closer planner equivalence |
| Extensions | Contentless FTS4 `content=''` matches the pinned `MATCH` rows and integrity text. FTS3 `content=''` is a column named `content`. Contentful FTS3/FTS4 writes pass the pinned `integrity_check`. `json_each(docs.label) RIGHT JOIN docs` returns 0 rows, matching the pinned CLI |
| Platforms and release | Benchmarks at 100000 and 1000000 rows, a fresh desktop run for each new revision, Android, iOS, power-loss durability, and publication when requested. The current 10000-row file is `benchmark_results/scenarios_10k_linux_x64.json`. The recorded desktop pass is commit `7afaaba` in run 40538509306 |

The production runtime stays Pure Dart. The planned browser work is a durable
store behind the same `canRead`, `canWrite`, `durabilityPromised`, and
`placement` flags. The current round trip is `MemoryBrowserByteStore` plus the
compiled `dart:js_interop` file, and the Chrome page on Linux is recorded in
`packages/sqlite_plus_orm/tool/chrome_orm_linux_x64.log`.

## Verification gate

Before committing an engine baseline, run locked dependency installation,
formatting, fatal-info analysis, package tests and every fixture checksum.
Compare SQL behavior with the pinned native source ID and compile options in
the fixture manifest. Cross-open exported images with native integrity checks;
retain mutation, dependency, metadata, journal and WAL recovery regressions.
Record exact results in DEVELOPMENT_LOG.md and keep the compatibility matrix
and README consistent with them. All production runtime execution remains
Pure Dart.
