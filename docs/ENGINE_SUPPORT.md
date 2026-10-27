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

## Items 51–76

These additions are a tested subset. They do not close M9, and they do not
turn the M8 checkbox into a claim of complete SQLite.

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

## Remaining SQLite targets

These omissions remain project requirements or compatibility limits. They are
not implemented by closing a bounded engine milestone.

| Area | Remaining capability |
|---|---|
| Schema state | Atomic commit of two durable databases. Temp and attached images are connection-local and are not journaled on their own |
| PRAGMA state | Journal modes other than reading rollback/wal and rewriting the current mode. The auto-vacuum algorithm. Per-database cache, busy, and synchronous values |
| Planning | Native EXPLAIN bytecode, full native costing, join reorder outside 2–3 comma joins with ORDER BY and stat1, built STAT4 statistics, and covering reads of a star or a generated column |
| Collations | ICU and locale collations. REINDEX of a custom collation name has no separate oracle |
| Grammar and errors | DQS fallback stays off. Exact native error text is not claimed. Malformed UTF stays rejected |
| Table functions | General virtual-table modules; metadata PRAGMA sources have explicit join-order and hidden-argument limits |
| Windows | Bounded execution; callback-bearing WHERE filtering can be buffered before window output, and native planner/coroutine equivalence is not general |
| Extensions | `json_pretty`, correlated `json_each`, FTS5 multi-page leaves, porter/trigram/detail/tokendata/locale, and FTS3/FTS4 writes remain unimplemented. The verified JSON, FTS, and R-tree subset is in the compatibility matrix |
| Platforms and release | Browser storage, non-Linux execution, the full M9 benchmark matrix, and release qualification. Items 77–108 are open |

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
