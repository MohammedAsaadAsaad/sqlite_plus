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

## 2026-10-24 — M6 functions, aggregates, metadata and rowid planning (partial)

- Added bounded scalar functions and core aggregates, column grouping/HAVING,
  distinct aggregates, signed metadata PRAGMAs and column constraints/default
  metadata. Unsupported syntax/arity, aggregate misuse and bare-column cases
  fail explicitly; M6 remains unchecked.
- Added rowid equality planning and validated B-tree point descent. A regression
  compares identical results and page-read counts against a forced scan. Point
  searches retain cell/freeblock/separator/overflow corruption checks.
- Added 291 pinned SQLite differential cases across all three fixture encodings,
  including error cases. Corrected aggregate error evaluation inside lazy scalar
  expressions, empty input/LIMIT 0, compensated sums with split integer input,
  floating quote/text rendering, type metadata and output-allocation limits.
- All 1149 engine tests pass with formatting, locked installs, fatal-info analysis
  and all checksum gates. Rollback, transaction, WAL/native-write continuation
  and owner interoperability verifiers pass against the pinned SQLite build.
- Collected five real AOT samples for a 2000-row memory-backed point-query versus
  scan workload; saved raw microsecond timings, fixture SHA, SDK and process RSS
  under benchmark_results. No general benchmark or M9 completion claim.
- M6 still needs joins/subqueries/compounds, remaining expression semantics,
  secondary indexes and maintenance, constraints, DDL and full conformance.
  M7–M9 remain unstarted to preserve sequential verification.

## 2026-10-24 — M6 relational execution, schema/index writes and windows (partial)

- Added joins (including outer/NATURAL/USING), qualified/derived sources,
  correlated/scalar/EXISTS/IN subqueries, compounds and ordinary/forward/bounded
  recursive CTEs. Added IN/BETWEEN/CASE/CAST/LIKE/GLOB/bitwise expressions,
  explicit/declared BINARY/NOCASE/RTRIM, expression/ordinal/alias grouping,
  HAVING aliases and differential MIN/MAX bare-column selection.
- Added fresh SQLite image creation and compact rowid/index B-tree construction,
  promoted interior index records, overflow pages and schema reconstruction.
  Mutations validate cross-tree ownership and freelists before rebuilding.
  Indexed/WITHOUT ROWID writes, DDL/ADD COLUMN, defaults, NOT NULL/UNIQUE/CHECK,
  STRICT, AUTOINCREMENT, FK actions/deferral, views and BEFORE/AFTER row triggers
  now have verified subsets. Unsupported schema/trigger forms remain explicit.
- Added column-index prefix descent and ordinary-table rowid fetches for safe
  equality plans. Tests compare results/page reads against scans for duplicate,
  descending, missing and NULL keys. Broader planner work remains open.
- Added bounded ranking/value/offset/aggregate windows, PARTITION/ORDER, ROWS and
  default/peer RANGE frames; unsupported grouped/named/advanced frames remain
  rejected. Added table/index/FK PRAGMAs and transactional user/application header
  metadata writes. Fixed trigger IGNORE row skipping and atomic ABORT rollback.
- Expanded the pinned M6 oracle from 291 to 624 cases across the three encodings.
  Added 153 schema/index/constraint/trigger mutation snapshots; pinned SQLite
  cross-opens each image, compares rows/metadata and passes integrity_check.
- All 1,493 engine tests pass. All three packages pass locked dependency
  installation, formatting and fatal-info analysis. Fixture/oracle checksums,
  8 mutation and 14 transaction snapshots, byte-exact hot-journal recovery,
  WAL both-endian/checkpoint/native continuation and owner handoff checks pass.
- Collected a real AOT five-sample index-versus-scan benchmark over 10,000 rows
  and saved raw microseconds, image size, SDK and whole-process RSS. This remains
  one small Linux memory workload; it does not satisfy M9's benchmark matrix.
- M6 remains unchecked for remaining SQL breadth and conformance; M7–M9 remain
  pending. Documentation now distinguishes implemented subsets from open gates.

## 2026-10-24 — M6 UPSERT/RETURNING, rename and advanced window expansion (partial)

- Added direct INSERT/UPDATE/DELETE RETURNING results, including empty-result
  metadata and values captured before AFTER-trigger changes. MutationResult and
  owner RPC preserve result columns, BigInt and blob values. Trigger-body and
  aggregate/window RETURNING forms reject before mutation.
- Added multiple ON CONFLICT clauses, column/rowid targets, DO NOTHING,
  DO UPDATE/excluded/WHERE, INSERT SELECT, AUTOINCREMENT attempts and WITHOUT
  ROWID cases. Combined OR policies and partial/expression targets remain open.
- Added atomic table renaming with supported index/FK/sequence rewrites and
  transaction rollback. Dependent views/triggers reject the operation; no
  ambiguous dependency rewrite or destructive migration is performed.
- Fixed schema-name collisions with views and validated supported trigger-body
  syntax before storing it. Added regressions for malformed trigger programs,
  reserved names and statement rollback. Scalar trigger SELECT honors WHERE.
- Added aggregate FILTER, named/inherited windows, GROUPS/numeric RANGE offsets,
  EXCLUDE and explicit NULLS FIRST/LAST in ordinary/compound/window ordering.
  Expanded the pinned SQL oracle to 717 M6 cases and the native mutation verifier
  to 189 snapshots, now including RETURNING results and FK/header metadata.
- Final verification: 1,592 engine tests pass; all packages pass formatting and
  fatal-info analysis with locked dependencies. All fixture/oracle checksum gates,
  8 mutation/14 transaction snapshots, byte-exact rollback recovery and WAL/native
  continuation/owner handoff verifiers pass. The final schema verifier covers
  195 snapshots; extra multi-clause/catch-all UPSERT assertions pass separately.
- Trigger OLD/NEW DML values now use bound parameters, avoiding SQL text
  round-tripping for NULs, quotes, infinities and blobs. Added Dart and native
  cross-open regressions for these values.
- M6 remains open for remaining SQL/function/PRAGMA/ALTER/grouped-window breadth
  and hardening. M7 ORM/generator, M8 extensions and M9 platform/release gates
  are not marked complete.

## 2026-10-24 — M6 completion work: grouped windows, functions, range plans and integrity

- Split grouped evaluation, HAVING and window execution into distinct phases.
  Added grouped/window aggregate contexts and rejected invalid nested aggregates
  and windows. Non-window scans stream contexts rather than retaining them all.
- Added connection-local Pure Dart scalar and aggregate registration, overloads,
  varargs, built-in overrides, callback failure/value conversion and copied blobs.
  Registries stay isolated across concurrent async connection scopes. Registered
  aggregates support DISTINCT/FILTER and feed built-in windows after grouping.
- Added string helpers, math functions, variadic IF/IIF and decimal ROUND through
  30 places. Added DATE/TIME/DATETIME/JULIANDAY/UNIXEPOCH/STRFTIME/TIMEDIFF,
  statement-stable CURRENT keywords and dynamic defaults without executing them
  while reading catalog metadata. Added pinned timezone/calendar/epoch/format
  boundary cases and unambiguous infinity encoding in development fixtures.
- Added rowid ranges and secondary multi-column equality prefixes/ranges with
  descending/inclusive/NULL bounds, residual predicates and a prefix-length
  heuristic. Callback predicates avoid planning-time execution. Regression tests
  compare scans and page-read counts; fresh AOT planner measurements are saved.
- Added bounded integrity_check/quick_check and foreign_key_check. Integrity
  checks validate tree/freelist coverage, constraints and persisted index contents
  against reconstructed table data. Tests corrupt an index key and distinguish
  full from quick checking; FK checks cover violating and WITHOUT ROWID rows,
  disabled enforcement and mismatched parent definitions.
- Expanded the pinned M6 oracle to 1,161 cases; the development-only schema
  verifier now checks 210 snapshots including dynamic defaults and integrity/FK
  PRAGMA results. Full SQL/native conformance remains unclaimed.
- Final checks pass: 2,043 engine tests; locked dependency installation,
  formatting and fatal-info analysis for all three packages; all fixture/oracle
  checksums; 210 native schema/query snapshots; 8 mutation/14 transaction
  snapshots; byte-exact rollback recovery and both-endian WAL/checkpoint/native
  continuation/owner handoff checks.
- Regression fixes isolate registries even when connections nest async execution
  scopes; mutable readers explicitly share only their owning registry. CURRENT
  keywords retain their own SQL function identities when DATE is overridden.
- Fresh five-sample AOT point/range measurements cover 10,000 memory-backed rows.
  Raw timings, whole-process RSS, SDK and image size are saved. The earlier
  concurrent check run showed timing variation, so the committed run is repeated
  after the complete test suite finishes. No M9/platform benchmark claim.
- M6 is still open. The completion audit lists remaining column ALTER/dependency
  rewrites, partial/expression indexes and related UPSERT forms, additional
  trigger policies/view/recursion/body shapes, generated columns and broader
  SQL/function/PRAGMA conformance. These missing features are not hidden by
  checking the milestone or relabeling the verified subset as full SQLite parity.

## 2026-10-24 — M6 column ALTER operations

- Added explicit RENAME [COLUMN] and DROP [COLUMN] on supported schemas. Rename
  updates declarations, CHECK/key constraints, column indexes, parent FK column
  references and INTEGER PRIMARY KEY metadata. Function/type/collation names
  are preserved even when they match a renamed column.
- Drop reconstructs record widths and rejects keys, index/CHECK/FK dependencies,
  last-column deletion and ambiguous declarations. Dependent views/triggers fail
  before mutation; this does not silently rewrite them or perform migrations.
- Added ordinary/WITHOUT ROWID, overflow reclamation, transaction rollback,
  collision/dependency and punctuation-quoted column regressions. Structural
  token checks distinguish quoted parentheses/commas from SQL punctuation.
- The native schema verifier now covers 235 snapshots, including rename/drop
  metadata and integrity checks. M6's remaining open scope is documented; it is
  not marked complete while those features are missing.
- Final checks pass: all 2,044 engine tests, all-package formatting/fatal-info
  analysis, fixture/oracle checksums and pinned mutation/transaction/journal/WAL
  interoperability verifiers. No platform or full-M6 completion claim is made.

## 2026-10-24 — M6 expression and partial indexes

- Added a shared index definition for deterministic scalar terms, ordering,
  collations and WHERE predicates. Image reconstruction maintains key values,
  partial membership, unique constraints and WITHOUT ROWID primary-key suffixes.
  Foreign keys cannot use expression/partial unique indexes as parent keys.
- Added expression equality/range planning and conservative partial-predicate
  proofs. Exact AST matching preserves operand order, boolean nodes and real
  literal spelling; unsupported/unproved conditions retain scans. Explicit
  UPSERT targets use stricter matching than query-plan predicate implication.
- Added expression-aware index_info/index_xinfo, column/table rename handling and
  drop dependency guards. Added deterministic flags to Dart scalar registration
  and runtime checks for non-deterministic date/time values in index expressions.
- Fixed inherited collations for function/arithmetic results while preserving
  explicit COLLATE and column affinity through unary plus/CAST. Fixed REAL
  column semantics when physical records store integer serial values.
- Distinguished constraint failures from expression/callback failures, preventing
  OR IGNORE from swallowing ABS overflow and other evaluation errors.
- The pinned verifier now checks 305 mutation/query snapshots independently for
  UTF-8, UTF-16le and UTF-16be (915 total), comparing data/metadata and native
  integrity_check after every operation. It covers Unicode/blob expressions,
  unique membership transitions, UPSERT, overflow records, schema alterations,
  invalid expressions and differing PK/index collations.
- Verification: all 2,051 engine tests pass; all packages pass locked installation,
  formatting and fatal-info analysis. Fixture/oracle checksums and pinned
  mutation/transaction/journal/WAL interoperability checks pass. Added a real
  five-sample AOT expression/partial-index point/range benchmark over 10,000
  rows, with forced scans, raw timings, image size and whole-process RSS.
- M6 remains open for the documented trigger/dependency/generated-column and
  broader SQL conformance work; no full milestone-completion claim is made.

## 2026-10-24 — M6 trigger queries, recursion and RAISE policies

- Added SELECT/WITH trigger bodies and WHEN subqueries against working images.
  OLD/NEW values keep their types and declared collations, without comparison
  affinity, matching the pinned reference. Removed runtime SQL interpolation;
  compile-only trigger validation no longer executes INSERT SELECT bodies.
- Added connection-local PRAGMA recursive_triggers, default off, with a 1,000-frame
  bound. Long success/error unwinds yield periodically to avoid Dart Future
  listener stack overflow. Tests exercise successful deep recursion, depth errors,
  full statement rollback, setting changes and savepoint behavior.
- Corrected automatic rowid timing: BEFORE INSERT sees -1 before allocation;
  final rowid allocation and subsequent multirow inserts account for trigger
  writes to the target table. Preserved trailing WHEN comments safely.
- Added RAISE FAIL partial-image persistence and RAISE ROLLBACK transaction/
  savepoint restoration. Owner RPC releases transaction ownership after rollback
  errors. Tested pager commits, poisoned I/O failure and FK precedence over FAIL.
- Fixed redundant scalar projection evaluation and output-expression ORDER BY
  reuse; preserved FILTER distinctions in expression matching. Added pinned
  callback-count results, HAVING laziness, alias/ordinal collation cases, signed
  ordinal syntax and TRUE/FALSE constant behavior. The M6 oracle has 1,212 cases.
- The native verifier now compares direct DML change counts as well as rows,
  RETURNING, metadata and integrity across 367 snapshots per encoding (1,101
  snapshots total). Advanced view triggers and remaining M6 audit items stay open.
