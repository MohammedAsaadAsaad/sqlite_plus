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
| Transactions/savepoints | Implemented for the limited M4 writer | BEGIN/COMMIT/ROLLBACK, nested SAVEPOINT/RELEASE/ROLLBACK TO; 14-step pinned SQLite differential sequence; writes deferred until outer commit |
| Offline WAL recovery | Implemented for stable copied files | SQLite-generated WAL commits, every truncated final-frame tail, salts/checksums/resource limits; no live writer coordination |
| Exclusive file lease | Single-owner subset | SQLite lock-byte range blocks a separate SQLite process; same-isolate duplicate lease protection. POSIX cross-isolate/process-wide descriptor-close limitations remain |
| WAL writes/checkpoints | Implemented under exclusive ownership | Full-image WAL appends, both checksum endians, checkpoint ordering, growth/shrink, torn-write and every-operation crash recovery; native SQLite cross-open and write continuation |
| Isolate coordination | Implemented for clients sharing DatabaseOwner | One handle owner, serialized SendPort requests, client-owned transactions, cross-isolate owner exclusion via loopback guard; external SQLite blocked by lock-byte lease |
| SQLite image mutations | Implemented for simple unindexed rowid tables | INSERT/UPDATE/DELETE, bulk B-tree/overflow rebuilding, freelist reclamation; 8 mutation snapshots cross-open and pass pinned SQLite integrity_check/differential checks |
| Rollback journal | Implemented under explicit durable storage contract | SQLite-compatible full-page before-images, PERSIST invalidation, every-operation crash injection, recovery fault injection; pinned SQLite recovers Dart journal byte-for-byte |
| Durable file adapter | Conditional | Existing-file random writes/flush validated; caller must guarantee durable pre-provisioned entries and exclusive access. No power-loss filesystem certification |
| ORM and code generator | Placeholders | Analyzer passes; no behavior/tests yet |
| Linux x64 | Development checks verified | Dart 3.13.7; 852 engine tests, formatting and fatal-info analysis pass |
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
compatibility is asserted: functions, joins, grouped queries, DDL is not implemented; DML and transaction control use the separate limited mutable API. NULL logic, signed arithmetic limits,
integer/real comparisons, ASCII-insensitive names, quoted tokens, positional
parameters, rowid aliases, binary UTF ordering and blob numeric conversion are
covered by the pinned cases. Floating-point-to-text conversion beyond those
cases is not verified. Query results are materialized; no performance claims.

M4 provides an experimental MutableSqliteDatabase for existing images. It only
writes ordinary rowid tables without indexes, triggers, non-PK constraints,
auto-vacuum or reserved bytes. Unsupported targets fail before mutation.
TableImageWriter validates cross-tree ownership and freelists before reclaiming
pages. Rebuilding appends pages and reclaims old pages rather than optimizing
in-place splits; no write-performance claim. A default 64 MiB image bound applies.

RollbackJournalPager requires distinct DurableStorageBackend instances with
already durable directory entries, durable ordered sync and exclusive access.
DurableFileStorageBackend only opens existing regular files; its explicit
pre-provisioning attestation is a caller contract, not a detected property.
No automatic directory provisioning is offered. Crash-injection tests model
volatile versus synced data and restart recovery at each operation. Torn or
unrecognized journal headers fail closed. Filesystem power-loss, multi-process
locking, SQLite journal modes other than this single-header PERSIST subset,
live WAL writing, checkpoint coordination and cross-isolate ownership remain M5/unverified.

M5 uses a single exclusive owner, rather than SQLite's shared-memory concurrency
protocol. DatabaseOwner owns all file handles in one isolate and exposes
DatabaseClient SendPorts to other isolates. Transactions belong to their logical
client; other clients receive a busy error until it commits/rolls back. WAL
checkpoints are forbidden during active SQL transactions. A deterministic
loopback port lease excludes duplicate owners across isolates before any main
file descriptor is opened, avoiding POSIX's process-wide lock-release hazard.
The port serves no SQL; it is an ownership guard. Port collisions fail closed.
All clients must use the canonical path; hard-link aliases and direct extra
handles are unsupported. Shared external SQLite readers/writers are excluded for
the owner lifetime. Existing -shm files and unresolved rollback journals are
rejected, never silently removed. Provision files and durable directory entries
before opening; no automatic directory provisioning is claimed.

WalPager appends complete-image transactions and acknowledges after WAL sync.
Checkpoint syncs WAL before copying pages, syncs main before clearing WAL, and
can replay after a crash during the copy, including growth, shrinkage and torn
page writes. Failed I/O poisons the pager. Invalid WAL headers fail closed; this
is not a storage-media repair mechanism. Existing WAL-format databases are
required; automatic journal-mode switching is unsupported. All SQL writes still
have M4's unindexed/simple-rowid-table limitations. No physical power-loss,
shared-reader WAL, multi-database transaction or performance claim is made.
The pinned reference reads Dart WALs, appends native transactions, and verifies
checkpoint integrity. Linux x64 owner/process behavior is verified; other
platforms and arbitrary non-cooperating same-process handles remain unverified.
