# SQLite compatibility matrix

Reference: **SQLite 3.53.1**, source ID
`2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`.
Exact compile options and fixture hashes are recorded in
`packages/sqlite_plus/test/fixtures/manifest.json`. Native SQLite is used only by
development reference tools. Production engine code is Pure Dart.

| Feature | Status | Verification / limits |
|---|---|---|
| Memory byte storage / format header | Implemented | Partial reads, isolation, 100-byte fields, signed metadata, page-size sentinel, stale size handling |
| Read-only paging / B-tree framing | Implemented for stable rollback-format copies | Bounds, cells/freeblocks, overlaps, four page types, page-one offset, cycles/separators; empty interiors allowed only on page one |
| Table/index/overflow record reads | Verified fixture subset | 2,244 physical records, three encodings, 512/4096/65536-byte pages; malformed text rejected |
| Rowid point planning | Implemented | Separator descent, residual WHERE evaluation, corruption regressions and AOT microbenchmark |
| Secondary-index/range planning | Verified subset | Multi-column/expression equality prefixes and ranges, proved partial predicates, descending keys, rowid ranges and NULL/inclusive bounds; page-read regressions and AOT measurements |
| SELECT expressions | Verified subset | 726 original plus 1,872 M6 pinned differential cases plus 1,298 row-value cases; IN/BETWEEN/CASE/CAST/LIKE/ESCAPE/GLOB/bitwise, VALUES rows/compounds/CTEs/subqueries; named/numbered/anonymous parameter indices and NULL/affinity behavior |
| Collations | BINARY/NOCASE/RTRIM | Declared/explicit propagation, ASCII NOCASE, SQL filtering/grouping/distinct/sorting and index constraints |
| Joins / derived sources | Verified subset | INNER/LEFT/RIGHT/FULL/CROSS/NATURAL, parenthesized joined units, ON/USING, ON output aliases/forward INNER references, aliases and qualified wildcards; 4,080 grouped query and 1,224 grouped metadata comparisons; merged-column affinity/collation and real-column precedence over implicit rowid aliases |
| Subqueries / compounds / CTEs | Verified subset | Scalar/correlated/EXISTS/IN, UNION/ALL/INTERSECT/EXCEPT, ordinary/forward/recursive CTEs; max 100,000 queued rows; stable priority ORDER BY, LIMIT/OFFSET and UNION duplicate suppression |
| Scalar / aggregate functions | Verified subset | Core/string/math/ROUND/variadic IF/IIF, PRINTF/FORMAT, UNISTR and aggregates; MEDIAN/PERCENTILE variants with 1,323 pinned aggregate/window cases; STRING_AGG, aggregate ORDER BY with FILTER/DISTINCT/collations; connection-local scalar/aggregate callbacks; DATE/TIME/DATETIME/JULIANDAY/UNIXEPOCH/STRFTIME/TIMEDIFF and dynamic defaults; broader edge cases remain |
| GROUP BY / HAVING | Verified subset | Expressions/ordinals/aliases, HAVING aliases, distinct aggregates, empty inputs and bare-column MIN/MAX selection in differential cases |
| Window functions | Verified bounded subset | Ranking, NTILE, LAG/LEAD, first/last/nth values, aggregate ROWS/GROUPS/RANGE frames/offsets, EXCLUDE, FILTER, named/inherited windows and NULLS FIRST/LAST; max 10,000 rows; grouped aggregates and HAVING feed windows |
| Schema creation / index maintenance | Verified subset | CREATE/DROP TABLE/INDEX/VIEW/TRIGGER, CREATE TABLE AS, ADD/RENAME/DROP COLUMN and table rename with resolved view/trigger references, ordinary and WITHOUT ROWID B-trees, auto/secondary indexes, overflow; 847 SQLite cross-open/integrity snapshots per encoding (2,541 total across UTF-8/UTF-16le/UTF-16be); ADD places columns before table constraints |
| Generated columns | Verified subset | VIRTUAL/STORED, deterministic expressions, dependency order/cycle rejection, affinity, constraints/indexes, ADD virtual and guarded rename/drop; native fixtures in all encodings |
| Constraints | Verified subset | Defaults, NOT NULL/UNIQUE/CHECK, STRICT, AUTOINCREMENT, FK enable state/actions/deferral, OR IGNORE/REPLACE/FAIL/ROLLBACK, partial/expression unique keys; schema PRIMARY KEY/UNIQUE/NOT NULL conflict policies and recursive REPLACE delete triggers; evaluation errors are not ignored as constraints; broader edge-case conformance pending |
| Views / row triggers | Verified subset | Read views; BEFORE/AFTER INSERT/UPDATE/DELETE, FK-action child row triggers, UPDATE OF, WHEN, OLD/NEW, DML/SELECT/WITH/VALUES bodies, WHEN subqueries, RAISE ABORT/FAIL/ROLLBACK/IGNORE, recursive_triggers state/1,000-depth bound, typed OLD/NEW and automatic rowid timing; INSTEAD OF INSERT/UPDATE/DELETE view triggers, zero direct change counts and RETURNING |
| DML | Verified subset | INSERT VALUES/multirow/DEFAULT VALUES/SELECT, REPLACE shorthand, UPDATE/DELETE, UPSERT target/DO NOTHING/DO UPDATE, RETURNING with owner RPC; expression/partial conflict targets; combined conflict policies verified; WITH/RECURSIVE DML, scalar/correlated subqueries, target aliases, UPDATE FROM, tuple SET/UPSERT assignments; broader syntax pending |
| PRAGMAs | Verified subset | Header/table/index/FK metadata, integrity_check/quick_check/foreign_key_check, mutable foreign_keys/recursive_triggers/user_version/application_id; table_list/collation_list/function_list/pragma_list/database_list and metadata-only scalar/CAST view types; bounded to supported images/schema |
| Row values | Verified subset | Per-field comparison/IN/BETWEEN/CASE affinity, NULLs, collations and callback order; wildcard-width preparation; 1,298 pinned cases |
| Maintenance | Verified subset | ANALYZE/sqlite_stat1, REINDEX, VACUUM main; 285 native cross-open snapshots plus stale expression-index repair; STAT1 prefix ranking implemented, native cost-model equivalence and VACUUM INTO unsupported |
| Schema qualifiers / index hints | Verified main subset | main qualification bypasses CTE shadows; INDEXED BY validates index/predicate and executes single-table index plan; NOT INDEXED retains rowid plans; joins still materialize inputs; 69 pinned cases across encodings |
| Connection counters | Verified subset | CHANGES/TOTAL_CHANGES/LAST_INSERT_ROWID, trigger-local restoration, transaction rollback/FAIL, FK actions and DROP implicit deletes; 48 pinned multi-statement sequences across encodings plus isolation/schema tests |
| Transactions / savepoints | Implemented for image writer | SQL snapshots, nested savepoints, deferred FK commit; pinned 14-step transaction sequence |
| Rollback journal | Conditional durable contract | PERSIST before-images, every-operation/torn-write crash tests, recovery injection; native byte-exact hot-journal recovery |
| WAL writes / checkpoint / recovery | Exclusive-owner subset | Both checksum endians, three native cross-open commits, native continuation, torn frames/pages and every-operation growth/shrink checkpoint recovery |
| Isolate ownership / file lease | Single-owner architecture | Serialized SendPort requests, client-owned transactions, loopback duplicate-owner guard, native SQLite lock-byte exclusion and handoff |
| ORM runtime | Verified M7 baseline | Public engine APIs only; typed codecs/queries, BigInt keys, identity/snapshot tracking, atomic CRUD/revisions, immutable values, explicit batched relationships and safe reviewed migrations; Dart `MappedField` closures (`equalTo`, comparison operators, `oneOf`, null tests) lower to the same bound SQL; 158 real-engine/fault tests |
| Metadata generator | Verified M7 baseline | Resolved conventions/annotations, constructors/aliases, mutable/immutable mappings, deterministic owned output and CLI; 48 tests including compiled generated end-to-end consumers; unsupported model shapes/custom codecs use manual metadata |
| Virtual table module registration | Item 1 verified | Connection-local Dart `VirtualTableModule`; `CREATE VIRTUAL TABLE name USING module(args)` writes a `table` row with root page 0; SELECT and joins read module rows (text, integer, blob, null). Unknown module, reserved name, duplicate name, and bad module output do not commit. Column lists, lifecycle hooks, constraints, hidden columns, transaction hooks, and `generate_series` are not claimed |
| JSON/JSONB / FTS / R-tree | M8 pending | No implementation claim |
| Linux x64 | Development verified | Dart 3.13.7; 9,643 engine, 158 ORM and 48 generator tests; format, fatal-info analysis and locked dependencies pass |
| Windows/macOS/Android/iOS/Web | Unverified, M9 pending | Core has no dart:io dependency; optional file/owner adapter does; no execution claim |

