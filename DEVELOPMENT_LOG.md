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