- Final verification: all 2,112 engine tests pass; locked dependencies, formatting
  and fatal-info analysis pass for all packages. All fixture/oracle hashes,
  native mutation/transaction cross-open checks, byte-exact rollback recovery
  and WAL/checkpoint/owner-handoff interoperability checks pass.

## 2026-10-24 — M6 INSTEAD OF view triggers

- Added view INSERT/UPDATE/DELETE through INSTEAD OF triggers, UPDATE OF filters,
  initial-row snapshots and typed OLD/NEW contexts. View rows remain virtual;
  only underlying table mutations are serialized. Direct changes are zero and
  lastInsertRowid is unset; RETURNING reflects the view values.
- Matched pinned REAL output/pseudo-row behavior, ignored view rowid assignments,
  absent pseudo-rowid reads, timing restrictions, rollback and reopen behavior.
- Preserved declared types and collations through view/derived/CTE materialization
  and query metadata. Fixed UNION duplicate comparison/representative selection
  with inherited collations. Added 24 pinned query cases (1,236 total).
- Verification: all 2,138 engine tests, all-package locked installs and fatal-info
  analysis, formatting and oracle checksum verification pass. Pinned SQLite
  cross-opens 390 schema/DML snapshots in each encoding (1,170 total), checking
  RETURNING, direct changes, metadata, rows and native integrity_check. M6 remains
  open for the remaining documented SQL/schema and conformance audit work.

## 2026-10-24 — M6 SQL conflict policies and UPSERT combinations

- Added INSERT/UPDATE OR FAIL and OR ROLLBACK, reusing verified partial-image and
  transaction-owner rollback boundaries. NOT NULL/CHECK preparation precedes
  uniqueness/UPSERT resolution; REPLACE applies declared NOT NULL defaults.
- Allowed conflict policies with UPSERT; DO UPDATE and its trigger bodies always
  abort on constraints. Explicit outer policies propagate into ordinary trigger
  statements, overriding their own OR clauses. STRICT datatype errors always
  abort, including under IGNORE/FAIL; expression failures remain non-ignorable.
- Preserved row identity during candidate checks so FK cascades still execute;
  verified default substitution, partial writes and transaction/savepoint cleanup.
- Verification: all 2,142 engine tests, formatting, all-package locked dependency
  installation and fatal-info analysis pass. Fixture/oracle checksums and all
  native mutation/transaction/rollback/WAL interoperability checks pass. Pinned
  SQLite verifies 418 snapshots per encoding (1,254 total), including policies,
  UPSERT constraints, trigger inheritance and STRICT/default regressions. M6 is
  still open for schema constraint policies and the remaining documented audit.

## 2026-10-24 — M6 generated columns and binary fixtures

- Added VIRTUAL/STORED generated expressions, deterministic schema validation,
  topological dependencies/cycle errors, ordinary-column/PK/default restrictions,
  affinity and logical REAL handling. Virtual values are computed on reads;
  stored values occupy the correct rowid/WITHOUT ROWID physical record positions.
- Writes recompute generated values and maintain constraints/indexes. Positional
  INSERT excludes generated fields; explicit INSERT/UPDATE/UPSERT writes reject.
  Added virtual ADD, expression-aware rename, guarded DROP and table_info/xinfo.
- Added pinned native binary fixtures in UTF-8/UTF-16le/UTF-16be with overflow,
  stored/virtual chains and WITHOUT ROWID. SHA-256 verification is included in CI.
- All 2,149 engine tests, formatting, all-package locked dependency installs and
  fatal-info analysis pass. Native SQLite cross-opens 458 snapshots per encoding
  (1,374 total), checking data, RETURNING, metadata and integrity. Generated
  fixture/read/write tests and all fixture/oracle checksum checks pass.
- Existing native mutation/transaction checks, byte-exact hot journal recovery
  and WAL/checkpoint/native continuation/owner-handoff checks also pass. M6 remains
  open for the documented dependency rewrites, schema policies and broader audit.

## 2026-10-24 — M6 schema conflict defaults and REPLACE triggers

- Added per-constraint PRIMARY KEY/UNIQUE/NOT NULL conflict defaults, explicit
  statement precedence, duplicate-key policy merging/conflict errors, and native
  table CHECK conflict-clause parsing (CHECK still aborts by default).
- Added recursive REPLACE BEFORE/AFTER DELETE triggers, unique-key victim
  collection and FK actions, without counting implicit deletes as direct changes.
  Non-REPLACE constraints resolve before replacement deletion. BEFORE DELETE
  RAISE(IGNORE) leaves uniqueness enforcement active, matching the reference.
- Verification: all 2,152 engine tests, all-package locked dependencies and
  fatal-info analysis, formatting, all fixture/oracle checksums and existing
  mutation/transaction/journal/WAL/native-handoff checks pass. Pinned SQLite
  validates 501 mutation snapshots per encoding (1,503 total), including schema
  policies, compound keys, rollback, ignored replacement deletes and metadata.
- M6 remains open for dependency rewrites and remaining SQL/PRAGMA/planner audit.

## 2026-10-24 — M6 recursive CTE queue semantics

- Added stable priority queues for recursive ORDER BY, LIMIT/OFFSET extraction,
  FIFO ties, UNION deduplication and multiple recursive branches. Offset rows
  still feed recursion; LIMIT zero avoids anchor evaluation. The 100,000 queued
  row bound has passing exact-boundary and over-boundary tests.
- Validate recursive widths/references even with LIMIT zero; reject multiple
  direct recursive references, aggregates/windows and invalid ordering terms.
  Fixed ordinary CTEs evaluating their anchor twice, with callback-count tests.
- Added 93 pinned query cases across encodings (1,329 M6 cases total), including
  tree traversal, collations, NULL ordering, limits, malformed preparation and
  callbacks. Parameterized CTE INSERT RETURNING and atomic errors are covered.
- Verification: all 2,247 engine tests, all-package locked dependencies and
  fatal-info analysis, formatting and all fixture/oracle checksums pass. Native
  schema/DML cross-open verification still passes all 501 snapshots per encoding
  (1,503 total). GitHub Actions passed all five preceding pushed batches.
- M6 remains open for the documented dependency rewrites and conformance audit.

## 2026-10-24 — M6 VALUES queries

- Added standalone/multirow VALUES, derived/scalar/IN subqueries, compounds and
  ordinary/recursive CTE anchors, parameters and native column labels. VALUES
  query bodies now execute in trigger contexts and view definitions.
- Match terminal VALUES ORDER/LIMIT syntax restrictions, row-width validation,
  correlated values and native single-row versus multirow aggregate behavior.
- Verification: all 2,315 engine tests, all-package locked dependencies and
  fatal-info analysis, formatting and all fixture/oracle checksum checks pass.
  The pinned M6 oracle has 1,395 cases; native schema/view/trigger cross-open
  comparisons pass 514 snapshots per encoding (1,542 total). M6 remains open
  for the documented schema dependency and broader conformance audit work.

## 2026-10-24 — M6 CTAS, REPLACE and interior-page boundary fix

- Added CREATE TABLE AS SELECT/WITH/VALUES, query parameters, result-order rowids,
  SQLite column-name deduplication and affinity types, with no copied defaults,
  keys or generated-column constraints. Added REPLACE INTO shorthand through the
  existing conflict/UPSERT/trigger paths and string-quoted result/source aliases.
- Preserved query affinity, declared types and collations for LIMIT zero results,
  including CAST metadata; added differential comparison-affinity regressions.
- Native cross-open testing found a pre-existing table-tree split bug exposed by
  the larger UTF-16 schema: a final interior group could have one child/no keys.
  Redistribute the final child groups and reject empty interiors outside page one.
  Test 273 schema layouts across encodings and native integrity at the failing
  accumulated-schema boundary, with positive/negative framing regressions.
- Verification: all 2,344 engine tests, all-package locked installs/fatal-info
  analysis, formatting and fixture/oracle checksums pass. The M6 query oracle has
  1,419 cases. Native SQLite verifies all 537 snapshots per encoding (1,611 total).
  Mutation/transaction interoperability, byte-exact rollback recovery and WAL/
  checkpoint/native continuation/owner handoff checks pass after the storage fix.
- M6 remains open for dependency rewrites and the remaining conformance audit.

## 2026-10-24 — M6 named parameter indices

- Added :name/@name/$name and native namespace/suffix token forms, repeated-name
  index reuse, case/prefix distinction and mixed ?/?NNN indexing. The existing
  list API binds by native index; INSERT SELECT transfers its index map into
  UPSERT/RETURNING. Tested Unicode names, gaps and the 32,766-variable boundary.
- Reject parameters in CHECK expressions during schema preparation, avoiding an
  evaluation-time range error. Defaults/generated/view/index/trigger parameter
  restrictions are covered as well.
- Verification: all 2,389 engine tests, formatting, all-package locked dependency
  installation/fatal-info analysis and all fixture/oracle hashes pass. The M6
  oracle has 1,461 cases; pinned SQLite verifies 550 schema/DML snapshots in each
  encoding (1,650 total), including parameterized writes and atomic errors.
- M6 remains open for dependency rewrites and the documented conformance audit.

## 2026-10-24 — M6 aggregate ORDER BY and STRING_AGG

- Added aggregate-local ORDER BY with stable ties, direction, collations/NULLS,
  FILTER/DISTINCT and registered aggregate inputs. STRING_AGG shares GROUP_CONCAT
  semantics for grouped/window execution. Invalid scalar/window/star ordering
  and nested aggregate/window order expressions reject during preparation.
- Match native argument/key callback order and exact-expression reuse, DISTINCT
  representative selection for a shared ordering key, and separator evaluation.
  Preserve streaming callback/step interleaving for unordered registered functions.
- Verification: all 2,452 engine tests, all-package locked installs/fatal-info
  analysis, formatting and all fixture/oracle hashes pass. The M6 corpus has
  1,521 cases. Pinned SQLite verifies 558 snapshots per encoding (1,674 total),
  including ordered aggregation in CTAS, views and trigger bodies. M6 remains
  open for the documented dependency rewrites and broader conformance audit.

## 2026-10-24 — M6 table rename dependencies

- Added parsed source offsets and scope-aware table-reference rewriting for
  dependent views and triggers. Follow source/qualified/wildcard/correlated
  references, derived/compound/CTE scopes, trigger owners/WHEN and DML bodies;
  preserve aliases, column names, trigger names and string literals.
- Rewriting rejects unresolved qualifiers, duplicate source aliases and trigger
  pseudo-row/table namespace collisions atomically. Column dependency guards stay.
- Pinned comparison exposed SQLite 3.53.1 rebinding trigger UPSERT EXCLUDED
  qualifiers to the renamed target. Reproduce and document that reference quirk,
  including resulting updates, rather than silently claiming different behavior.
- Verification: all 2,455 engine tests, all-package locked installs/fatal-info
  analysis, formatting and all fixture/oracle checksums pass. Pinned SQLite
  verifies 598 schema/DML/query snapshots per encoding (1,794 total), checking
  rewritten views/triggers, rollback, quoted names and unresolved-reference errors.
  Existing mutation/transaction/journal/WAL/owner-handoff checks also pass.
- M6 remains open for dependent column rewrites and the broader documented audit.

## 2026-10-25 — M6 dependent column alterations

- Added metadata-only column binding resolution for views, derived/correlated/
  CTE sources, explicit aliases and trigger WHEN/DML/OLD/NEW/EXCLUDED fields.
  Column renames update resolved references; drops validate the proposed schema.
  Reject downstream automatic output-name breakage atomically, matching the
  pinned reference; preserve explicit aliases and support case-only renames.
- Retain named-window definitions for schema rewriting, including unused windows
  that ordinary queries ignore. Both table/column rewrites and drop validation
  now visit their references. Guard NATURAL/USING-key and ambiguous schema shapes.
- Fixed unary dynamic defaults invoking functions while parsing schema metadata.
  Only literal/unary-literal defaults are folded; dynamic defaults run on INSERT.
  ALTER ADD rejects non-literal default expressions without executing callbacks.
- Verification: all 2,461 engine tests, all-package locked installs/fatal-info
  analysis, formatting and all fixture/oracle checksums pass. Pinned SQLite
  verifies 663 snapshots per encoding (1,989 total), including dependent aliases,
  joins/correlation, trigger fields, case-only/quoted renames, rejected drops,
  unused windows and overflow-producing defaults deferred until INSERT. Existing
  mutation/transaction/rollback/WAL/native owner-handoff checks also pass.
- M6 remains open for guarded schema shapes and the broader conformance audit.

## 2026-10-25 — M6 join metadata and dependent alterations

- Resolve NATURAL/USING merged-column origins for column alterations, including
  LEFT/RIGHT/FULL joins and implicit-rowid collisions. Reject renamed USING keys
  when the resulting schema is invalid, matching pinned SQLite atomically.
- Preserve original-left affinity/collation during USING comparisons while
  exposing the correct merged result metadata. Real fields outrank implicit
  rowid aliases. Normalize derived-column collation at materialization boundaries.
- Match compound set-stage sorting and ORDER BY expression/ordinal/collation
  resolution, including stable UNION ALL concatenation.
- Verification: isolated staged snapshot passes all 2,536 engine tests, all-package
  formatting/fatal-info analysis and locked installs. The pinned query corpus has
  1,593 M6 cases; native SQLite verifies 740 schema/DML/query snapshots per encoding
  (2,220 total), including ALTER dependencies, join coercion and atomic errors.
- M6 remains open for the remaining SQL/schema/function/PRAGMA and trigger/FK audit.

## 2026-10-25 — M6 DML, row values, functions and maintenance

