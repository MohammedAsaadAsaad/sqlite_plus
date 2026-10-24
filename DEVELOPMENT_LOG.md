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
