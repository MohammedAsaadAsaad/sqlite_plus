# SQLite compatibility matrix

Reference: **SQLite 3.53.1**, source ID
`2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`.
Exact compile options and fixture hashes are recorded in
`packages/sqlite_plus/test/fixtures/manifest.json`. Native SQLite is used only by
development reference tools. Production engine code is Pure Dart.

| Feature | Status | Verification / limits |
|---|---|---|
| Memory byte storage / format header | Implemented | Partial reads, isolation, 100-byte fields, signed metadata, page-size sentinel, stale size handling |
| Read-only paging / B-tree framing | Implemented for stable rollback-format copies | Bounds, cells/freeblocks, overlaps, four page types, page-one offset, cycles/separators |
| Table/index/overflow record reads | Verified fixture subset | 2,244 physical records, three encodings, 512/4096/65536-byte pages; malformed text rejected |
| Rowid point planning | Implemented | Separator descent, residual WHERE evaluation, corruption regressions and AOT microbenchmark |
| Secondary-index/range planning | Verified subset | Multi-column/expression equality prefixes and ranges, proved partial predicates, descending keys, rowid ranges and NULL/inclusive bounds; page-read regressions and AOT measurements |
| SELECT expressions | Verified subset | 726 original plus 1,236 M6 pinned differential cases; IN/BETWEEN/CASE/CAST/LIKE/ESCAPE/GLOB/bitwise and NULL/affinity behavior |
| Collations | BINARY/NOCASE/RTRIM | Declared/explicit propagation, ASCII NOCASE, SQL filtering/grouping/distinct/sorting and index constraints |
| Joins / derived sources | Verified subset | INNER/LEFT/RIGHT/FULL/CROSS/NATURAL, ON/USING, aliases and qualified wildcards |
| Subqueries / compounds / CTEs | Verified subset | Scalar/correlated/EXISTS/IN, UNION/ALL/INTERSECT/EXCEPT, ordinary/forward/recursive CTEs; recursion max 100,000 rows; recursive ORDER/LIMIT unsupported |
| Scalar / aggregate functions | Verified subset | Core/string/math/ROUND/variadic IF/IIF and aggregates; connection-local scalar/aggregate callbacks; DATE/TIME/DATETIME/JULIANDAY/UNIXEPOCH/STRFTIME/TIMEDIFF and dynamic defaults; broader edge cases remain |
| GROUP BY / HAVING | Verified subset | Expressions/ordinals/aliases, HAVING aliases, distinct aggregates, empty inputs and bare-column MIN/MAX selection in differential cases |
| Window functions | Verified bounded subset | Ranking, NTILE, LAG/LEAD, first/last/nth values, aggregate ROWS/GROUPS/RANGE frames/offsets, EXCLUDE, FILTER, named/inherited windows and NULLS FIRST/LAST; max 10,000 rows; grouped aggregates and HAVING feed windows |
| Schema creation / index maintenance | Verified subset | CREATE/DROP TABLE/INDEX/VIEW/TRIGGER, ADD/RENAME/DROP COLUMN and table rename, ordinary and WITHOUT ROWID B-trees, auto/secondary indexes, overflow; 390 SQLite cross-open/integrity snapshots per encoding (1,170 total across UTF-8/UTF-16le/UTF-16be) |
| Constraints | Verified subset | Defaults, NOT NULL/UNIQUE/CHECK, STRICT, AUTOINCREMENT, FK enable state/actions/deferral, OR IGNORE/REPLACE, partial/expression unique keys; evaluation errors are not ignored as constraints; broader edge-case conformance pending |
| Views / row triggers | Verified subset | Read views; BEFORE/AFTER INSERT/UPDATE/DELETE, UPDATE OF, WHEN, OLD/NEW, DML/SELECT/WITH bodies, WHEN subqueries, RAISE ABORT/FAIL/ROLLBACK/IGNORE, recursive_triggers state/1,000-depth bound, typed OLD/NEW and automatic rowid timing; INSTEAD OF INSERT/UPDATE/DELETE view triggers, zero direct change counts and RETURNING |
| DML | Verified subset | INSERT VALUES/multirow/DEFAULT VALUES/SELECT, UPDATE/DELETE, UPSERT target/DO NOTHING/DO UPDATE, RETURNING with owner RPC; expression/partial conflict targets; combined conflict policies and broader syntax pending |
| PRAGMAs | Verified subset | Header/table/index/FK metadata, integrity_check/quick_check/foreign_key_check, mutable foreign_keys/recursive_triggers/user_version/application_id; bounded to supported images/schema |
| Transactions / savepoints | Implemented for image writer | SQL snapshots, nested savepoints, deferred FK commit; pinned 14-step transaction sequence |
| Rollback journal | Conditional durable contract | PERSIST before-images, every-operation/torn-write crash tests, recovery injection; native byte-exact hot-journal recovery |
| WAL writes / checkpoint / recovery | Exclusive-owner subset | Both checksum endians, three native cross-open commits, native continuation, torn frames/pages and every-operation growth/shrink checkpoint recovery |
| Isolate ownership / file lease | Single-owner architecture | Serialized SendPort requests, client-owned transactions, loopback duplicate-owner guard, native SQLite lock-byte exclusion and handoff |
| ORM / generator | Placeholders, M7 pending | No behavior or tests yet |
| JSON/JSONB / FTS / R-tree / virtual tables | M8 pending | No implementation claim |
| Linux x64 | Development verified | Dart 3.13.7; 2,138 engine tests, format, fatal-info analysis and locked dependencies pass |
| Windows/macOS/Android/iOS/Web | Unverified, M9 pending | Core has no dart:io dependency; optional file/owner adapter does; no execution claim |