## Query and format limits

General SQLite conformance is not claimed. See README for the current grammar.
Unsupported SQL should fail explicitly. A mutable query reads its image through a shared read-only view and does not copy the database bytes before scanning. Query results are materialized and integer
values use BigInt to retain signed-64-bit precision. Malformed UTF text is
rejected rather than emulating native SQLite's permissive decoding. The default
record bound is 16 MiB. The parser limits SQL to 1 MiB and expression nesting to
128. Floating rendering/numeric coercion beyond the pinned cases is unverified.
Multiple MIN/MAX bare-column ambiguity and unspecified row ordering are not
portable guarantees. Window execution is materialized and is not a performance
claim. Index plans use safe equality prefixes/ranges and a constraint-count heuristic;
valid STAT1 prefix cardinalities now rank eligible indexes. A complete native
cost model and SQLite EXPLAIN bytecode remain unsupported.

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
ALTER supports ADD/RENAME/DROP COLUMN and table renaming (resolved view/trigger references rewritten; resolved column dependencies validated before commit; explicit DROP dependency checks remain) and never silently performs destructive
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

M6's bounded main-schema engine baseline is defined separately from the remaining
SQLite targets in [ENGINE_SUPPORT.md](docs/ENGINE_SUPPORT.md). TEMP/ATTACH,
unlisted PRAGMA state, native EXPLAIN/cost-model equivalence, custom collations
and broader conformance remain unsupported. M7's ORM/generator gate passes for
the documented runtime/generator contract. M8 extensions and M9 browser/platform/
release work have not passed their gates. Saved AOT benchmarks contain real raw samples
for small Linux memory workloads, not the required 1k/10k/100k/1m scale and
platform/ORM/native-engine comparison matrix. No release-ready or all-milestones
completion claim is made.