- Added scalar/correlated/EXISTS/IN mutation subqueries, statement WITH/RECURSIVE,
  target aliases and UPDATE FROM. Preserve self-read snapshots, live correlated
  reads, materialized assignments and per-target versus per-view joined-row writes.
- Fire user row triggers for CASCADE/SET NULL/SET DEFAULT in native order. Defer
  nested FK checks until the outer statement completes; guard the single-row
  insert fast path so child audit writes do not reject incomplete cascades.
- Preserve constraint COLLATE/direction and implicit/WITHOUT ROWID index metadata.
  Reject repeated PK terms and orphan-producing mismatched-PK-collation parent
  actions explicitly. Native cross-open verifies 279 key snapshots per encoding.
- Added row-value comparison/IN/BETWEEN/CASE, metadata-only wildcard width checks
  and compound-width preparation. Plain projections skip LIMIT/OFFSET-excluded
  expressions. Resolve merged-group ambiguity, deduplicate derived/CTE labels,
  bind JOIN ON output aliases/forward INNER references, and support main schema
  qualifiers plus INDEXED BY/NOT INDEXED with single-table planner enforcement.
- Added core Unicode/likelihood/random functions, native-format PRINTF/FORMAT,
  MEDIAN/PERCENTILE aggregates/windows and connection-local SQL counters. Match
  counter trigger restoration, FAIL/rollback, FK actions and incoming-FK DROP
  implicit deletes. Function introspection uses native percentile kind/flags.
- Added callback-free recursive view metadata and supported-capability PRAGMAs.
  Schema ALTER resolves names in invalid aggregate-ON views without executing
  them, matching native preparation; querying such a view still rejects.
- Implemented actual sqlite_stat1 ANALYZE data, REINDEX rebuilding and VACUUM main,
  including index/table statistics cleanup, stale expression-index repair and
  transactional restrictions. Planner statistics costing remains a later batch.
- Verification: isolated snapshot passes 5,690 engine tests, all-package locked
  installs, formatting and fatal-info analysis. Twelve fixture/oracle checksums
  pass. Pinned corpora include 1,647 general M6 cases, 1,298 row cases, 347 core
  cases, 11,613 PRINTF cases (tested in each encoding), 69 source/hint cases,
  1,323 percentile cases and 36 multi-statement counter sequences. Native tools
  verify 802 schema snapshots per encoding (2,406 total), 483 DML snapshots,
  837 constraint-key snapshots, 285 maintenance snapshots plus three repairs,
  4,692 JOIN comparisons and 180 metadata comparisons. Mutation/transaction,
  byte-exact hot-journal recovery and WAL/native continuation/owner handoff pass.
- M6 remains open for parenthesized joins/metadata, broader dependent-DML shapes,
  lazy view callback preparation, statistics planning and the remaining audit.
  M7–M9 remain pending; this is not an all-milestones completion claim.

## 2026-10-25 — M6 grouped sources, preparation and STAT1 planning

- Implemented parenthesized joined-source frames with qualified/hidden fields,
  materialized alias names, outer null extension, rowids and wildcard boundaries.
  Match native RIGHT/FULL merged wildcard values and group namespace errors.
- Added metadata-only grouped descriptors and scalar-subquery affinity/types,
  including correlated/nested queries and CTAS. Apply comparison affinity to both
  selected values; skip nested projections for literal LIMIT zero without calls.
- Extended table/column dependency visitors for trigger UPDATE FROM, correlated
  assignments and grouped scopes. Preserve atomic rejection when the pinned engine
  would accept a USING-key rename with a subsequently broken trigger. Track hidden
  group name allocation during ALTER and validate unrelated table qualifiers.
- View rows now defer until consumed. Empty targets and untaken branches prepare
  subquery widths without callbacks. Explicit INSERT fields skip defaults; rowid
  allocation ignores INTEGER PRIMARY KEY defaults. Match VALUES/default callback
  order and target-trigger input materialization in the verified subset.
- Rank eligible single-table indexes by valid STAT1 prefix estimates, retaining
  mandatory hints and safe partial proofs. Invalid/stale/duplicate statistics
  fall back; physical corruption rejects. Save reproducible five-sample Linux AOT
  data for 30-query/10,000-row workloads, with raw storage calls and process RSS.
- Bind TRUE/FALSE columns and output aliases before literal fallback. Preserve
  parenthesized constant labels and native materialized columnN names. Prevent
  ambiguous input fields from being rebound as WHERE/GROUP/HAVING output aliases.
  Avoid implicit-rowid metadata alias recursion.
- Added IN table/main.table with native row-width/NULL behavior and atomic native
  table-rename rejection. Qualified mutable state PRAGMAs now share actual
  connection flags, parse parenthesized/native signed-prefix arguments, and match
  preparation-time flag effects even when trailing SQL subsequently rejects.
- Remaining M6 work includes proper streaming INSERT SELECT/CTE callback behavior
  and the documented SQL grammar/PRAGMA/function audit. M7–M9 remain pending.
- Verification: all 7,346 engine tests, all-package locked installs/formatting and
  fatal-info analysis pass. Fourteen fixture/oracle checksum tools pass. Pinned
  verification covers 1,740 general M6 queries, 4,080 grouped-join cases, 1,515
  boolean-name cases, and 48 connection-state sequences with 1,752 steps. Native
  tools verify 815 schema snapshots per encoding (2,445 total), 1,224 grouped
  metadata comparisons, 294 scalar-metadata operations, 504 UPDATE FROM/group
  dependency snapshots, 165 lazy/default callback operations, 30 STAT1 plans and
  results, and the existing DML/constraint/maintenance/JOIN/metadata/storage checks.

## 2026-10-25 — M6 numeric grammar and row assignments

- Decode single underscore separators in decimal/hex/exponent SQL literals while
  retaining raw labels and separate string/PRAGMA prefix rules. Handle signed-min
  literals with separators/leading zeros; reject native unary-negation overflow
  for hexadecimal signed-min constants. Normalize separator spelling for compound
  ORDER BY expression matching. Add the NOT NULL postfix spelling.
- Support SET/UPSERT target vectors with literal rows and SELECT/VALUES sources.
  Check width before empty-target execution. Cache subquery rows per context;
  expand literal vectors before duplicate-target elimination so unused fields do
  not invoke callbacks. Evaluate fields in native column order, with rowid first
  for INTEGER PRIMARY KEY tables and declared order for WITHOUT ROWID tables.
- Extend trigger dependency rewriting through vector targets/RHS expressions.
  Permit quoted dotted UPSERT target fields. Keep generated rowid/_rowid_/oid
  columns out of the implicit-rowid writable set.
- Verification: 7,481 engine tests, fatal-info analysis and formatting pass. The
  general M6 corpus has 1,872 cases; the new assignment corpus has 459 pinned
  operations in three encodings, including callback counts, duplicate fields,
  correlated/uncorrelated/empty queries, UPSERT/FROM, views/triggers/ALTER and
  generated-column rejection. Native SQLite cross-opens 828 schema snapshots per
  encoding (2,484 total); all fifteen fixture/oracle checksum tools pass.
- M6 remains open for the documented streaming/CTE execution work and SQL audit.

## 2026-10-26 — M6 execution and verified engine handoff

- Introduce internal row cursors beneath materialized public query results.
  INSERT SELECT resumes expressions between writes; target reads/triggers and
  RETURNING materialize as required. Single VALUES evaluates fields/defaults in
  destination order. Preserve primary-key scan order for aliases, qualifiers,
  WITHOUT ROWID prefixes, ordinals and output aliases with LIMIT.
- Substitute eligible ordinary/NOT MATERIALIZED CTE/view/derived expressions;
  retain explicit materialization and coroutine boundaries. Ignore unreachable
  CTE sources/signatures, retain lexical scopes, and cache uncorrelated scalar/
  IN/EXISTS reads. Scalar queries stop at the first row; EXISTS suppresses unused
  projections while preserving preparation, aggregate/window and set semantics.
- Interleave aggregate inputs/steps by row, deduplicate equivalent aggregates,
  reuse grouping keys and native MIN/MAX representatives. Cache window inputs,
  filters and keys with tested lookahead/sorter/layered coroutine scheduling.
  VIRTUAL generated reads evaluate per reference; STORED values remain persisted.
- Add supported table-valued metadata PRAGMAs, hidden argument/schema fields,
  tested left-source correlation and ALTER dependency traversal. Dispatch SQL
  pattern operators through registered functions. Defer stored view/trigger/
  DEFAULT signatures and prepare applicable programs before mutation callbacks.
- Match ASCII numeric whitespace, NUL scanning, integer-prefix bitwise/remainder
  conversion and REAL-to-INTEGER signed64 boundaries. Keep bare boolean folding
  consistent with column resolution and aggregate/window preparation.
- Verification: all 9,632 engine tests pass. Locked dependency installation,
  formatting (129 repository Dart files), all-package fatal-info analysis and all
  23 fixture/oracle checksums pass. New pinned corpora contain 321 streaming,
  1,053 CTE/scalar/EXISTS, 180 aggregate, 261 window and 306 generated-read cases;
  pattern/stored SQL has 6,438 operations, numeric text 1,392 operations, and
  metadata table sources/dependencies 576 comparisons across three encodings.
- Native SQLite cross-opens 828 schema snapshots per encoding (2,484 total).
  Existing DML (483), key (837), maintenance (285 plus repairs), FROM dependencies
  (504), scalar metadata (294), grouped metadata (1,224), JOIN binding (4,692),
  metadata PRAGMA (180) and STAT1 (30) comparisons pass. Journal byte recovery,
  WAL continuation/checkpoint/ownership and mutation/transaction checks pass.
  Streaming additionally verifies 1,740 operations and 321 cross-open images.
  Window execution verifies 1,311 operations and 261 cross-open images.
- Close M6 specifically as the documented main-schema engine baseline, following
  the bounded contracts used by prior storage milestones. The full master target
  remains broader: TEMP/ATTACH, unlisted PRAGMA state, native planner/EXPLAIN,
  custom collations and other exclusions are retained in ENGINE_SUPPORT.md and
  the matrix. This is not a full SQLite compatibility or release-ready claim.
  M7 now consumes the verified public API; M8/M9 retain separate gates.

## 2026-10-27 — M7 ORM, generator and safe migration gate

- Add browser-safe immutable metadata, annotations, checked scalar/nullable
  codecs and connection ownership over public engine APIs. BigInt preserves
  signed64; int uses portable53 bounds; bool/date/blob conversions are explicit.
  Typed predicates bind values, quote identifiers, validate column identity and
  support composition, NULL/IN, ordering, pagination and query terminals.
- Implement DbContext identity maps, copied encoded snapshots, mutable/immutable
  CRUD, generated keys, revision concurrency and atomic SaveChanges. Freeze
  intended values synchronously, refresh store/trigger values inside the
  transaction, and publish keys/snapshots after commit while retaining later
  local edits. Cover BEGIN-after-open failures, deferred commit constraints,
  rollback failure and indeterminate migration/save poisoning.
- Add explicit reference/collection loading and bounded batches, composite/blob
  keys, provisional generated parent links, dependency ordering/deferred cycles,
  and tracked CASCADE/SET NULL refreshes. Loads preserve canonical identity and
  perform no implicit getter I/O.
- Add immutable schema plans, exact per-plan approval, live baseline rechecks,
  protected model/version metadata and post-change schema/FK validation. Safe
  additions preserve unmanaged objects. Destructive/ambiguous changes need
  explicit reviewed SQL/mappings; no guessed migration or broad approval flag.
- Add resolved convention/annotation generation, typed columns/mapping/key and
  relationship helpers, mutable/immutable constructors, located diagnostics,
  owned atomic output and CLI check mode. Analyzer/dart_style remain development
  dependencies. Generated consumers execute migrations, linked CRUD, revisions,
  queries, relationships, nullable assigned keys and export/reopen flows.
- Native migration cross-open exposed invalid engine ADD COLUMN SQL after table
  constraints. Insert new declarations before the first table constraint using
  parsed delimiter offsets; preserve comments/quoted punctuation and accept
  quoted keyword column names. Six regressions and the expanded native schema
  corpus verify physical images and errors in all three encodings.
- Verification: 9,638 engine, 155 ORM and 48 generator tests pass. All-package
  locked installs, formatting (160 Dart files), fatal-info analysis and all 23
  existing fixture checksums pass. CI now tests every package and compiles/runs
  the ORM JavaScript smoke. Current local JavaScript execution uses Node 24.19.0;
  browser storage/platform durability remains M9.
- Pinned native gates pass 847 schema snapshots per encoding (2,541 total), 672
  bound ORM query comparisons, 27 ORM CRUD/schema comparisons with three native
  write continuations, and 123 migration operations/21 cross-open snapshots with
  three additional continuations. Compiled JavaScript exercises full signed64
  keys, linked CRUD, blob tracking/revisions and relationship loads in memory.
- M7 closes for the documented API and supported generator shapes. Custom
  codecs/composite relationships and unsupported generator model shapes use
  manual metadata. M8 extensions and M9 browser/platform/performance/release
  gates remain open; no all-milestones or release-ready claim is made.

## 2026-10-27 — Shared query image and Dart field filters

- Mutable queries read through `ByteImageStorage`, a read-only alias of the live
  image. The view rejects writes and truncation, and close does not clear the
  caller's buffer. Page reads still copy one page into the pager. This removes
  the full-image copy on every query; it does not change the compact rebuild
  used for writes, the 64 MiB cap, or full SQLite conformance.
- `MappedField` exposes `equalTo`, `notEqualTo`, `oneOf`, null tests, and the
  comparison operators. Generated `<Model>Fields`, `filter`, and `orderByFields`
  let a closure name columns in Dart. `==` stays a bool operator, so equality
  uses `equalTo`. Predicates still bind values and quote identifiers.