## Query and format limits

General SQLite conformance is not claimed. See README for the current grammar.
Unsupported SQL should fail explicitly. Query results are materialized and integer
values use BigInt to retain signed-64-bit precision. Malformed UTF text is
rejected rather than emulating native SQLite's permissive decoding. The default
record bound is 16 MiB. The parser limits SQL to 1 MiB and expression nesting to
128. Floating rendering/numeric coercion beyond the pinned cases is unverified.
Multiple MIN/MAX bare-column ambiguity and unspecified row ordering are not
portable guarantees. Window execution is materialized and is not a performance
claim. Index plans use safe equality prefixes/ranges and a constraint-count heuristic;
there is no statistics-driven cost model or SQLite EXPLAIN bytecode.

Read-only APIs require a stable rollback-format copy with no concurrent writer,
hot journal or pending WAL; they do not lock or recover the source. WAL headers
are rejected. A traversal/seek may yield rows before discovering later corruption;
unvisited seek branches are not validated. Raw BtreeRecord values are physical
records: rowid INTEGER PRIMARY KEY fields are NULL and the rowId is separate.
WITHOUT ROWID uses physical primary-key-first column order. Raw traversal provides no cross-tree/freelist integrity guarantee; the bounded
PRAGMA checks below use the validated image path. Media repair is not claimed.

## Writes and durability

The image writer checks B-tree/overflow ownership and freelist coverage before
reconstruction. Compact rebuilds maintain supported indexes and schema roots.
Complete non-auto-vacuum images without reserved page bytes are required, with a
64 MiB bound. Image mutation favors a simple atomic boundary over in-place
splits; write scaling and all native schema edge cases remain open. Unsupported schema syntax or constraints may reject access; expression/partial
indexes support the documented deterministic grammar and predicate proofs.
ALTER supports ADD/RENAME/DROP COLUMN and table renaming (dependent views/triggers rejected; explicit DROP rejects schema dependencies) and never silently performs destructive
migration. Schema/index comparisons are backed by native integrity_check for the
specified snapshots, not a universal conformance claim.

DurableStorageBackend requires distinct already durably provisioned main and
journal/WAL entries, durable ordered sync, and exclusive access. The optional
file adapter opens existing regular files; directoryEntryIsDurable is a caller
attestation, not a detected property. Automatic directory provisioning, mode
switching and physical power-loss filesystem certification are unsupported.
Failed commit/checkpoint I/O poisons the pager; reopen for recovery.

DatabaseOwner owns every file handle in one isolate. Logical clients share
SendPorts and receive busy errors during another client's transaction. A
canonical-path loopback-port lease excludes other owners before opening the
main descriptor; the port carries no SQL and collisions fail closed. An exclusive
SQLite lock-byte lease blocks external SQLite connections until close. Hard-link
aliases and extra direct descriptors are unsupported because POSIX locks are
process-scoped and descriptor closes can release them.

WAL appends full images and acknowledges after sync. Checkpoint syncs WAL,
copies/syncs main, then clears/syncs WAL; restart can replay a partial checkpoint.
Existing WAL-format main and durable sidecar entries are required. Existing
-shm or unresolved rollback journals are rejected rather than deleted. This
architecture excludes external concurrent readers/writers and does not implement
SQLite's shared wal-index. Raw pager users must provide equivalent ownership.
Multi-database atomic transactions and other journal modes remain unsupported.

## Remaining milestones / release gates

M6 is **open**: SQL/function/PRAGMA breadth, remaining UPSERT shapes, ALTER variants,
additional trigger/FK shapes, optimizer coverage and full differential
hardening remain. M7 ORM/generator, M8 extensions and M9 browser/platform/release
work have not passed their gates. Saved AOT benchmarks contain real raw samples
for small Linux memory workloads, not the required 1k/10k/100k/1m scale and
platform/ORM/native-engine comparison matrix. No release-ready or all-milestones
completion claim is made.

M6 completion audit still has concrete open items: view/trigger dependency rewrites and broader ALTER conformance; combined UPSERT conflict policies; additional trigger/FK interactions;
generated columns; remaining SQL/function/PRAGMA conformance and hardening.
These are not marked implemented by passing the expanded subset tests.
