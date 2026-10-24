# Development log

## Initial scaffold

- Created Dart monorepo skeleton, memory backend and unit tests.
- Dart SDK not present in scaffold execution environment; `dart analyze` and `dart test` **not executed**.
- Repository connected and first scaffold uploaded on 2026-10-24.
- No Codex coding session has been launched.
- Next: provision Dart SDK, run tests, pin SQLite reference version, implement header decoder and SQLite fixtures.

## 2026-10-24 — M0 verification and M1

- Read the project specification and engineering instructions; verified the
  original scaffold independently from an archived HEAD: formatting, fatal-info
  analysis, and all 5 memory-storage tests pass. No baseline CI failure reproduced.
- Installed Dart 3.13.7 from a SHA-256-verified official `library/dart` image SDK
  layer because direct Google Storage downloads were denied. Kept SDK and package
  caches outside the checkout. Used supported analyzer state override and Dart's
  analytics suppression for the read-only home directory.
- Pinned the development oracle to SQLite 3.53.1 and its exact source ID; recorded
  compile options, dbstat expectations and SHA-256 hashes in the fixture manifest.
  Regeneration passes integrity_check and is byte-for-byte reproducible.
- Implemented Pure Dart database-header decoding and structural B-tree page
  validation, including corrupt/truncated inputs, page size boundaries, header
  versions, freeblocks, pointer arrays, reserved space and page-one placement.
- Engine: 20 tests pass (5 storage and 15 format/fixture tests); analysis with
  fatal infos passes. All three packages pass formatting and analysis. Added
  dependency lockfiles and expanded CI to all packages, pinned Dart, enforced
  lockfiles, and checked fixture hashes. Remote GitHub Actions was not run here.
- Scope: no SQL, pager, records, writes, WAL recovery or full database integrity
  checks. No runtime native SQLite dependency. Other platforms remain untested.
- Next milestone: M2 read-only pager and B-tree traversal/record comparison.

## 2026-10-24 — M2 read-only pager and B-tree records

- Implemented Pure Dart exact/partial-read paging with authoritative logical
  page counts, stale-size fallback, independent buffers and backend ownership.
  WAL header versions are rejected; the reader requires a stable journal-free
  rollback-format copy and provides no locks or recovery.
- Added an optional dart:io read-only file backend. Serialized seek/read pairs
  protect concurrent reads; write/truncate operations are unsupported. The core
  export remains independent of dart:io.
- Added iterative table/index traversal (including index interior records and
  WITHOUT ROWID trees), bounded overflow reconstruction, cell/freeblock overlap
  checks, separator bounds, repeated-page and chain-length validation.
- Added bounded varint and record decoding: all integer serial widths use BigInt,
  plus doubles, NULL, copied blobs and well-formed UTF-8/UTF-16 text. Physical
  INTEGER PRIMARY KEY alias fields remain NULL, with rowid exposed separately.
- Expanded the same pinned SQLite 3.53.1 fixtures and recorded SELECT expectations:
  2,244 physical records, 213 pages (131 overflow), 512/4096/65536-byte pages,
  minimum/maximum rowids, overflow/local boundaries, empty tables, indexes,
  WITHOUT ROWID, schema records, blobs and supplementary Unicode characters.
  Source ID and compile options are enforced, and all binary/oracle checksums
  are verified. Regeneration is byte-for-byte deterministic.
- Verified all 48 engine tests, formatting and fatal-info analysis on Dart
  3.13.7/Linux x64. Tests include partial reads/EOF, file byte preservation,
  lifecycle, corrupt pointers/varints/records, cycles, shared pages, separator
  order, overflow lengths, reserved tails, cancellation, 2,000 deterministic
  malformed record inputs and 100 mutated B-tree inputs. All three packages
  pass locked dependency installation, formatting and analysis.
- No write/crash-recovery tests apply to these read-only changes. M3 catalog/SQL,
  concurrent mutation safety, malformed-text parity, full integrity checking,
  and execution on other platforms remain unimplemented/unverified. Remote
  GitHub Actions results are not claimed by local command verification.

## 2026-10-24 — M3 catalog and SELECT subset

- Added a strict bounded tokenizer/parser, sqlite_schema catalog, CREATE TABLE
  metadata decoding, and a Pure Dart read-only single-table SELECT API.
- Implemented projections, aliases, rowid aliases, WITHOUT ROWID mapping,
  WHERE, DISTINCT, ordering, limits/offsets, positional bindings and core
  arithmetic/comparison/NULL expressions. Unsupported syntax fails explicitly;
  M6 remains responsible for full semantics, joins, functions and aggregates.
- Generated 726 deterministic SELECT oracle cases with the pinned SQLite 3.53.1
  source and compile options. Differential failures exposed column label,
  UTF-16 binary ordering and blob numeric conversion differences; corrected them
  and retained the cases. Added integer limits, infinities, signed zero,
  malformed SQL, schema constraints, binding and parser-depth regressions.
- All 808 engine tests pass, including the M0–M2 regressions; formatting,
  fatal-info analysis and oracle checksums pass. CI verifies the SELECT oracle.
  The oracle is development-only; runtime remains Pure Dart.