- Verification on Dart 3.13.7/Linux x64: 9,640 engine tests, 158 ORM tests,
  48 generator tests, formatting and fatal-info analysis pass. Native schema,
  journal and WAL oracles were not re-run for this read-path change.
- Full SQLite parity, native cost-model equivalence, the rest of M8, browser
  durability, and the large-scale benchmark matrix remain open.

## 2026-10-27 — M8 item 1: virtual table module registration

- Added a Pure Dart `VirtualTableModule` registered on the connection through
  `SqlFunctionRegistry.virtualTables`. There is no C module ABI.
- `CREATE VIRTUAL TABLE name USING module(arguments)` stores the statement in
  `sqlite_schema` as a table with root page 0. Arguments are strings, identifiers,
  or numbers. The module supplies column names. `SELECT`, `rowid`, and joins read
  the rows the module returns, with integers normalized to `BigInt` and blobs copied.
- A missing module, a `sqlite_` table name, a duplicate name, a row-width mismatch,
  an unsupported value, a thrown module error, and more than 100,000 rows fail
  without changing the committed image. `IF NOT EXISTS` leaves the existing table.
  Reopening the image reads the same rows after the module is registered again.
- Column declarations, `xCreate`/`xConnect`/`xDisconnect`/`xDestroy`, constraint
  translation, hidden columns, transaction hooks, and `generate_series` are not
  implemented. JSON, FTS, and R-tree remain absent.
- Verification on Dart 3.13.7/Linux x64: `dart format` for the touched files,
  `dart analyze --fatal-infos` on `sqlite_plus`, and 9,643 engine tests pass.
  ORM and generator suites were not re-run; this change does not touch them.
  Native oracles were not re-run.

## 2026-10-27 — M8 item 2: virtual table lifecycle

- `xCreate` runs once for `CREATE VIRTUAL TABLE` and can reject the statement
  before any schema row is written. `xConnect` and `xDisconnect` bracket each
  read, including a read whose module throws. `xDisconnect` does not remove the
  schema row. `xDestroy` runs for `DROP TABLE` and removes only that virtual
  table; a real neighbor table and a second virtual table stay readable.
- Dropping a virtual table whose module is not registered on that connection
  fails and leaves the schema row. A thrown `xDestroy` also leaves the row.
- Column declarations, constraint translation, hidden columns, transaction hooks,
  and `generate_series` are still absent.
- Verification on Dart 3.13.7/Linux x64: format, fatal-info analysis, and 9,644
  engine tests pass. ORM, generator, and native oracles were not re-run.

## 2026-10-27 — M8 item 3: virtual table cursor

- A module can override `xOpen` and return a `VirtualTableCursor`. The scan calls
  `filter`, then `rowid` and `column` until `eof`, then `next`. `close` runs
  even when `filter` throws, and it runs before `xDisconnect`.
- Modules that only implement `read` keep working through the default cursor.
  Custom rowids pass through to SQL. A cursor rejects `filter`, `next`, `eof`,
  `column`, and `rowid` after `close`. An empty filter produces no rows.
- Constraint arguments, hidden columns, transaction hooks, and `generate_series`
  are still absent.
- Verification on Dart 3.13.7/Linux x64: format, fatal-info analysis, and 9,645
  engine tests pass. ORM, generator, and native oracles were not re-run.

## 2026-10-27 — M8 items 4–12: constraints, hidden columns, series

- `bestIndex` receives equality and range comparisons. A module marks the ones
  it consumes. `LIKE` and any comparison the module does not mark stay on a
  full scan, and SQL still applies every predicate.
- Hidden columns are absent from `SELECT *` and readable by name. A declared
  column list must match the module, including `HIDDEN`. `CREATE` arguments are
  delivered to the cursor.
- `SELECT ... FROM module(args)` opens an eponymous module. A real table, a
  named virtual table, or a module that is not eponymous rejects that call.
- `xBegin`, `xCommit`, and `xRollback` follow the image transaction. Rollback
  removes the virtual schema row and the ordinary insert together. `DROP TABLE`
  on a virtual table leaves a neighbor table and its index. A missing module
  does not change the image. Reopen sees the virtual table; a `sqlite_` name is
  rejected.
- `generate_series` implements the documented start/stop/step rules: omitted
  start is 0, omitted stop is 4294967295, omitted step is 1, a zero step yields
  no rows, NULL converts as integer zero, and int64 addition stops on overflow.
  Python's sqlite3 here is 3.45.1 and was built without `generate_series`. The
  pinned 3.53.1 library is not installed, so no new pinned oracle was generated.
- A closed cursor and an out-of-range column raise `SqlException` and leave the
  connection usable. A thrown `xCommit` marks the connection failed.
- Verification on Dart 3.13.7/Linux x64: format, fatal-info analysis, and 9,654
  engine tests pass. ORM, generator, and native oracles were not re-run.

## 2026-10-27 — M8 items 13–22: JSON and JSONB

- Added the JSON scalar and aggregate functions present in SQLite 3.53.1,
  including `json`/`jsonb`, `json_valid` flags 1–15, `json_type`,
  `json_error_position`, `json_extract`, `->`/`->>`, array/object/length,
  insert/replace/set/remove/patch, `json_quote`, and both group functions.
  `json_each` and `json_tree` are eponymous table functions on the virtual-table
  cursor. An integer arrow path is an array index; numeric text is an object label.
- `json()` renders a SQL real with the 17-digit value text. `json_quote`,
  `json_array`, and `json_object` keep the 15-digit form. JSON subtype survives
  a scalar subquery and is cleared when a derived table or CTE stores the value.
- A constant `json_each(...)` join matches the pinned rows. `json_each(column)`
  raises `Virtual table argument must be constant` because relations are loaded
  before the join. SQLite 3.53.1 evaluates that correlated call. `json_pretty`
  is not implemented.
- JSON text larger than 1 MiB is rejected. That is the SQL tokenizer cap;
  SQLite's default `SQLITE_MAX_LENGTH` is 1 GB. Depth 1000 succeeds and 1001
  fails. Function output larger than 16 MiB fails. A raw NUL inside JSON text
  is malformed; the `\u0000` escape is preserved.
- `MappedField.at(path)` emits `json_extract` with the path bound. A consumer
  test filters rows without putting a SQL string in the application, and a
  separate test checks the emitted SQL.
- The oracle has 714 cases across UTF-8, UTF-16le, and UTF-16be. It was
  generated by a SQLite 3.53.1 CLI whose `sqlite_source_id()` matches the pin.
  That CLI reports `COMPILER=gcc-13.3.0`, while `manifest.json` records
  `COMPILER=clang-22.1.3`. The generator records the difference and does not
  rewrite the manifest or the other oracles. CI runs `--verify`, which checks
  the checksum and does not execute SQLite.
- Verification on Dart 3.13.7/Linux x64: format, fatal-info analysis, 10,374
  engine tests, and 160 ORM tests pass. Generator tests were not re-run.
  Native schema, journal, and WAL oracles were not re-run. M8 is not complete:
  FTS and R-tree are still absent.

## 2026-10-27 — M8 items 23–50: FTS and R-tree

- FTS5 reads native shadow tables and writes one segment per document.
  unicode61 and ascii follow the pinned token rules. unicode61 is not an Arabic
  stemmer: Arabic letters stay one token under both tokenizers.
- A bound column `MATCH` is FTS text, not extra SQL. A bare operator and a bare
  quote are syntax errors. Result order follows bm25 on the pinned cases. One
  single-document score is within 1e-12 of -1e-6. highlight and snippet match
  the pinned window.
- `CREATE VIRTUAL TABLE ... USING fts5` writes the shadow tables. INSERT,
  UPDATE, and DELETE rebuild the index. Content, contentless, and
  contentless-delete each create, search, and delete. A contentless table
  without `contentless_delete` rejects UPDATE and DELETE before the image
  changes. External content shows the live table text, and `MATCH` stays stale
  until `INSERT INTO e(e) VALUES('rebuild')`.
- Unimplemented FTS5 options and commands, FTS3/FTS4 CREATE and INSERT, extra
  R-tree dimensions, RETURNING, INSERT SELECT, ORDER/LIMIT, WITH, and
  INDEXED BY fail before the image changes.
- FTS3 and FTS4 native images open. Parenthesized `MATCH` is evaluated from
  stored content. Writes raise `FTS3 and FTS4 writes are not implemented`.
- R-tree accepts one to five dimensions and trailing auxiliary columns.
  Coordinates are float32. Queries scan the leaves and let SQL filter them.
  Insert, update, and delete images pass `PRAGMA integrity_check` on the pinned
  CLI. Geopoly area, json, overlap, and within match the pinned polygons,
  including a corrupt input that returns NULL. Overlap is not claimed beyond
  those polygons.
- The search oracle has 42 replay cases and six FTS3/FTS4 images across UTF-8,
  UTF-16le, and UTF-16be. It was generated by a SQLite 3.53.1 CLI whose
  `sqlite_source_id()` matches the pin. That CLI reports `COMPILER=gcc-13.3.0`,
  while `manifest.json` records `COMPILER=clang-22.1.3`. The generator does not
  rewrite the manifest. CI runs `--verify`, which checks the JSON checksum and
  each image checksum and does not execute SQLite. Dart tests that shell out to
  the CLI skip when the binary is absent.
- `MappedTable.search` binds the text and orders by rank. `Bounds.intersects`
  binds four comparisons. The application tests do not embed that SQL.
- Multi-page FTS5 leaves, porter, trigram, detail, tokendata, and locale are
  not implemented. `json_pretty` is still absent. Correlated `json_each` is
  unchanged.
- Verification on Dart 3.13.7/Linux x64: format, fatal-info analysis, 10,438
  engine tests, and 163 ORM tests pass. Generator tests were not re-run.
  Native schema, journal, and WAL oracles were not re-run. macOS, Windows,
  Android, iOS, and the browser were not run. No new benchmark numbers were
  collected. M9 and items 51–108 remain open. This is not a claim of full
  SQLite FTS or R-tree support.

## 2026-10-27 — Items 51–76: connection schema and page writes

- TEMP tables, indexes, views, and triggers live in a connection image.
  `exportImage` omits them, and reopen does not see them. An unqualified name
  resolves temp, then main, then the one attached schema. `CREATE` without
  TEMP still writes main when a temp table has the same name.
- `ATTACH ':memory:'` accepts one extra database. A file path uses the
  optional `attachFile` callback. The limit is 64 MiB. Duplicate names,
  `main`, `temp`, a second attachment, a missing file, and a missing reader
  are rejected. `DETACH` of a missing name is rejected. One statement that
  mutates two schemas throws `cross-database statement is not supported`
  before a partial write. A cross-schema SELECT is assembled in a scratch
  image. Temp and attached images are not a second durable journal. A
  transaction snapshots main, temp, and the attached image together.
- `journal_mode` reads header byte 18. Writing the current mode is a no-op.
  `memory`, `off`, `delete`, `persist`, `truncate`, and a rollback/wal switch
  throw before the bytes change. A write-version 2 image is not opened for a
  query. `cache_size` defaults to -2000, `busy_timeout` to 0, and
  `synchronous` to 2. Those values do not change `exportImage`. `auto_vacuum`
  reads 0. A write throws `auto_vacuum is not implemented`. A non-zero largest
  root page fails at open.
- `createCollation` registers one connection-local text collation. The test
  covers ORDER BY, UNIQUE, and an index. REINDEX of a custom collation name
  has no separate oracle. EXPLAIN QUERY PLAN returns column `detail` from this
  engine. EXPLAIN bytecode throws. Two or three comma joins with ORDER BY and
  sqlite_stat1 counts can be reordered; the compared result is the rows. A
  covering index reads fewer pages than a query that returns a table column.
  `sqlite_stat4` throws at open. Double quotes stay identifiers.
