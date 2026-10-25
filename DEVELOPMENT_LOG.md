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