- Investigated M4 filesystem durability prerequisite: Dart's File.open on a
  directory fails with EISDIR in this environment, so a parent directory cannot
  be flushed through the available dart:io file API. Durable journal creation
  and directory-entry persistence need an explicitly supported capability;
  do not claim crash-safe filesystem writes from ordinary file flush alone.

## 2026-10-24 — M4 limited writes and rollback journal

- Implemented record serialization, rowid B-tree bulk mutation/rebuilding,
  overflow writes, freelist reclamation and cross-tree ownership validation.
  Added atomic single-statement INSERT/UPDATE/DELETE for simple unindexed rowid
  tables. Indexed/triggered/constrained, WITHOUT ROWID, auto-vacuum and reserved
  space targets fail explicitly; no general writable compatibility claim.
- Implemented SQLite-compatible single-header rollback journals with complete
  before-images and PERSIST header invalidation, guarded by an explicit durable
  storage capability. Every mutating storage operation and each recovery step
  is tested with crashes, both dropping and retaining unsynced writes.
- Added an existing-file-only Pure Dart adapter that requires explicit caller
  attestation of durable directory entries. Random-position writes, flush and
  truncate are verified; it cannot establish directory-entry durability, locks
  or physical power-loss safety. No files are silently provisioned.
- The pinned SQLite 3.53.1 reference successfully recovers a Dart-produced hot
  journal byte-for-byte. Eight sequential INSERT/UPDATE/DELETE image snapshots
  cross-open, match reference rows/change counts and pass SQLite integrity_check.
- All 821 engine tests pass, with formatting, fatal-info analysis and checksum
  checks. Added writer fixture verification to CI. Runtime remains Pure Dart.
- M5 remains next: SQL transactions/savepoints, locking, WAL and recovery. M4
  storage durability is conditional on its documented backend contract, not a
  claim that the cloud filesystem has been power-loss certified.

## 2026-10-24 — M5 foundations; milestone not complete

- Added private-image BEGIN/COMMIT/ROLLBACK and nested savepoint scopes to the
  limited mutable writer. Deferred physical writes until outer commit; closing
  rolls back, statement errors preserve the transaction, and commit I/O failures
  poison the session. A 14-step transaction/savepoint sequence matches the pinned
  SQLite reference and each exported image passes SQLite integrity_check.
- Added offline WAL snapshot recovery, checksum/salt validation, committed-prefix
  selection and independent rollback-format copy generation. Tests use real WAL
  captures from the pinned build and check every truncated final-frame tail,
  corrupt frame/header data, multiple commits and bounds. No live WAL writing,
  shared-memory wal-index management or checkpoint protocol is implemented.
- Added an optional exclusive SQLite lock-byte-range lease. A separate SQLite
  process is blocked under the lease and succeeds after release; same-isolate
  duplicate opens are rejected. SDK documentation confirms POSIX locks are
  process-wide, permit overlapping isolates, and can be dropped by another file
  descriptor closing. General multi-isolate ownership remains unfinished.
- Hardened raw image writes to reject constrained targets, and made bound blob
  results independent copies. Added regressions and a constrained fixture table.
- All 834 engine tests pass; all packages pass formatting, locked installation
  and fatal-info analysis. All fixture/oracle checksum checks and M4 reference
  verification pass. Runtime remains Pure Dart; native SQLite is development-only.
- M5 remains unchecked. M6–M9 are unstarted to preserve the user's requirement
  to finish and verify each milestone before moving on. No claim that all
  remaining milestones are completed, or that production WAL/concurrency works.

## 2026-10-24 — M5 exclusive-owner WAL completion

- Added the ImagePager commit boundary and a full-image WAL writer/checkpointer.
  Commits acknowledge after WAL sync; checkpoints sync WAL, copy main pages,
  sync main, then clear/sync WAL. Shared parsing covers both checksum endians.
- Recovery now supports a main file partially updated by checkpoint, including
  a new header size before physical growth. Tests cover every commit/checkpoint
  storage operation with retained/lost unsynced writes, torn frame/page writes,
  old committed-prefix preservation, database growth and shrinkage.
- Added DatabaseOwner/DatabaseClient RPC: one isolate owns all handles; clients
  share SendPorts, requests serialize, and transaction scope belongs to a client.
  A loopback-port ownership guard rejects duplicate owner isolates before opening
  a main descriptor; an exclusive SQLite lock-byte lease excludes native readers.
  Guard ports carry no SQL. Collisions fail closed; canonical-path identity and
  no direct/aliased handles are required. General shared-reader wal-index mode
  remains explicitly unsupported rather than claimed as SQLite parity.
- The pinned SQLite reference verifies three Dart WAL commits, both checksum
  byte orders, checkpoints, native write continuation and exclusive owner
  handoff. Native SQLite remains blocked after a rejected duplicate-owner open.
- All 852 tests pass, all packages pass formatting/fatal-info analysis and locked
  installation, and fixture/oracle checks pass. Runtime remains Pure Dart.
- M5 is checked for this exclusive-owner architecture. No shared external WAL
  readers, automatic mode switching/file provisioning, hard-link coordination,
  physical power-loss certification or cross-platform claim is made.
- Next: M6 SQL semantics, planner/index use, functions and PRAGMAs. Full SQL
  compatibility remains unclaimed and must be supported by differential evidence.
