# Engine support contract

The master specification is the planned SQLite target. This document defines
the engine baseline the ORM and extensions use now, and the follow-up that is
still planned.

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

## Items 51–76

These additions are part of the current baseline. The wider SQLite surface is
planned and listed below.

TEMP tables, indexes, views, and triggers belong to the connection. Reopen
does not see them. An unqualified name resolves temp, then main, then the one
attached database. `ATTACH ':memory:'` is core. A file path uses the optional
`attachFile` callback and must be at most 64 MiB. A second attachment, a
duplicate name, `main`, `temp`, a missing file, and a missing reader are
rejected. One statement that mutates two schemas is rejected before a partial
write. A cross-schema SELECT is copied into a scratch image. Temp and attached
images are not a second durable journal. A transaction snapshots main, temp,
and the attached image together.

`journal_mode` reads header byte 18. Writing the current mode changes nothing.
`memory`, `off`, `delete`, `persist`, `truncate`, and a rollback/wal switch
are rejected before the bytes change. A write-version 2 image is not opened
for a query. `cache_size` defaults to -2000, `busy_timeout` to 0, and
`synchronous` to 2. Those three values stay off the image. `auto_vacuum` reads
0, and a write is rejected. An image whose largest root page is not 0 fails
at open.

`createCollation` registers one connection-local text collation. The test
covers ORDER BY, UNIQUE, and an index on that collation. REINDEX of a custom
collation name has no separate oracle. EXPLAIN QUERY PLAN returns this
engine's `detail` text. EXPLAIN bytecode is rejected. Two or three comma joins
with ORDER BY and sqlite_stat1 counts can be reordered; the test compares
rows. A covering index skips the table when every referenced column is in the
index or is a rowid alias, and that read uses fewer pages. `sqlite_stat4`
fails closed at open. Double quotes remain identifiers.

The gap ledger has 25 UTF-8 cases from the pinned CLI. A case matches the CLI
or names the rejection. The recorded differences include DQS, `json_pretty`,
EXPLAIN bytecode, `journal_mode` memory/off, `auto_vacuum`, a cross-database
insert, the fresh `journal_mode` name, and EXPLAIN QUERY PLAN text. The CLI
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
existing writers. An auto-vacuum file is still rejected at open.

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

The repository root `LICENSE` is the MIT license. Every package version stays
`0.0.1-dev.1`. The three packages are prepared for pub.dev at this pre-release.
`CHANGELOG.md` records this version. The Linux CI job checks fixture checksums. macOS and Windows CI run
format, analysis, package tests, and the example projects.

On Linux x64, Dart 3.13.7, this revision passed format, fatal-info analysis,
10,496 engine tests, 169 ORM tests, and 53 generator tests. The pinned SQLite
CLI was present, so the native integrity tests ran. Each example project
passed its own test.

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
| PRAGMA state | More journal modes, the auto-vacuum algorithm, and per-database cache, busy, and synchronous values |
| Planning | Native EXPLAIN bytecode, fuller native costing, wider join reorder, built STAT4 statistics, and covering reads of a star or a generated column |
| Collations | ICU and locale collations, and a separate oracle for REINDEX of a custom collation name |
| Grammar and errors | A double-quoted-string compatibility mode, and closer native error text |
| Table functions | More virtual-table modules |
| Windows | Wider window execution and closer planner equivalence |
| Extensions | `json_pretty`, correlated `json_each`, FTS5 multi-page leaves, porter, trigram, detail, tokendata, locale, and FTS3/FTS4 writes |
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
