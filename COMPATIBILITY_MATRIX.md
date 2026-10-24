# SQLite compatibility matrix

Reference: **SQLite 3.53.1**, source ID
`2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`.
Exact compile options, fixture SHA-256 hashes, record oracle hash and page
expectations are in `packages/sqlite_plus/test/fixtures/manifest.json`.
The pinned Python/SQLite oracle is development-only. M3 SELECT compatibility is limited to the grammar and differential cases below.

| Feature | Status | Verification |
|---|---|---|
| Pure Dart in-memory byte storage | Implemented | Original 5 storage tests pass |
| SQLite 100-byte database header | Implemented | Big-endian fields, signed cache size, page-size sentinel, format checks, stale size handling |
| Read-only pager | Implemented for stable rollback-format copies | Partial reads, exact reads, logical/physical size, bounds, isolated buffers, close lifecycle; WAL headers rejected |
| Pure Dart file adapter | Implemented for dart:io platforms | Read-only file mode, serialized concurrent reads, write/truncate rejection, fixture bytes unchanged |
| B-tree page framing | Implemented, limited scope | Four page types, page-one offset, cell/freeblock bounds, overlaps and reserved space |
| Table/index traversal | Implemented | Iterative in-order scan; table separator/rowid bounds; index interior records; repeated page/cycle detection |
| Overflow payloads | Implemented | Local/overflow split, usable-size limits, bounded allocations, exact chain lengths, cycles/out-of-range pages |
| Record decoding | Implemented for well-formed text | All integer serial widths, BigInt signed 64-bit values, doubles, NULL, copied blobs, UTF-8/UTF-16le/UTF-16be |
| SQLite-created file reads | Verified fixture subset | 2,244 physical records across three encodings/page sizes match pinned SQLite; includes schema, indexes and WITHOUT ROWID tables |
| Binary fixtures / development oracle | Implemented | 512/4096/65536-byte pages; 213 total pages including 131 overflow pages; checksums, integrity_check, deterministic regeneration |
| Catalog and SELECT subset | Implemented | 726 pinned SQLite differential cases: single table, projection, WHERE, DISTINCT, ORDER BY, LIMIT/OFFSET, positional bindings, arithmetic/comparison/NULL logic; catalog names and rowid aliases |
| Full SQL semantics | Not started (M6) | No joins, aggregates, subqueries, compound SELECTs, IN/LIKE, user functions or non-BINARY collations |
| Transactions, locking and recovery | Not started | No concurrent writers, hot journal recovery, WAL reader, or crash safety claims |
| SQLite file writes | Not started | No cross-open writes, pager mutation or complete integrity check |
| ORM and code generator | Placeholders | Analyzer passes; no behavior/tests yet |
| Linux x64 | Development checks verified | Dart 3.13.7; 808 engine tests, formatting and fatal-info analysis pass |
| Windows/macOS/Android/iOS/Web | Not verified | Core has no dart:io imports; optional adapter requires dart:io. Execution on these platforms remains untested |

M2 reads stable, nonempty SQLite 3 database copies with rollback-format headers.
Callers must ensure there is no hot journal, concurrent writer or pending WAL;
there is no file lock or recovery mechanism. Header WAL format is rejected even
if a WAL might already be checkpointed. Trailing physical pages beyond a valid
header size are not addressable; stale/zero size fields use physical page count.

Traversal returns physical records: rowid table INTEGER PRIMARY KEY aliases are
NULL in the stored record and must be read from `BtreeRecord.rowId`. Index and
WITHOUT ROWID records have no separate rowid, and use physical column order.
All integer values and rowids are BigInt to preserve 64-bit precision. Malformed
UTF text is rejected rather than emulating SQLite's permissive conversion rules.
The default per-record payload limit is 16 MiB and is configurable. A stream can
yield records before later corruption is discovered; consume it fully to validate
the visited tree. No complete database integrity, SQL collation ordering,
freelist validation or cross-tree page ownership claim is made. Crash recovery
is not applicable to these read-only operations. Runtime sources use Pure Dart;
native SQLite is used only to generate development fixtures.

M3 `SqliteDatabase.openReadOnly` reads catalog metadata and `query` supports the
single-table SELECT subset described in README. Catalog definitions with
unsupported constraints/collations fail when accessed. No general SQLite SQL
compatibility is asserted: functions, joins, grouped queries, DDL, DML and
transactions are not implemented. NULL logic, signed arithmetic limits,
integer/real comparisons, ASCII-insensitive names, quoted tokens, positional
parameters, rowid aliases, binary UTF ordering and blob numeric conversion are
covered by the pinned cases. Floating-point-to-text conversion beyond those
cases is not verified. Query results are materialized; no performance claims.