- The gap ledger has 25 UTF-8 cases generated by the SQLite 3.53.1 CLI whose
  `sqlite_source_id()` matches the pin. That CLI reports `COMPILER=gcc-13.3.0`,
  while `manifest.json` records `COMPILER=clang-22.1.3`. The generator does
  not rewrite the manifest. CI runs `--verify`, which checks the checksum and
  does not execute SQLite. Matches are replayed. Recorded differences are DQS
  (`SELECT "missing"` is the string on the CLI and `No such column` here),
  `json_pretty`, EXPLAIN bytecode, `journal_mode` memory/off, `auto_vacuum`,
  a cross-database insert, the fresh `journal_mode` name (`rollback` here,
  `memory` on the CLI's `:memory:` database), and EXPLAIN QUERY PLAN text.
- `SqlErrorCode` is `constraint`, `syntax`, or `missingTable`. The messages
  are not claimed to be SQLite's text. Record decoding rejects UTF-8 byte
  0xFF, an unpaired UTF-16 surrogate, and an odd UTF-16 length.
- A rowid insert that splits a page, a delete that empties the tree, and a
  same-length overflow update pass `PRAGMA integrity_check` on the pinned CLI.
  The file does not shrink. Freed pages stay on the freelist and are reused,
  so a delete followed by an insert of the same size keeps `page_count`. A
  non-key update leaves an expression index and a partial index byte-identical.
  A key change uses the compact rebuild, and the new key is visible. Crash
  recovery during the incremental insert, delete, and overflow update restores
  the previous rollback image. A WAL commit of one row recovers that row after
  a crash on the next insert. WITHOUT ROWID, views, and triggers keep their
  existing writers. An auto-vacuum file is rejected at open.
- `benchmark_results/page_writes_linux_x64.json` is an AOT sample from this
  revision on Dart 3.13.7 / Linux x64. Three batch inserts of 10,000 rows took
  268581, 275709, and 288941 microseconds. One batch insert of 100,000 rows
  took 2686614 microseconds. Counting those rows took 37662, 38107, and 43315
  microseconds after 10,000 rows, and 376886 microseconds after 100,000 rows.
  Two hundred single-row inserts took 296606 microseconds. Peak RSS was
  214040576 bytes. No pre-change binary was available, so no delta is claimed.
  One hundred thousand single-row inserts were not run.
- `json_pretty`, correlated `json_each`, and the FTS/R-tree limits recorded
  for items 23–50 are unchanged. M8 stays checked for that subset only. M9
  stays open. Items 77–108 were not started.
- Verification on Dart 3.13.7/Linux x64: format, fatal-info analysis,
  10,488 engine tests, and 163 ORM tests pass. Generator
  tests were not re-run. Native schema, journal, and WAL oracles were not
  re-run. macOS, Windows, Android, iOS, and the browser were not run.

## 2026-10-27 — Items 77–82: unpromised browser storage

- `openBrowserStorage` looks up OPFS, then IndexedDB, through
  `dart:js_interop`. The IndexedDB database is `sqlite_plus` version 1 and
  the object store is `files`. Production dependencies do not include WASM or
  native SQLite. The package SDK floor is 3.4.0 because `JSAny.isA` requires
  it. CI still runs Dart 3.13.7. On this Linux VM the conditional import
  selects the stub and returns null.
- `OpenedStorage.capabilities` exposes `canRead`, `canWrite`,
  `durabilityPromised`, and `placement`. Memory and browser placements both
  set `durabilityPromised` to false. `requireWritable` rejects a read-only
  flag and a browser flag that claims power-loss durability. The caller reads
  the flag. It does not infer durability from the class.
- A missing interface, including the stub and a null probe, returns a new
  `MemoryStorageBackend` with `StoragePlacement.memory`. Close, then open,
  has length 0. A probe that throws propagates.
- The round trip uses `MemoryBrowserByteStore`. That store is an in-process
  map. It is not OPFS and it is not durable. Close, then open, returns
  `SELECT body` equal to `kept`. Bytes stay local until `sync`, and the store
  keeps its own copy. Empty names and names containing `/`, `\`, or NUL are
  rejected. `BrowserStorageBackend` does not implement
  `DurableStorageBackend`. Power loss is not claimed.
- `dart compile js tool/browser_storage_compile.dart` compiles the web file.
  The compiled JavaScript was not executed. Chrome was not run. CI compiles
  that file and does not run it.
- `BrowserDatabaseConnection` uses the public engine API only. The ORM test
  saves notes 1 `kept` and 2 `other`, filters with
  `where(MappedField.equalTo('kept'))`, closes, reopens, and filters again.
  A missing probe leaves the next memory open at length 0. The test file
  contains no SQL string.
- `json_pretty`, correlated `json_each`, the FTS/R-tree limits, and the
  items 51–76 contracts are unchanged. M8 stays checked for its earlier
  subset only. M9 stays open. Items 83–108 were not started. macOS, Windows,
  Android, iOS, and Chrome were not run.
- Verification on Dart 3.13.7/Linux x64: format, fatal-info analysis,
  10,496 engine tests, and 165 ORM tests pass. That includes 8 tests in
  `browser_storage_test` and 2 tests in `browser_connection_test`.
  `dart compile js tool/browser_storage_compile.dart` succeeded. The compiled
  JavaScript was not executed. Generator tests were not re-run. Native
  schema, journal, and WAL oracles were not re-run. Chrome, macOS, Windows,
  Android, and iOS were not run.

## 2026-10-27 — Items 83–90: platform rows

- The Linux x64 gate was reprinted on Dart 3.13.7. Format and fatal-info
  analysis passed. `dart test` printed 10,496 engine tests, 165 ORM tests,
  and 48 generator tests. The pinned SQLite CLI was present for the engine
  run, so the native integrity tests ran. These counts are Linux x64 only.
- `markTestSkipped` does not stop a test by itself. The six tests that need
  `/tmp/sqlite-build/sqlite3` now return after the skip. With
  `SQLITE_PLUS_SQLITE3` pointed at a missing path, those six skipped and the
  other tests in the two files passed. GitHub runners do not have that CLI,
  so those six skip there.
- Chrome on this Linux machine ran the ORM page. The captured log is
  `packages/sqlite_plus_orm/tool/chrome_orm_linux_x64.log`. Its page text is:

```
placement=browser
canRead=true
canWrite=true
durabilityPromised=false
saved=2
before=kept
reopenPlacement=browser
reopenDurabilityPromised=false
reopenBody=kept
result=pass
```

  The browser line in that file is `Google Chrome 156.0.8078.47`. The Dart
  line is `Dart SDK version: 3.13.7 (stable) (Thu Oct 22 14:28:57 2026 -0700) on "linux_x64"`.
  `durabilityPromised` stayed false. Power loss is not claimed.
- GitHub Actions job `desktop` runs format, fatal-info analysis, and
  `dart test` for the three packages on `macos-latest` and `windows-latest`
  with Dart 3.13.7. The result of each job is that platform's result. It is
  not copied from Linux.
- Android was not run. `flutter` and `adb` are absent, and this machine has
  no Android SDK, emulator, or device.
- iOS was not run. This machine is Linux and has no Mac. The macOS CI job is
  a macOS Dart VM, not an iOS device or simulator.
- M8 stays checked for its earlier subset only. M9 stays open. Items 91–108
  were not started. `json_pretty` and the other recorded limits are unchanged.

## 2026-10-27 — Items 99–107, with performance tests deferred

- Items 91–98 stay deferred. No scale-benchmark numbers were recorded.
- GitHub Actions run 40487224654, head `9989846`, passed all three packages on
  `macos-latest`. The six pinned-CLI integrity tests skip there. The same run
  failed `windows-latest` for `sqlite_plus` and `sqlite_plus_generator`.
  `sqlite_plus_orm` passed. The engine failure was `PathAccessException` errno
  32 in `database_owner` tearDown. The generator failures compared LF output
  with CR LF golden text and process stdout. This revision retries that delete
  and compares LF. Linux `database_owner_test.dart` passed 9 tests. A Windows
  pass is not recorded. Linux counts are not copied to either desktop OS.
- `@DbEntity(module:)` accepts `fts5` or `rtree`. `@DbJson()` emits `path`.
  The FTS query extension emits `search`. The R-tree field helper emits
  `bounds`. `ensureCreated` writes `CREATE VIRTUAL TABLE`. FTS and R-tree
  writers reject `RETURNING`, so a tracked save reads the row back. A second
  `plan()` is empty when that SQL still matches.
- `example/models.dart` passes generator `--check`. The compiled consumer in
  `packages/sqlite_plus_generator/test/search_consumer_test.dart` imports only
  `sqlite_plus_orm`, contains no SQL text, and saves, searches, and reads one
  JSON note, one FTS article, and one R-tree place.
- Linux Dart 3.13.7: format and fatal-info analysis passed for the three
  packages. `dart test` printed 10,496 engine tests, 167 ORM tests, and 53
  generator tests. The pinned SQLite CLI was present, so the native integrity
  tests ran. Native schema, journal, and WAL generators were not re-run.
  Linux CI `--verify` still checks those checksums and fails the job on a
  mismatch. It does not execute SQLite. The desktop jobs do not run it.
- Root `LICENSE` is MIT. Package versions stay `0.0.1-dev.1`. `CHANGELOG.md`
  lists the verified subset and the open limits, including DQS, `json_pretty`,
  EXPLAIN bytecode, STAT4, `auto_vacuum`, cross-database writes, journal-mode
  switches, power loss, Android, iOS, and the deferred performance items.
- M8 stays checked for its earlier subset only. M9 stays unchecked. Item 108
  stays open.

## 2026-10-27 — Items 91–98, capped at 10000 rows

- The measurement ceiling is 10000 rows. `sizes_not_run` is `[100000,1000000]`
  because those sizes were not run.
- `packages/sqlite_plus_orm/benchmark/scenarios_10k.dart` rejects a row count
  outside 1 through 10000. The package test calls it with 2 rows, 1 sample,
  and `includeFile` false. That test checks the shape only. Its timings are
  not published.
- The published file is `benchmark_results/scenarios_10k_linux_x64.json`,
  written by the AOT executable on Linux x64. SDK
  `3.13.7 (stable) (Thu Oct 22 14:28:57 2026 -0700) on "linux_x64"`. Hostname
  `cursor`. OS
  `Linux 6.12.94+ #1 SMP PREEMPT_DYNAMIC Mon Oct 19 22:12:29 UTC 2026`.
  Runtime `AOT executable`. Peak RSS `220463104`.
- Cold is the first measured SQL query after the fill in the same process.
  Warm is the next repetition of that query. Population variance is the
  integer floor of `sum((sample - mean)^2) / sample_count`. Rows per second
  is `(rows_touched * 1000000) ~/ microseconds`.
- Memory SQL, three samples, microseconds: insert
  `[2601012,2518356,2478439]`, point cold `[3699,846,594]`, point warm
  `[1111,437,418]`, range cold `[66375,50091,48456]`, range warm
  `[71440,53338,51313]`, update `[737057,663964,693884]`, delete
  `[790531,535159,515625]`. Image bytes `[98304,98304,98304]`.
- Memory ORM, three samples, microseconds: track `[7784,5962,11470]`, save
  `[2934430751,3092578591,2700874993]`, point cold `[552,633,3074]`, point
  warm `[441,450,524]`, range cold `[151407,165494,221424]`, range warm
  `[140809,139628,147875]`, update `[713464555,644367619,642860919]`, delete
  `[639607004,680642252,602419455]`. The file's rows per second for that
  update and delete are `[0,0,0]`. Image bytes `[102400,102400,102400]`. The
  ORM image includes `_sqlite_plus_orm_model`.
- File SQL ran on a pre-created rollback journal. Insert microseconds
  `[1941990,1996109,2015981]`, point cold `[573,648,606]`, point warm
  `[586,521,404]`, file bytes `[98304,98304,98304]`, journal bytes
  `[8720,8720,8720]`. `directoryEntriesDurable` true is a caller attestation.
  Power loss was not measured.
- This is not macOS, Windows, Android, iOS, or a native SQLite comparison.
  No earlier binary was measured, so no delta is claimed.
- Linux ORM `dart test` printed 169 passed. Format and fatal-info analysis
  passed for `sqlite_plus_orm`. Engine 10,496 and generator 53 were not
  re-run. Native schema, journal, and WAL generators were not re-run.
- Versions stay `0.0.1-dev.1`. M8 stays checked for its earlier subset only.
  M9 stays unchecked. Item 108 stays open. macOS and Windows results for this
  head are not recorded yet.

## 2026-10-27 — Windows file lock after a failed owner open

- GitHub Actions run 40494640309, head `e320528`, passed all three packages on
  `macos-latest`. The engine job printed 10490 passed and 6 skipped. ORM
  printed 167. The generator printed 53. The six skips are the pinned CLI
  integrity tests. These counts are macOS only.
- The same run passed `windows-latest` for `sqlite_plus_orm` (167) and
  `sqlite_plus_generator` (53). `sqlite_plus` printed 10489 passed, 1 failed,
  and 6 skipped. The failure is
  `database_owner_test.dart` "stale shared-memory and missing sidecars fail
  without creation". tearDown raised `PathAccessException` errno 32 on the
  temp directory after 20 retries of 50 ms. The six skips match the macOS
  CLI skips. These counts are Windows only.
- A failed `DatabaseOwner.open` used to `Isolate.kill` as soon as the isolate
  reported the error, which is before its `finally` closes the file. The open
  path now waits for that isolate to exit, and kills it only if exit exceeds
  5 seconds. The stale-sidecar test then takes the same byte-range lock the
  owner uses. Linux `database_owner_test.dart` passed 9 tests. Linux
  `dart test` for `sqlite_plus` printed 10496 passed. The pinned SQLite CLI
  was present, so the native integrity tests ran. A Windows pass is not
  recorded until the next `windows-latest` job for this head.
- M9 stays unchecked. Item 108 stays open.

## 2026-10-27 — Publish preparation, not a publication

- The repository is a Dart workspace. The root `pubspec.yaml` is
  `sqlite_plus_workspace` with `publish_to: none`. The three packages use
  `resolution: workspace`. The ORM depends on `sqlite_plus: ^0.0.1-dev.1` and
  the generator depends on `sqlite_plus_orm: ^0.0.1-dev.1`. Analyzer `6.4.1`
  and `dart_style` `2.3.6` stay exact. The lockfile is
  the root `pubspec.lock`. Package lockfiles are removed. The SDK constraint
  is `>=3.6.0 <4.0.0`. Workspace resolution requires language version 3.5 or
  newer, and this tree uses 3.6. CI `dart pub get --enforce-lockfile` runs
  from the repository root.
- Each package has `LICENSE`, `CHANGELOG.md`, `README.md`, and an `example/`.
  `publish_to: none` is absent from the three packages. The root workspace
  stays unpublished. Version stays `0.0.1-dev.1`. Nothing was uploaded to
  pub.dev.
- `packages/sqlite_plus/example/library_tour.dart` binds `json_object`, rolls
  back a third card, highlights an FTS5 match, matches `مرحبا`, selects the
  R-tree shelf inside the unit box, sets `user_version` to 7, and reopens
  the exported image. The program printed `Kept Garden`, 320 pages,
  `a garden [kept] in the margin`, `Arabic Shelf`, two cards, place 1,
  version 7, and 40960 image bytes.
- `packages/sqlite_plus_orm/example/reading_log.dart` saves two books, renames
  one, and reads the JSON shelf through `MappedField.at`. The renamed book is
  revision 1. `Other Atlas` stays at revision 0. The idle save reports 0.
  The application does not write SQL.
- `packages/sqlite_plus_generator/example/library_app.dart` saves ten rows
  through `generatedModel`: one customer, three purchases, two notes, two
  articles, and two places. The filter keeps totals `22.5` and `30.0`. The
  JSON path, FTS search, and R-tree bounds each return one row. The
  application imports `sqlite_plus_orm` only.
- Generator tests locate `.dart_tool/package_config.json` by walking up to
  the workspace root.
- Linux Dart 3.13.7: format and fatal-info analysis passed. `dart test`
  printed 10497 engine tests, 170 ORM tests, and 54 generator tests. The
  pinned SQLite CLI was present, so the native integrity tests ran. These
  counts are Linux x64 only. macOS and Windows results for this head are not
  recorded. The Windows file-lock fix still waits for a `windows-latest` job.
- `dart pub publish --dry-run` reported 0 warnings for `sqlite_plus` and
  `sqlite_plus_orm`. `sqlite_plus_generator` reported 2 warnings because
  `analyzer` 6.4.1 and `dart_style` 2.3.6 stay exact. Nothing was uploaded.
- M9 stays unchecked. Item 108 stays open. This preparation is not a 1.0
  release and it is not a pub.dev upload.

## 2026-10-27 — Desktop CI for the failed-open fix

- GitHub Actions run 40538509306, head `7afaaba`, completed on the push to
  `cursor/sqlite-conformance-orm-31c1`. The same commit also had pull-request
  run 40538517281. The counts below are from the push run's own jobs.
- `ubuntu-latest`: engine 10490 passed and 6 skipped, ORM 169 passed,
  generator 53 passed. The six skips are the pinned CLI integrity tests.
  The GitHub runner does not have that CLI. This is separate from the local
  Linux run that had the CLI and printed 10496 engine tests for that commit.
- `macos-latest`: engine 10490 passed and 6 skipped, ORM 169 passed,
  generator 53 passed. The six skips are the same pinned CLI tests.
- `windows-latest`: engine 10490 passed and 6 skipped, ORM 169 passed,
  generator 53 passed. The six skips are the same pinned CLI tests.
  `database_owner_test.dart` "stale shared-memory and missing sidecars fail
  without creation" passed. The Windows engine summary was logged at
  2026-10-27 18:15 Asia/Gaza.
- These counts are for `7afaaba` only. They are not counts for later heads.
  M9 stays unchecked. Item 108 stays open.

## 2026-10-27 — An example project for each package

- `packages/sqlite_plus/example`, `packages/sqlite_plus_orm/example`, and
  `packages/sqlite_plus_generator/example` are workspace members. Each has
  `publish_to: none`, `pubspec.yaml`, `lib/`, `bin/main.dart`, `test/`, and
  `README.md`. They are not published.
- The engine tour, the ORM reading log, and the generated library app moved
  into those projects. The package test that used to import each file moved
  with it. `example/lib/models.dart` is the generator input that passes
  `--check`.
- Linux Dart 3.13.7: format and fatal-info analysis passed for the three
  packages and the three examples. Package `dart test` printed 10496 engine
  tests, 169 ORM tests, and 53 generator tests. The pinned SQLite CLI was
  present. Each example printed 1 test passed, and `dart run bin/main.dart`
  printed the tour, the reading log, and the generated library. These counts
  are Linux x64 only.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-27 — Public pages describe the follow-up as planned work

- The repository README, package READMEs, example READMEs, changelogs,
  `docs/REFERENCE.md`, and `docs/ENGINE_SUPPORT.md` describe the next SQL
  surface, FTS extensions, collations, durable browser storage, Android, iOS,
  power-loss durability, larger benchmarks, and publication as planned work.
- The compatibility matrix and this log keep the test record. Publication
  still waits for an explicit request. M9 stays unchecked. Item 108 stays open.

## 2026-10-27 — README pages lead with the working examples

- The repository README, the three package READMEs, and the three example
  READMEs now lead with the SQL surface, the reading log, and the generated
  library. The code blocks follow `library_tour.dart`, `reading_log.dart`,
  `models.dart`, and `library_app.dart`, including the lines those programs
  print. Follow-up work stays in a Planned section.
- This is a documentation change. No package test was re-run for it. The
  compatibility matrix is unchanged. Publication still waits for an explicit
  request. M9 stays unchecked. Item 108 stays open.

## 2026-10-27 — README tables and an Android emulator probe

- The repository README, the three package READMEs, and the three example
  READMEs were reorganized around tables: package roles, example output, SQL
  surface, ORM calls, generator mappings, and the planned follow-up.
- Flutter 3.47.8 (Dart 3.13.7) built a debug APK that imports `sqlite_plus`
  and `sqlite_plus_orm`. It ran on emulator 37.2.12.0, image
  `system-images;android-35;aosp_atd;x86_64`, Android 15, ABI `x86_64`.
  Nested KVM raised `kvm_arch_vcpu_create`, so the emulator used `-accel off`.
- The logcat line at 2026-10-27 18:04:23.330 is stored in
  `packages/sqlite_plus/tool/android_probe_api35_x86_64.log`. Memory SQL,
  the ORM revision save, and `DatabaseOwner` on the app cache path all
  returned the values in that file.
- `flutter build ios` is not a subcommand of Flutter 3.47.8 on this Linux
  host. No iOS simulator ran. M9 stays unchecked. Item 108 stays open.
  Nothing was uploaded to pub.dev.

## 2026-10-28 — Margin, a notes application on the ORM

- `examples/notes` is a Flutter application. It is outside the pub workspace.
  `Note` is mapped with `Column` and `EntityType`. `NoteStore` uses
  `DbContext`, `ensureCreated`, and `saveChanges`. The file is an
  `exportImage` snapshot named `margin.db`.
- Linux, Flutter 3.47.8, Dart 3.13.7: `flutter analyze --fatal-infos` reported
  no issues. `flutter test` passed 6 tests. Four are store tests, including a
  save that reopens from the image, a blank draft, pin order, and search. Two
  are widget tests for the desk and the editor.
- `flutter build apk --release` produced a fat APK. The committed copy is
  `examples/notes/dist/margin-notes.apk`, sha256
  `a09263e40b4b0053de152610b0ea15ca178b0371b315c698332d22508f930f15`.
  It is signed with the Android debug certificate. The application id is
  `dev.sqliteplus.margin_notes`.
- That APK was installed on the API 35 x86_64 emulator, image
  `system-images;android-35;aosp_atd;x86_64`, emulator 37.2.12.0, `accel off`,
  fingerprint `Android/sdk_slim_x86_64/emu64x:15/AE3A.240806.019/12368160:userdebug/test-keys`.
  Logcat reported `Displayed dev.sqliteplus.margin_notes/.MainActivity` at
  2026-10-28 06:11:48 Asia/Hebron. A note titled `Kept` with body `Garden`
  was saved from the editor. After `am force-stop` and a new start, the same
  note was on the desk.
- This is one release APK on that emulator. It is not a physical device.
  `flutter build ios` is still not a subcommand on this Linux host. M9 stays
  unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-28 — Split the Margin release packages by ABI

- Pull request 5 was merged to `main` at 2026-10-28 06:18 Asia/Hebron,
  commit `733a029`.
- `flutter build apk --split-per-abi --release` replaced
  `examples/notes/dist/margin-notes.apk` with three packages:
  `margin-notes-arm64-v8a.apk` (19604707 bytes, versionCode 2001, sha256
  `dca40bf3e8ad6749ce7fc5e6ada4d4fb443d1f0026105c94009e592082e1f912`),
  `margin-notes-armeabi-v7a.apk` (17138749 bytes, versionCode 1001, sha256
  `a289bbd04ea9a87886c2be35c40658b8025566e25ce20573c891794ba2a232e8`),
  and `margin-notes-x86_64.apk` (21096170 bytes, versionCode 4001, sha256
  `fdbd71a7add699a8b08d7aebb44f583a52ec37102bfc2f551a6d2e1befe97ade`).
  Each is signed with the Android debug certificate.
- `adb install -r` of the x86_64 package succeeded on the same API 35
  emulator. Logcat reported `Displayed dev.sqliteplus.margin_notes/.MainActivity`
  at 2026-10-28 06:20:49 Asia/Hebron. The note titled `Kept` with body
  `Garden` was still on the desk. The arm64-v8a and armeabi-v7a packages
  were built and checked as zip archives with one native ABI each. They
  were not installed on a device. M9 stays unchecked. Item 108 stays open.
  Nothing was uploaded to pub.dev.

## 2026-10-28 — Margin tools: random insert, delete, details, VACUUM

- The tools screen inserts a chosen count of random notes through `DbSet.add`
  and `saveChanges`. One mode saves the whole batch in one `saveChanges`
  transaction. The other calls `saveChanges` once per note and reopens the
  context between notes. The work runs in `Isolate.spawn`. The result reports
  wall time, process CPU time from `/proc/self/stat` at 100 ticks per second,
  and process RSS before, at the sampled peak, and after. Delete-all removes
  every tracked note in one `saveChanges`. VACUUM runs through
  `DbContext.connection.execute('VACUUM')` and the screen shows page count,
  freelist, image bytes, and note count before and after. The details page
  shows the file path, file and image sizes, page and freelist counts, schema
  names, and the loaded rows.
- Linux, Flutter 3.47.8, Dart 3.13.7: `flutter analyze --fatal-infos` reported
  no issues. `flutter test` passed 12 tests.
- `flutter build apk --split-per-abi --release` replaced the three packages:
  `margin-notes-arm64-v8a.apk` 19932467 bytes, sha256
  `f6ccf637e49873b9b9a9df0e0abd9bb7427d48f4009f778f44a06b00fc6459a1`;
  `margin-notes-armeabi-v7a.apk` 17466509 bytes, sha256
  `c8c289bcdb516d475f6bc04daee598ddde11d7b9a0afc72eb504646af783ddce`;
  `margin-notes-x86_64.apk` 21423930 bytes, sha256
  `d918346a52b2762638618d9f0e7f9743d3e0629a9bc7222b43fa1f4e45112fc9`.
- `adb install -r` of the x86_64 package succeeded on the same API 35
  emulator. Logcat `Displayed` at 2026-10-28 07:03:34 Asia/Hebron. The tools
  screen exposed the insert count, the transaction switch, delete-all,
  details, and VACUUM. The details page showed
  `/data/user/0/dev.sqliteplus.margin_notes/app_flutter/margin.db`, 3 pages,
  tables `notes` and `_sqlite_plus_orm_model`, and the note `Kept`. The
  arm64-v8a and armeabi-v7a packages were checked as zip archives. They were
  not installed on a device. M9 stays unchecked. Item 108 stays open.
  Nothing was uploaded to pub.dev.

## 2026-10-28 — saveChanges batches inserted rows

- Each statement on `MutableSqliteDatabase` loads the image and writes a new
  one. `saveChanges` was doing that once per added row for the `INSERT`, again
  for the read-back, and again for every tracked row after the writes.
  `benchmark_results/scenarios_10k_linux_x64.json` records that earlier shape
  for 10000 assigned-key rows: ORM save microseconds
  `[2934430751,3092578591,2700874993]`, 3 rows per second. That file stays the
  record of its own workload.
- `saveChanges` now reads trigger names from `sqlite_schema` once. Added rows
  on a table with no trigger are written with multi-row
  `INSERT ... RETURNING`. A statement stops before 20000 parameters or 900000
  bytes of SQL text, and the next rows start another statement. `RETURNING` is
  the stored row when that table has no trigger. A written table that has a
  trigger still inserts one row and reads it back, so a later child sees the
  post-trigger key. If a written or deleted table has a trigger, or a delete
  or update can cascade, set null, or set default, each tracked table is read
  once. Other saves leave unchanged tracked rows in place.
- The AOT measurement is `benchmark_results/orm_save_batch_linux_x64.json`.
  Generated-key notes have title, body, pinned, updated, and tint. Samples 3.
  SDK `3.13.7 (stable) (Thu Oct 22 14:28:57 2026 -0700) on "linux_x64"`.
  Hostname `cursor`. OS
  `Linux 6.12.94+ #1 SMP PREEMPT_DYNAMIC Mon Oct 19 22:12:29 UTC 2026`.
  Runtime `AOT executable`. For 1000 rows, save microseconds
  `[255251,242615,242029]`, rows per second `[3917,4121,4131]`, variance
  `37203686`, image bytes `[65536,65536,65536]`. For 10000 rows, save
  microseconds `[4047036,4028665,4055493]`, rows per second `[2470,2482,2465]`,
  variance `125417341`, image bytes `[557056,557056,557056]`. Peak RSS
  `127545344`. This is Linux x64, not a phone, and not a delta against
  `scenarios_10k_linux_x64.json`.
- Linux `dart analyze --fatal-infos` reported no issues for
  `sqlite_plus_orm`. `dart test` printed 173 passed. Engine and generator
  suites were not re-run. `examples/notes` `flutter analyze --fatal-infos`
  reported no issues and `flutter test` passed 12 tests.
- `flutter build apk --split-per-abi --release` replaced the three packages.
  Byte lengths stayed the same and the hashes changed:
  `margin-notes-arm64-v8a.apk` 19932467 bytes, sha256
  `4a7e0b9be88f9e44898c0e3345f60833fd048ccae5cd9eb4e3db52ae07957aa7`;
  `margin-notes-armeabi-v7a.apk` 17466509 bytes, sha256
  `e7c47e1006489b85b582b96c02a52c09e2e8b3e27a2ba1f89d903bf93ffbf0f2`;
  `margin-notes-x86_64.apk` 21423930 bytes, sha256
  `226279e1672cb2c15caadaa3dd01477174bff19dcffd8e484539f7d1df4eaf54`.
  The arm64 `libapp.so` contains the `sqlite_schema` trigger lookup. These
  packages were not installed on a device.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-28 — Resident rows, one DELETE, live process page

- Ordinary writes on the main database reuse the loaded rows. The byte image
  is rebuilt when it is exported, queried, or when the statement cannot stay
  deferred. Expression indexes, generated columns, triggers, views, journals,
  and `REINDEX`, `ANALYZE`, and `VACUUM` still publish an image immediately.
  A commit checks foreign keys. A database with no foreign key does not scan
  every row again at `COMMIT`.
- Inserts keep the unique-key sets for the current rows and add the new key.
  An insert does not sort the existing rows. `saveChanges` of many plain
  deletes sends one `DELETE`. A single-column key uses `IN`. A group that
  covers every stored row sends `DELETE FROM` that table. A plain delete
  rebuilds the row list once when the table has no trigger and nothing
  references it.
- Separate note saves still use one `saveChanges` transaction per note and
  reopen the context. They do not rebuild the image on every note. The
  isolate exports once at the end. The off position of the tools switch is
  not a path with zero transactions.
- Margin updates the open list in memory after save, pin, and delete. The
  tools screen opens القياسات. That page samples process RSS and CPU every
  half second, and the button stays available while a job is running. CPU
  time comes from `/proc/self/stat` at 100 Hz and can exceed 100%. The
  numbers are the whole process.
- Linux `dart analyze --fatal-infos` reported no issues for `sqlite_plus`
  and `sqlite_plus_orm`. `dart test` printed 10500 engine tests passed and
  176 ORM tests passed. `examples/notes` `flutter analyze --fatal-infos`
  reported no issues and `flutter test` passed 14 tests.
- The AOT file `benchmark_results/orm_save_batch_linux_x64.json` was measured
  again on this revision. Same workload, three samples. SDK
  `3.13.7 (stable) (Thu Oct 22 14:28:57 2026 -0700) on "linux_x64"`.
  Hostname `cursor`. OS
  `Linux 6.12.94+ #1 SMP PREEMPT_DYNAMIC Mon Oct 19 22:12:29 UTC 2026`.
  Runtime `AOT executable`. For 1000 notes, save microseconds
  `[116381,100751,102062]`, rows per second `[8592,9925,9797]`, variance
  `50116598`, image bytes `[65536,65536,65536]`. For 10000 notes, save
  microseconds `[1296964,1305441,1291381]`, rows per second `[7710,7660,7743]`,
  variance `33412557`, image bytes `[557056,557056,557056]`. Peak RSS
  `120561664`. This is Linux x64, not a phone.
  `scenarios_10k_linux_x64.json` remains its own workload.
- `benchmark_results/resident_ops_linux_x64.json` is the separate-save and
  delete measurement. Same SDK, host, OS, and AOT runtime. Three samples.
  Separate saves of 100 notes, microseconds `[29936,30029,26834]`, rows per
  second `[3340,3330,3726]`, variance `2204342`, then one export
  `[7741,7768,7903]`, image bytes `[20480,20480,20480]`. Separate saves of
  1000 notes, `[270601,273341,274021]`, rows per second `[3695,3658,3649]`,
  variance `2185155`, export `[75242,73071,73519]`, image bytes
  `[65536,65536,65536]`. One delete among 1000 notes, save
  `[26700,25815,25780]`, export `[72327,73403,72295]`, image bytes
  `[65536,65536,65536]`. Delete-all of 1000, save `[51755,48187,50418]`,
  rows per second `[19321,20752,19834]`, variance `2166172`, export
  `[318,315,316]`, image bytes `[12288,12288,12288]`. Delete-all of 10000,
  save `[1662591,1682367,1700757]`, rows per second `[6014,5944,5879]`,
  variance `242880648`, export `[364,371,335]`, image bytes
  `[12288,12288,12288]`. Peak RSS `221724672`. This is not a phone
  measurement. One delete still rewrites the image when the file is saved.
- `flutter build apk --split-per-abi --release` replaced the three packages.
  Flutter signs them with the debug keystore. Application id
  `dev.sqliteplus.margin_notes`. `margin-notes-arm64-v8a.apk` 19932467 bytes,
  versionCode 2001, sha256
  `d00defb81b1738895a6393ae09e312c1d5e1e3cade0b0927d5f4e735a6b28a3c`;
  `margin-notes-armeabi-v7a.apk` 17482893 bytes, versionCode 1001, sha256
  `fa3af6ff193d6e39dc433b508e0353b083ee064d2f55743c71ae716c2b1383f8`;
  `margin-notes-x86_64.apk` 21489466 bytes, versionCode 4001, sha256
  `23eac4b2e30a237116440ddaab14c6281369082809874a4a79254607f523fe1e`.
  The arm64 `libapp.so` contains `live-metrics`. These packages were not
  installed on a device.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-28 — ميزان, native SQLite beside sqlite_plus

- `examples/compare` is a Flutter application, `publish_to: none`, and not a
  workspace member. Android SQLite is opened with `sqflite` in that
  application. The sqlite_plus packages were not changed and were not
  retested as a suite.
- Both engines run the same statements on `bench(id, name, body, n)`. The
  count is 1 through 10000. Separate inserts are autocommit. A transaction
  uses `BEGIN`/`COMMIT` on sqlite_plus and one `sqflite` transaction on
  Android. Search creates `bench_name` during preparation, then measures
  `SELECT id FROM bench WHERE name = ?`. sqlite_plus work runs in an
  isolate. `exportImage` is timed beside the statement interval. The screen
  samples process RSS and CPU during a run.
- Linux Flutter 3.47.8, Dart 3.13.7: `flutter analyze` reported no issues
  and `flutter test` passed 13 tests. The sqlite_plus engine checks used 1,
  3, and 4 rows. The widget checks used scripted engines. `sqflite` was not
  opened on Linux.
- `flutter build apk --split-per-abi --release` wrote three packages, signed
  with the debug keystore. Application id `dev.sqliteplus.engine_bench`.
  `bench-arm64-v8a.apk` 19473455 bytes, versionCode 2001, sha256
  `954adf7e5327bce9a39b5a3320024919514409328fc3f7f93c47091cfd033281`;
  `bench-armeabi-v7a.apk` 16974725 bytes, versionCode 1001, sha256
  `b10f346424d1d548b078391b0bd7fb1421e29e909bf3874cd4b1dc50d8d8b0df`;
  `bench-x86_64.apk` 20964918 bytes, versionCode 4001, sha256
  `5ac8989c3588f3f6632989b2327b549d50c9dadcdfe8dc0733555aa2310ceb34`.
- The x86_64 package was installed on the API 35 emulator,
  `ro.build.version.release` 15, ABI `x86_64`, model
  `Android ATD built for x86_64`, fingerprint
  `Android/sdk_slim_x86_64/emu64x:15/AE3A.240806.019/12368160:userdebug/test-keys`.
  `adb install -r` succeeded. Logcat `Displayed` at 2026-10-28 08:21:28.549
  emulator UTC, so 10:21:28 Asia/Hebron.
- One measured pair, 20 rows, إدراج بمعاملة. The screen showed نتيجة متطابقة,
  20 rows, sum 210, and 20 hits on both engines. Android SQLite 262.1 ms,
  sqlite_plus 975.4 ms, ratio 3.72. Native file 16.0 KB. sqlite_plus image
  8.0 KB and export 125 µs. Log stamps 08:23:14 and 08:23:16 emulator UTC,
  so 10:23:14 and 10:23:16 Asia/Hebron. This is one run on that image, not a
  repeated sample, not a physical phone, and not iOS. The other two ABIs
  were not installed.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-28 — same-rowid update and unqualified delete

- A phone log in ميزان, 1000 rows, Asia/Hebron 10:40–10:43, showed sqlite_plus at 74.333 s for separate updates, 43.956 s for one bulk update, and 17.411 s for separate deletes. Checksums on that phone matched the native engine. This change addresses those three statement shapes.
- A same-rowid `UPDATE` replaces that row and moves unique keys. `DELETE` whose comparison is only a rowid alias and an integer reads that row. `DELETE FROM` with no `WHERE` clears the row list. `changes()` still counts every removed row. `UPDATE OR REPLACE`, a rowid change, triggers, foreign keys, `CHECK`, `NOT NULL`, and `RETURNING` keep their existing paths.
- `packages/sqlite_plus`: `dart format --output=none --set-exit-if-changed .` and `dart analyze --fatal-infos` passed. `dart test` passed 10512 tests. The package example passed analysis, its test, and `dart run bin/main.dart`.
- `examples/compare`: `flutter analyze` reported no issues and `flutter test` passed 13 tests. Those tests do not open `sqflite`.
- Linux x64 JIT, Dart 3.13.7, not AOT, not a phone, two samples of 1000 rows and no secondary index. After the bulk update the checksum was 1000 rows and sum 501500. After the per-row update it was 1000 rows and sum 502500. After each delete it was 0 rows and sum 0. Bulk update 55 ms then 52 ms. Separate update 646 ms then 625 ms. `DELETE FROM` 1 ms then 1 ms. Separate delete 118 ms then 136 ms.
- The phone was not run again. Search, primary-key reads, and `VACUUM` were not part of this measurement.
- `flutter build apk --split-per-abi --release` wrote three packages, debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0. `bench-arm64-v8a.apk` 19473455 bytes, versionCode 2002, sha256 `ec881d9cc8982a42b672010106a237182a40c39570e00182bdbd653b663ebad6`. `bench-armeabi-v7a.apk` 16991109 bytes, versionCode 1002, sha256 `79db3b2c6bd671a00d39ba1b156dc856d279601c2a0b83be77617deeb23b2bf4`. `bench-x86_64.apk` 20964918 bytes, versionCode 4002, sha256 `21715d0753636f7444c5247de864cefed602c3faffa65a4a5bbdc4951f3c5233`. None of these three files was installed here.
- M9 stays unchecked. Nothing was uploaded to pub.dev.

## 2026-10-28 — English Bench and Margin, a copied log, and faster statements

- A phone log from Bench versionCode 2002, Asia/Hebron 12:50 on 2026-10-28, had the shape of a 1000-row run. The cards did not print the count. Checksums matched. Separate insert was 306.9 ms native and 104.6 ms sqlite_plus, ratio 0.34. Transaction insert was 67.1 ms and 99.5 ms, ratio 1.48. Separate update was 309.5 ms and 133.8 ms, ratio 0.43. Bulk update was 662 µs and 46.8 ms, ratio 70.64. Search was 98.1 ms and 573.9 ms, ratio 5.85. Point lookup was 114.3 ms and 172.2 ms, ratio 1.51. `VACUUM` was 1.1 ms and 62.4 ms, ratio 57.16. Deletes were not in those two screenshots. This change addresses the statements that were still slower on that phone.
- `UPDATE table SET column = column + integer`, with no `WHERE` and an `INT` declared type, stores one addend for that column. The next read or export applies it, and a second increment adds to the same addend. Rollback restores the addend. The measured statement does not walk the rows.
- A repeated `INSERT INTO table(columns) VALUES (?,?,...)` that includes the rowid, has no unique index, and uses `ABORT` policies keeps a plan and skips the parser. `SELECT` equality on live rows uses the rowid or a binary value index. `VACUUM` leaves the byte image untouched when every table is a view, virtual, rowid-aliased, `WITHOUT ROWID`, indexed, or empty, and the freelist is empty. The following read rebuilds that image.
- `DELETE FROM table` clears the row list. A table whose `CREATE` text has no `NOT`, `UNIQUE`, `CHECK`, `REFERENCES`, `DEFAULT`, `COLLATE`, `AUTOINCREMENT`, `GENERATED`, or `CONSTRAINT`, and which has no secondary index, puts the old pages on the freelist before the statement returns. The bench table declares `NOT NULL`, so that publish is skipped and the next read rebuilds the image. `changes()` is the removed row count, and a second delete of an empty table reports 0.
- Bench and Margin are English and left to right. The IBM Plex Sans Arabic font stays. Bench has Copy log, which puts the whole log on the clipboard, oldest entry first, including each comparison.
- `packages/sqlite_plus`: `dart format --output=none --set-exit-if-changed .` and `dart analyze --fatal-infos` passed. `dart test` passed 10513 tests. The package example passed analysis, its test, and `dart run bin/main.dart`.
- `examples/compare`: `flutter analyze` reported no issues and `flutter test` passed 14 tests. Those tests do not open `sqflite`. `examples/notes`: `flutter analyze` reported no issues and `flutter test` passed 14 tests.
- Linux x64, Dart 3.13.7, JIT, not AOT and not a phone. Two samples of 1000 rows and no secondary index. Transaction insert 23993 µs and 23542 µs. Bulk update, after one warmup, 20 calls: medians 13 µs and 13 µs, minimums 12 µs and 11 µs, maximums 136 µs and 231 µs. After 21 increments the checksum was 1000 rows and sum 521500. Point lookup 26557 µs and 26452 µs, 1000 hits. Search 11809 µs and 11566 µs, 1000 hits. `VACUUM` 38 µs and 50 µs, checksum 1000 rows and sum 500500. `DELETE FROM bench` in a fresh process was 908 µs and 951 µs. Warmed repeats in those same two processes were 81, 54, 29, 112, 40 µs and 203, 45, 80, 77, 69 µs. The checksum read after the first delete took 23697 µs and 22037 µs and returned 0 rows and sum 0. That read is outside the measured statement. An empty `DELETE FROM bench` was 8 µs and 14 µs, with `changes()` 0. Separate update and separate delete were not remeasured in this pass.
- The phone was not run again. Nothing here is an AOT or device measurement.
- `flutter build apk --split-per-abi --release` wrote three Bench packages, debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0, launcher Bench. `bench-arm64-v8a.apk` 19604515 bytes, versionCode 2003, sha256 `d59caf7a6e974feae0ace5e632aec1220a2758b694b34bb61093e4738803a1d9`. `bench-armeabi-v7a.apk` 17105789 bytes, versionCode 1003, sha256 `7c76a676f75ac2b65cb696f5a26db61182c5bb8c38bb3117519251b68789d639`. `bench-x86_64.apk` 21095978 bytes, versionCode 4003, sha256 `a8114ec97ea6a2162a0efa22ddebe11e72c6744da0a881a2ebe50524f27a8ca4`.
- The same command wrote three Margin packages, application id `dev.sqliteplus.margin_notes`, versionName 1.0.0, launcher Margin. `margin-notes-arm64-v8a.apk` 19997995 bytes, versionCode 2002, sha256 `ae7a1dc46cc33476398fbdb80c6e5625440b8473e7fec8f478592e0471dbc73f`. `margin-notes-armeabi-v7a.apk` 17548421 bytes, versionCode 1002, sha256 `69b004720dc0d4041f28edaf2590ca0a5f224d857006d2eb5214ecbc994e7aae`. `margin-notes-x86_64.apk` 21489458 bytes, versionCode 4002, sha256 `49b46413b93f36362ba3c98875b7e68a70a4ba3ab7c9d85877825d8b0d8c8961`.
- None of these six packages was installed here.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-28 — 1000-row Bench sample

- One 1000-row sample of the arm64 Bench package, versionCode 2003. Every pair matched. The charts are `packages/sqlite_plus/doc/bench-time.png` and `packages/sqlite_plus/doc/bench-size.png`. The other two ABIs of this build were not part of this sample.
- Separate insert: native 514.9 ms, sqlite_plus 6.5 ms, ratio 0.01. Rows 1000, sum 500500, hits 1000. Prepare 510 µs and 2.8 ms. Export 0 µs and 3 µs. Size 36.0 KB and 28.0 KB. CPU 430.0 ms and 20.0 ms. Memory 171.38 MB → 177.42 MB and 177.79 MB → 178.40 MB.
- Transaction insert: 104.6 ms and 3.5 ms, ratio 0.03. Rows 1000, sum 500500, hits 1000. Prepare 483 µs and 986 µs. Export 0 µs and 3 µs. Size 36.0 KB and 28.0 KB. CPU 130.0 ms and 0 µs. Memory 182.86 MB → 185.34 MB and 185.33 MB → 185.33 MB.
- Separate update: 508.2 ms and 247.5 ms, ratio 0.49. Rows 1000, sum 501500, hits 1000. Prepare 166.1 ms and 4.2 ms. Export 0 µs and 4 µs. Size 36.0 KB and 28.0 KB. CPU 450.0 ms and 370.0 ms. Memory 188.16 MB → 189.14 MB and 188.55 MB → 189.17 MB.
- Bulk update: 1.3 ms and 92 µs, ratio 0.07. Rows 1000, sum 501500, hits 1000. Prepare 134.5 ms and 4.0 ms. Export 0 µs and 3 µs. Size 36.0 KB and 28.0 KB. CPU 0 µs and 0 µs. Memory 191.61 MB → 191.61 MB and 191.41 MB → 191.54 MB.
- Search: 126.3 ms and 7.6 ms, ratio 0.06. Rows 1000, sum 500500, hits 1000. Prepare 109.2 ms and 107.6 ms. Export 0 µs and 4 µs. Size 52.0 KB and 44.0 KB. CPU 160.0 ms and 10.0 ms. Memory 194.11 MB → 197.14 MB and 197.37 MB → 197.37 MB.
- Point lookup: 116.2 ms and 9.6 ms, ratio 0.08. Rows 1000, sum 500500, hits 1000. Prepare 184.7 ms and 4.4 ms. Export 0 µs and 3 µs. Size 36.0 KB and 28.0 KB. CPU 150.0 ms and 10.0 ms. Memory 199.83 MB → 202.65 MB and 202.64 MB → 202.64 MB.
- VACUUM: 1.2 ms and 9 µs, ratio 0.01. Rows 1000, sum 500500, hits 1. Prepare 114.7 ms and 4.8 ms. Export 0 µs and 3 µs. Size 36.0 KB and 28.0 KB. CPU 0 µs and 0 µs. Memory 182.77 MB → 182.82 MB and 182.80 MB → 182.80 MB.
- Separate delete: 352.7 ms and 168.0 ms, ratio 0.48. Rows 0, sum 0, hits 1000. Prepare 90.9 ms and 3.0 ms. Export 0 µs and 1 µs. Size 16.0 KB and 8.0 KB. CPU 230.0 ms and 220.0 ms. Memory 185.20 MB → 187.22 MB and 187.20 MB → 187.22 MB.
- Delete all: 732 µs and 105 µs, ratio 0.14. Rows 0, sum 0, hits 1000. Prepare 155.2 ms and 4.5 ms. Export 0 µs and 2 µs. Size 16.0 KB and 8.0 KB. CPU 10.0 ms and 0 µs. Memory 189.58 MB → 189.58 MB and 189.25 MB → 189.25 MB.
- In each pair the native figure is given first and the sqlite_plus figure second. These are the on-screen intervals from that one log. No engine code changed for this record.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — Bench file round writes the real file

- Each Bench operation already runs twice: both engines in memory, then both engines on a file. VersionCode 2005 opened `bench-sqlite-plus.db`, but a hot autocommit change set the live rows dirty and returned without `commitImage`. `close()` rebuilt the memory image and did not write it. The measured file round was therefore still a memory change.
- An autocommit hot change on a rollback journal now serializes, commits that image, and only then publishes it. The file bytes match `exportImage()` before `close()`. A transaction still waits for `COMMIT`, which is inside the measured interval. Memory databases have no journal, so their hot path is unchanged.
- `packages/sqlite_plus`: `dart format --output=none --set-exit-if-changed .` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10514 tests.
- `examples/compare`: `flutter analyze` reported no issues and `flutter test` passed 17 tests. One test reopens the sqlite_plus file after separate insert and after bulk update and reads the same checksum. Those tests do not open `sqflite`.
- `flutter build apk --split-per-abi --release` wrote three Bench packages, debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0, launcher Bench. `bench-arm64-v8a.apk` 19604515 bytes, versionCode 2006, sha256 `8277620f7fc8f46815bdcd2da2a657fd87f555746aa8e808ddc11b7c3d584b8e`. `bench-armeabi-v7a.apk` 17154941 bytes, versionCode 1006, sha256 `85ae690596a25e56e37404312adf106769f7ede0fe51003ef6d3e89fc961778b`. `bench-x86_64.apk` 21161514 bytes, versionCode 4006, sha256 `291c5d01040cb486ce43773d4dee0cf9b4d9e17324d24ca298f480b764815598`.
- None of these three packages was installed here.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — Changed-page file commits

- A phone log for Bench versionCode 2006, Asia/Hebron 11:31–11:34 on 2026-10-29, matched every checksum. File separate insert was 44.267 s, separate update 87.311 s, and separate delete 45.269 s. Memory separate update was 325.3 ms against native 135.3 ms, and memory separate delete was 164.6 ms against native 101.8 ms. Each autocommit had been rebuilding the whole image and journaling every page.
- A rollback commit now journals and writes only pages whose bytes differ, plus pages removed when the file shrinks. Recovery overlays those before-images onto the current file and truncates back to the saved page count. The journal is synced once after its header is valid, the database is synced after the new pages, and the invalidated header is synced before the commit returns.
- One appended row, one replaced row, or one deleted row of an ordinary rowid table is written into the existing leaves. A full rightmost leaf splits onto a new page. A bulk integer addend rewrites the leaves that hold that column. Anything else, including a secondary index, still uses the compact rebuild. `UPDATE table SET column = column + integer WHERE rowid = ?` and `DELETE FROM table WHERE rowid = ?` on a simple table skip the planner.
- `packages/sqlite_plus`: `dart format .` and `dart analyze --fatal-infos` passed. `dart test` passed 10517 tests.
- `examples/compare`: `flutter analyze` reported no issues and `flutter test` passed 17 tests. Those tests do not open `sqflite`.
- Linux x64, Dart 3.13.7, JIT, not AOT and not a phone. Two processes of 1000 `bench` rows. Memory separate insert 23970 µs and 39064 µs. Memory separate update 25721 µs and 43306 µs. Memory separate delete 9747 µs and 15437 µs. Memory bulk update 383 µs and 656 µs. Memory `DELETE FROM bench` 748 µs and 835 µs. File separate insert 1315418 µs and 2293980 µs. File separate update 1884763 µs and 1950286 µs. File separate delete 2080859 µs and 1561274 µs. File bulk update 10267 µs and 13398 µs. File `DELETE FROM bench` 3202 µs and 6234 µs. The file statements still sync the journal, the database, and the journal invalidation. This is not a phone measurement and not a comparison with sqflite.
- `flutter build apk --split-per-abi --release` wrote three Bench packages, debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0, launcher Bench. `bench-arm64-v8a.apk` 19670051 bytes, versionCode 2007, sha256 `43ba38f30313fab89b2108d4e0f16afdab6d696a800af36061411bf98ec18efd`. `bench-armeabi-v7a.apk` 17220477 bytes, versionCode 1007, sha256 `bd8001a24cb4507ce3899de659fb65805122cbbdc58b3f1111d342a52a28649f`. `bench-x86_64.apk` 21227050 bytes, versionCode 4007, sha256 `c477d11c4bd8c726301a6135cbf319db4399e7698a794079d86bb76df6e655a8`.
- None of these three packages was installed here.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — Bench file open without a loopback socket

- VersionCode 2004 stopped every sqlite_plus file operation on a phone with `SocketException: Failed to create server socket (OS Error: Operation not permitted, errno = 1, address = 127.0.0.1, port = 44098)`. Memory pairs on that phone still completed. `DatabaseOwner` binds that socket as a process lease.
- The bench file round now opens `RollbackJournalPager` in the bench isolate. The statements still commit to `bench-sqlite-plus.db` and its journal. No loopback socket is created. `directoryEntryIsDurable: true` remains the caller attestation after the empty image and journal are flushed. It is not a power-loss result.
- `examples/compare`: `flutter analyze` reported no issues and `flutter test` passed 16 tests. The file test ran all nine operations at 2 rows and matched the memory checksums. Those tests do not open `sqflite`. The engine suite was not re-run. No engine code changed.
- `flutter build apk --split-per-abi --release` wrote three Bench packages, debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0, launcher Bench. `bench-arm64-v8a.apk` 19604515 bytes, versionCode 2005, sha256 `f428e8935f0bae206a4a6de477a008f698faccfb9ec3cbc156f564e95c1358bc`. `bench-armeabi-v7a.apk` 17154941 bytes, versionCode 1005, sha256 `e36d6b8c59f035288ea7ccfa0c8601b25b142dedab30aadc01066eeb34717ff1`. `bench-x86_64.apk` 21161514 bytes, versionCode 4005, sha256 `f65b8b2be4ec28a7747bab82dd99caf52b253dd8ae4f1b04c22e1719b4c751f5`.
- None of these three packages was installed here.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — Bench memory pair and file pair

- Each Bench operation now runs twice. Memory opens both engines in memory. File opens both engines on a database file. Native memory is sqflite `:memory:` with `singleInstance: false`, and its size is `page_count * page_size`. Native file stays `bench-native.db`. sqlite_plus memory stays `MutableSqliteDatabase`, with `exportImage` timed beside the statement. sqlite_plus file is `DatabaseOwner` on `bench-sqlite-plus.db` with a rollback journal. The bench writes an empty image and an empty journal, flushes both, then passes `directoryEntriesDurable: true`. That flag is the caller attestation the file API requires. It is not a power-loss result. File export time is 0, and the size is the main file plus any sidecar.
- The earlier 1000-row table is native file against sqlite_plus memory. No new phone log was collected for the two pairs.
- `examples/compare`: `flutter analyze` reported no issues and `flutter test` passed 16 tests. The file test ran all nine operations at 2 rows and matched the memory checksums. Those tests do not open `sqflite`. The engine suite was not re-run. No engine code changed.
- `flutter build apk --split-per-abi --release` wrote three Bench packages, debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0, launcher Bench. `bench-arm64-v8a.apk` 19670051 bytes, versionCode 2004, sha256 `c43dcaf54a9a1ff2b22c81ce804c926b7a361ebe3e6351a56eb28ce69da19556`. `bench-armeabi-v7a.apk` 17269629 bytes, versionCode 1004, sha256 `a8121bdf0cfadbd217b5b785e836c7ca2d726106ecfdf3b43b7874a3fe8ab03c`. `bench-x86_64.apk` 21227050 bytes, versionCode 4004, sha256 `2536fb13b07d69f0cf645fcc4c9ff001e2a19716b4080a83473e517432a7ac46`.
- None of these three packages was installed here.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-28 — version 0.0.2

- Package versions are `0.0.2` in `sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator`. The ORM depends on `sqlite_plus: ^0.0.2`. The generator depends on `sqlite_plus_orm: ^0.0.2`.
- `0.0.1-dev.1` remains the earlier pub.dev upload. `0.0.2` is the release number for this tree.
- M9 stays unchecked. Item 108 stays open.