The master specification's full SQLite target is not marked implemented by
passing the bounded engine gate.

Table-rename verification includes qualified/wildcard/correlated views, aliases,
CTE shadows, trigger owners/WHEN/DML and the pinned trigger UPSERT EXCLUDED
rebinding quirk. Ambiguous alias/pseudo-row namespaces reject; arbitrary schema
rewriting is not claimed. Column alterations resolve supported view/trigger fields
and validate the proposed schema. NATURAL join rewrites follow merged-column
origins, including RIGHT/FULL joins. Renaming USING keys rejects invalid joins,
matching the reference. Broader schema and DQS fallback remain unverified.

Constraint key collation/direction metadata and WITHOUT ROWID index suffixes are
verified against 837 native snapshots. Repeated primary-key terms reject.
Parent actions whose PK collation differs from its column declaration reject
atomically; pinned SQLite can leave orphan rows here. Views now prepare metadata
and defer rows without callbacks. Eligible INSERT SELECT inputs stream, while
target interaction and RETURNING retain materialization boundaries. Ordinary/
NOT MATERIALIZED relations substitute eligible expressions and MATERIALIZED
retains values in the pinned cases. Native optimizer equivalence is not claimed.

STAT1 planning ranks supported single-table index candidates using prefix row
estimates, preserving mandatory hints and partial-index proofs. Thirty native
plan/result comparisons and real Linux AOT samples verify the documented subset;
full table/index costing, join reordering and STAT4 are not claimed.

Further metadata verification covers 294 scalar-subquery operations and 504
UPDATE FROM/group ALTER snapshots. Defaults, lazy view preparation and skipped
branches have 165 native callback comparisons. TRUE/FALSE name binding has 1,515
pinned comparisons; materialized boolean labels use native columnN naming.
Qualified state PRAGMAs preserve reference parsing and preparation-time effects.
Native IN-table rename rejection is reproduced. A USING-key rename that native
SQLite accepts with a broken UPDATE FROM trigger is rejected atomically here.

SQL numeric separators and postfix NOT NULL are verified in the expanded query
oracle, including signed-64-bit/hex boundaries and malformed tokens. Row-valued
UPDATE/UPSERT assignments have 459 native operation comparisons across encodings;
subqueries compute a vector once and fields evaluate in native target-column
order. Generated columns named rowid/_rowid_/oid remain read-only.

Execution-order hardening adds 321 streaming scenarios (1,740 live operations and
321 native cross-open images), 1,053 CTE/scalar/EXISTS cases, 180 aggregate cases,
261 window cases and 306 generated-column read cases. Window inputs cache each
argument/filter and preserve tested lookahead/sorter/coroutine boundaries;
callback-bearing WHERE filtering can still buffer before window output.

Pattern function dispatch and stored view/trigger/default signature preparation
have 6,438 native operations. Numeric text coercion has 1,392 operations covering
ASCII/Unicode whitespace, NUL, integer prefixes and storage-class boundaries.
Table-valued metadata PRAGMAs have 576 comparisons including ALTER dependencies;
forward-source/reordered correlation, correlated RIGHT/FULL sources and hidden
argument IN subqueries remain explicit limits.

ORM native checks include 672 generated bound-query comparisons, 27 CRUD/schema
comparisons with three encoding cross-opens/native write continuations, and 123
migration operations with 21 cross-open snapshots and three continuations.
Migration plans bind exact approval and recheck schema inside an owned
transaction; unmanaged objects remain, destructive/ambiguous changes require
explicit operations, and indeterminate outcomes poison the affected context.
JavaScript compilation and a Node memory smoke cover codecs, full signed64 keys,
linked CRUD, tracking/revisions and relationship loads. This verifies browser-safe
runtime imports/execution, not browser storage durability or mobile platforms.
