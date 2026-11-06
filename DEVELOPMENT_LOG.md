# Development log

## 2026-11-06 — Course chapters in the browser

- Learn SQL no longer opens with the introductory paragraph. Six chapters
  list their lessons, each chapter with its own icon. A lesson is a sequence
  of parts. Each part explains one idea, shows the example through `formatSql`
  and the SQL editor colors, and asks one question before the next part.
  Lesson questions follow the parts. Chapter questions open after every lesson
  in that chapter is passed, and they open the next chapter. The writing step
  is the SQL editor, so suggestions follow the tables in that step. There are
  sixteen lessons. An older `course.json` without version 2 is ignored.
- `browser/`: Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze
  --fatal-infos` reported no issues. `flutter test` passed 59 tests on 6
  November 2026.
- `flutter build apk --release --target-platform android-arm64` at 15:39
  Asia/Hebron (UTC+2) wrote
  `browser/dist/sqlite-plus-browser-arm64-v8a.apk`, 21381319 bytes, sha256
  `b75777b4d4f20ce4f7782677c531bdc3c1781aea8d09e6552371ce3d0969bde4`.
  `aapt dump badging` reports package `dev.sqliteplus.sqlite_plus_browser`,
  versionName `1.0.0`, versionCode `21`, minSdk `24`, targetSdk `36`,
  compileSdk `36`, application-label `SQLite Browser`, and native-code
  `arm64-v8a`. The release build is signed with the Android debug certificate.
  The package was not installed on a device or an emulator.

## 2026-11-06 — Explanations lead with the package

- Each package README opens on its own file example. The catalog page and the
  other packages are at the end of the engine page. Measured pages name the
  system and the result.
- The runnable examples write a file and read it back. On Linux x64, Dart
  3.13.7, the seven example suites passed.
- Published numbers: `sqlite_plus` 0.1.9, `sqlite_plus_orm` 0.1.9,
  `sqlite_plus_generator` 0.1.9, `sqlite_plus_arabic` 0.1.3,
  `sqlite_plus_vec` 0.1.3, `sqlite_plus_geo` 0.1.2, and
  `sqlite_plus_search` 0.1.0-dev.5.

## 2026-11-06 — Published the prepared packages

- pub.dev latest is `sqlite_plus` 0.1.8, `sqlite_plus_orm` 0.1.8,
  `sqlite_plus_generator` 0.1.8, `sqlite_plus_arabic` 0.1.2,
  `sqlite_plus_vec` 0.1.2, `sqlite_plus_geo` 0.1.1, and
  `sqlite_plus_search` 0.1.0-dev.4. The ORM, generator, and geo numbers
  carry the same library behavior as the previous publication and require
  the new engine or ORM constraint. Search is a pre-release.
- The two Android APKs are ignored by `*.apk`. The local files remain.

## 2026-11-05 — Unique-key append lands on the packed search

- The open branch that appends a new maximum key and refreshes the integrity
  sum is merged onto the packed-leaf engine. A term-packed leaf is rebuilt
  and packed again on the next edit, so the idx term stays with the leaf.
  An index whose idx terms are empty still edits the leaf in place.
- The JavaScript integrity sum no longer uses a 32-bit shift. A borrow is
  carried with division. `tool/platform_smoke.dart` passed on the Dart VM and
  on Node after `dart compile js`.
- Linux x64, Dart 3.13.7, AOT, not a phone. `dart compile exe` of
  `packages/sqlite_plus_search/benchmark/catalog_lookup.dart` indexed 20,000
  products in 12589506 µs. The image was 3391488 bytes and held 347 leaves.
  `بسكويت` returned 493 hits and 20 names in 27971 µs, then 28013 µs, and
  25379 µs at offset 320. Raw `MATCH` took 15033 µs. `biscuit` took 20282 µs,
  26254 µs, and 20635 µs. Raw `MATCH` took 16533 µs. The phone sample remains
  47.236 ms and was not measured again.
- `packages/sqlite_plus` `dart test` passed 10617 tests.
  `packages/sqlite_plus_search` `dart test` passed 62 tests.
  `packages/sqlite_plus_vec` `dart test` passed 5 tests.
  `examples/product_catalog` `flutter test` passed 12 tests.
  `dart analyze --fatal-infos` reported no issues for the engine and the
  search package.

## 2026-11-05 — Phone page at 47.236 ms, packages prepared for pub.dev

- One arm64 phone, catalog release 0.5.2, at 17:11 Asia/Hebron (UTC+2) on 5
  November 2026, showed `20 of 493 matches · 47.236 ms` for `بسكويت` on page
  1 of 25. The score on those titles was 3.965. The previous phone sample on
  0.5.1 was 472.000 ms for page 17.
- `sqlite_plus` is `0.1.8`. `sqlite_plus_search` is `0.1.0-dev.4` and depends
  on `sqlite_plus` ^0.1.8, `sqlite_plus_arabic` ^0.1.2, and `sqlite_plus_vec`
  ^0.1.2. The READMEs lead with that phone page and the Linux AOT samples.
  The packages were not uploaded. `sqlite_plus_arabic` 0.1.2 and
  `sqlite_plus_vec` 0.1.2 are already in this tree and are not on pub.dev yet.
  Publish the engine, then those two, then the search pre-release.

## 2026-11-05 — Packed FTS leaves keep a page search under 50 ms on Linux AOT

- The locked baseline is one leaf per product. On this Linux x64 machine, JIT
  and not a phone, 20,000 products and the query `بسكويت` returned 493 hits
  in 405 ms after `exportImage`, then 359 ms. The Arabic filter took 295 ms.
  Reopening took 296 ms and then 276 ms. `indexTable` took 36558 ms and the
  image was 4993024 bytes. Version 0.5.1+6 on a physical phone showed
  472.000 ms for page 17 of 25 of that query. Each page is a full search.
- Two or more documents are packed by term into leaves of at most 4050 bytes.
  The idx term is the first term on that leaf. A positive AND/OR of whole
  terms reads the covering leaves and one document-length blob, then ranks
  the hits. One document keeps the previous leaf bytes. An older catalog
  image with more than one empty idx term is rebuilt once on open and saved.
  A one-document image is left alone.
- The new sample is AOT on the same machine, `dart compile exe` of
  `packages/sqlite_plus_search/benchmark/catalog_lookup.dart`, not a phone.
  Indexing 20,000 products took 46879988 µs. The image was 3387392 bytes and
  held 347 leaves. `بسكويت` returned 493 hits and 20 names in 26967 µs, then
  20819 µs, and 25663 µs at offset 320. The raw `MATCH` took 18861 µs.
  `biscuit` took 19717 µs, 25481 µs, and 25621 µs, and its raw `MATCH` took
  20249 µs. Insert took 819240 µs. Those AOT searches are under 50 ms. A JIT
  run of the same program had a first `بسكويت` search of 54429 µs, so the
  under-50 figure is the AOT samples. The phone was not measured again.
- Pinned SQLite 3.53.1, source id
  `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`,
  opened that image. `PRAGMA integrity_check` returned `ok`, the FTS5
  `integrity-check` command completed, and `MATCH` of `"بسكويت"` and
  `"biscuit"` each returned 493 rows.
- `packages/sqlite_plus`: `dart analyze --fatal-infos` reported no issues and
  `dart test` passed 10613 tests. `packages/sqlite_plus_search`:
  `dart analyze --fatal-infos` reported no issues and `dart test` passed 62
  tests, including the pinned external-content check.
  `examples/product_catalog`: `flutter analyze --fatal-infos` reported no
  issues and `flutter test` passed 12 tests.
- `flutter build apk --release --target-platform android-arm64` at 16:58
  Asia/Hebron (UTC+2) on 5 November 2026 wrote
  `examples/product_catalog/dist/product-catalog-arm64-v8a.apk`, 19817049
  bytes, sha256 `66e14efeebfd7e33a93c7f8c6b4cb504213deb1071a48e012958b2de6995f165`.
  `aapt dump badging` reports package `dev.sqliteplus.product_catalog`,
  versionName `0.5.2`, versionCode `7`, minSdk `24`, targetSdk `36`,
  compileSdk `36`, application-label `Product catalog`, and native-code
  `arm64-v8a` only. The release build is signed with the Android debug
  certificate. The package was not installed on a device or an emulator.
  Opening a saved 20,000-product image from 0.5.1 rebuilds that index once.

## 2026-11-05 — Each result page is its own search

- A page loads 20 names. The line is how many this page loaded out of the
  full hit count, and the time of that search. Previous and next run the
  search for the other slice and replace the time.
- `examples/product_catalog`: `flutter analyze --fatal-infos` reported no
  issues and `flutter test` passed 12 tests. One test searches 25 names and
  checks that the first call returns 20 of 25, the next offset returns the
  other 5, and an offset past the end returns none. The widget test moves
  from page 1 to page 2 and back, and each page shows its own count.
- `flutter build apk --release --target-platform android-arm64` at 16:19
  Asia/Hebron (UTC+2) on 5 November 2026 wrote
  `examples/product_catalog/dist/product-catalog-arm64-v8a.apk`, 19751513
  bytes, sha256 `309313debceaab98d519ebc419b578996e5a8810592d68710b84d8196ddcab6e`.
  `aapt dump badging` reports package `dev.sqliteplus.product_catalog`,
  versionName `0.5.1`, versionCode `6`, minSdk `24`, targetSdk `36`,
  compileSdk `36`, application-label `Product catalog`, and native-code
  `arm64-v8a` only. The release build is signed with the Android debug
  certificate. The package was not installed on a device or an emulator.
  The saved index does not need to be rebuilt.

## 2026-11-05 — Search shows its time and pages the hits

- A search records one duration: the time until the hits come back. The result
  line is the hit count and that time. RSS, image size, and the activity list
  are not part of search. Twenty hits are on a page. Previous and next change
  the page without running search again.
- `examples/product_catalog`: `flutter analyze --fatal-infos` reported no
  issues and `flutter test` passed 11 tests. The new tests cover a 20-hit
  page, the short last page, a rejected page number, and a widget that moves
  from page 1 to page 2 and back while the recorded time stays the same.
- `flutter build apk --release --target-platform android-arm64` at 16:04
  Asia/Hebron (UTC+2) on 5 November 2026 wrote
  `examples/product_catalog/dist/product-catalog-arm64-v8a.apk`, 19751513
  bytes, sha256 `ff6280e9f6e072cc37b01ef9df79384c344a5301019a9ed97463709a4c42c705`.
  `aapt dump badging` reports package `dev.sqliteplus.product_catalog`,
  versionName `0.5.0`, versionCode `5`, minSdk `24`, targetSdk `36`,
  compileSdk `36`, application-label `Product catalog`, and native-code
  `arm64-v8a` only. The release build is signed with the Android debug
  certificate. The package was not installed on a device or an emulator.
  The saved index does not need to be rebuilt.

## 2026-11-05 — Catalog search returns instead of scanning every hit

- Keyword search no longer probes the source table once per hit. It loads the
  matched key rows with one `IN` list and checks those primary keys in one
  query. On the live image, a rowid `IN` list is a hash probe per id. A
  single `AND (column = ?)` filter is applied to those rows. Any other
  predicate still uses the ordinary planner.
- One FTS `MATCH` of a single full term can rank from the posting lists. The
  older path remains when that shape does not apply.
- The catalog looks up the shown names with one `IN` query and does not copy
  the database image before painting the hits.
- Linux x64, Dart 3.13.7, JIT, not AOT and not a phone. 20,000 products,
  10,000 Arabic and 10,000 English, `SearchTextAnalyzer(stemArabic: true)`,
  query `بسكويت`. `indexTable` took 36558 ms. `exportImage` took 1 ms and
  wrote 4993024 bytes. Search after that save, limit 20, took 405 ms and
  returned 493 hits. The next search took 359 ms. The same query with
  `language = ?` bound to `Arabic` took 295 ms and returned 493 hits.
  Reopening that image and searching took 296 ms, then 276 ms, both with 493
  hits. Before this mapping change, the same query on 1,000 Arabic names took
  8869 ms and then 8437 ms for 54 hits.
- `packages/sqlite_plus`: `dart analyze --fatal-infos` reported no issues and
  `dart test` passed 10611 tests. `packages/sqlite_plus_search`: `dart analyze
  --fatal-infos` reported no issues and `dart test` passed 62 tests.
  `examples/product_catalog`: `flutter analyze --fatal-infos` reported no
  issues and `flutter test` passed 9 tests.
- `flutter build apk --release --target-platform android-arm64` at 15:54
  Asia/Hebron (UTC+2) on 5 November 2026 wrote
  `examples/product_catalog/dist/product-catalog-arm64-v8a.apk`, 19751453
  bytes, sha256 `025e23c18423a325be038d9cd3838caa8c1663755426fdaeaceac24ba3650780`.
  `aapt dump badging` reports package `dev.sqliteplus.product_catalog`,
  versionName `0.4.0`, versionCode `4`, minSdk `24`, targetSdk `36`,
  compileSdk `36`, application-label `Product catalog`, and native-code
  `arm64-v8a` only. The release build is signed with the Android debug
  certificate. The package was not installed on a device or an emulator.
  The saved index from version code 3 does not need to be rebuilt.

## 2026-11-05 — Catalog is saved once; setup stays in the menu

- The first launch loads both product lists, builds the keyword index, and
  writes `product_catalog.sqlite` in the app's private files directory.
  Later launches open that image and start on search. The file is replaced
  only when Load products or Rebuild index is chosen from the top menu.
  Activity and the resource sample are in that menu too.
- `flutter analyze --fatal-infos` reported no issues and `flutter test` passed
  9 tests. One test saves an image, opens it, and searches without building
  the index again. The widget test prepares once, searches, then opens the
  same file in a second launch without reading the product list again.
- `flutter build apk --release --target-platform android-arm64` at 15:06
  Asia/Hebron (UTC+2) on 5 November 2026 wrote
  `examples/product_catalog/dist/product-catalog-arm64-v8a.apk`, 19751453
  bytes, sha256 `42fa6bddec67f5b7114ca02577af92045d8c602739a82ea3425a7830067e9a88`.
  `aapt dump badging` reports package `dev.sqliteplus.product_catalog`,
  versionName `0.3.0`, versionCode `3`, minSdk `24`, targetSdk `36`,
  compileSdk `36`, application-label `Product catalog`, and native-code
  `arm64-v8a` only. The release build is signed with the Android debug
  certificate. The package was not installed on a device or an emulator.

## 2026-11-05 — Catalog isolate, batches, and a simpler screen

- The catalog screen is a short phone layout: one status line, three figures,
  Arabic and English together, Load and Index side by side, then search.
  While a step runs, a progress bar shows how many products are done.
- Load, index, search, and the resource sample run on a background isolate.
  The interface isolate reads the asset text and sends at most 1,000 names
  per message. Each batch is committed before the next one starts. Indexing
  reads the source table 1,000 rows at a time, ordered by `rowid`, and sends
  progress back. A `WITHOUT ROWID` source is still loaded, then written in
  the same page size.
- Flutter 3.47.9, Dart 3.13.7, Linux x64: `flutter analyze --fatal-infos`
  reported no issues and `flutter test` passed 8 tests. `dart analyze
  --fatal-infos` and `dart test` in `packages/sqlite_plus_search` reported no
  issues and passed 62 tests, including a 1,001-row progress check.
- `flutter build apk --release --target-platform android-arm64` at 14:56
  Asia/Hebron (UTC+2) on 5 November 2026 wrote
  `examples/product_catalog/dist/product-catalog-arm64-v8a.apk`, 19620241
  bytes, sha256 `f03d26f3b6096cad307000e1fa3968a39f263b77f9ef2122271140b469c64abb`.
  `aapt dump badging` reports package `dev.sqliteplus.product_catalog`,
  versionName `0.2.0`, versionCode `2`, minSdk `24`, targetSdk `36`,
  compileSdk `36`, application-label `Product catalog`, and native-code
  `arm64-v8a` only. The release build is signed with the Android debug
  certificate. The package was not installed on a device or an emulator.
  iOS, macOS, Windows, and a browser build were not run.

## 2026-11-05 — Product catalog example

- `examples/product_catalog` is a Flutter app with the two 10,000-name lists as
  assets. Load products, Build search index, and Search run only when asked.
  Each step shows its own time, the database image before and after, and
  process RSS. The resource sample is outside the operation clock. Keyword
  search stems Arabic. There is no embedding model.
- Flutter 3.47.9, Dart 3.13.7, Linux x64, on the packages in this branch:
  `flutter analyze --fatal-infos` reported no issues and `flutter test` passed
  7 tests on 5 November 2026.
- A debug `flutter run -d linux` compiled from the append-engine working tree
  loaded 20,000 rows and searched. The Arabic query showed 20 of 493 hits. The
  search card read Time 673.840 ms, image 3.50 MB before and after, RSS 585.75
  MB to 643.35 MB, and peak RSS 751.64 MB, at about 14:25 Asia/Hebron (UTC+2).
  That is one debug sample, not an AOT benchmark of this branch.
- `flutter build apk --release --target-platform android-arm64` at 14:36
  Asia/Hebron (UTC+2) on 5 November 2026 wrote
  `examples/product_catalog/dist/product-catalog-arm64-v8a.apk`, 19423641
  bytes, sha256 `4c70b2d03af38bd42a76b2173de40654724bfda6542a3158123acd7b4ceaf382`.
  `aapt dump badging` reports package `dev.sqliteplus.product_catalog`,
  versionName `0.1.0`, versionCode `1`, minSdk `24`, targetSdk `36`,
  compileSdk `36`, application-label `Product catalog`, and native-code
  `arm64-v8a` only. Both product lists and the IBM Plex Sans Arabic fonts are
  in the archive. The release build is signed with the Android debug
  certificate, SHA-256
  `f0cc4aecf5b1af9dbd2d0cae5d319fe4c00762a67fafdf8b8a5cee8e1d318b60`. The
  package was not installed on a device or an emulator. iOS, macOS, Windows,
  and a browser build were not run.

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

## 2026-10-29 — Margin arm64 package versionCode 2003

- `examples/notes` pubspec build number is 3, so the arm64 split versionCode is 2003. That package is the changed-page engine. The armeabi-v7a and x86_64 files in `examples/notes/dist` were left at versionCodes 1002 and 4002.
- `flutter analyze` reported no issues. `flutter test` passed 14 tests.
- `flutter build apk --release --split-per-abi --target-platform android-arm64` wrote one package, debug keystore, application id `dev.sqliteplus.margin_notes`, versionName 1.0.0, launcher Margin. `margin-notes-arm64-v8a.apk` 19997995 bytes, versionCode 2003, sha256 `97569a908d994269899bf43d9f7f9d5c5d9856ab728fb67b65aa678329131aeb`.
- This package was not installed here.
- The Bench arm64 package already on main is `bench-arm64-v8a.apk` 19670051 bytes, versionCode 2007, sha256 `43ba38f30313fab89b2108d4e0f16afdab6d696a800af36061411bf98ec18efd`. It was not rebuilt for this note and was not installed here.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — One redo sync per file commit

- A phone log for Bench versionCode 2007, Asia/Hebron 12:17 on 2026-10-29, matched every checksum. File separate insert was 1.403 s against native 494.9 ms, ratio 2.84. File separate update was 1.671 s against 504.6 ms, ratio 3.31. File bulk update was 16.9 ms against 740 µs, ratio 22.87. File separate delete was 2.082 s against 541.4 ms, ratio 3.85. File delete all was 4.6 ms against 1.6 ms, ratio 2.95. File transaction insert was 110.5 ms against 133.7 ms. File search, point lookup, and VACUUM, and the memory pairs, were faster than native on that log. Each autocommit had synced the journal, the database, and the journal invalidation.
- A file commit now appends after-images of the changed pages and syncs that redo once. The database pages are written before the call returns. They are synced when the redo passes 256 KiB or the pager closes. Restart applies the last complete redo, then clears the log. A torn tail is ignored. A bad header throws and does not write. The redo magic is `SQREDO`, not an official SQLite journal header. Another SQLite library cannot apply this log. Direct file storage uses synchronous writes, so the phone path does not wait on an event-loop turn for each syscall.
- An integer addend is stored in the existing cell when the serial width stays the same. One leaf that does not fit is rewritten on its own. `DELETE FROM` on a table whose root is the highest catalog root clears that root. An emptied non-root leaf is unlinked onto the freelist. A secondary index still uses the compact rebuild.
- `packages/sqlite_plus`: `dart format --output=none --set-exit-if-changed .` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10517 tests.
- `examples/compare`: `flutter analyze` reported no issues and `flutter test` passed 17 tests. Those tests do not open `sqflite`.
- Linux x64, Dart 3.13.7, JIT, not AOT and not a phone. One sample of 1000 `bench` rows. After the bulk update the checksum was 1000 rows and sum 502500. After delete all it was 0 rows and sum 0. Memory insert 26802 µs, update 28252 µs, bulk 422 µs, separate delete 13919 µs, delete all 929 µs. File with `flushSync`: insert 888231 µs, update 866649 µs, bulk 5235 µs, separate delete 812255 µs, delete all 432 µs. File without `flushSync`: insert 69291 µs, update 85535 µs, bulk 3706 µs, separate delete 120562 µs, delete all 100 µs. The `flushSync` sample counted 12031 writes and 4255 syncs across insert, update, bulk, delete, a reseed, and delete all. This is not a phone measurement and not a comparison with sqflite.
- `flutter build apk --release --split-per-abi --target-platform android-arm64` wrote one Bench package, debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0, launcher Bench. `bench-arm64-v8a.apk` 19670051 bytes, versionCode 2008, sha256 `85752b8b449977acbcfb241c8cb1833f041f624862a3094d34047429eaec83ca`. The armeabi-v7a and x86_64 files in `examples/compare/dist` remain versionCodes 1007 and 4007.
- This package was not installed here. The bench file size is taken before close, so it includes the redo, which can remain up to 256 KiB.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — Phone log for versionCode 2008, and the other packages

- One 1000-row sample of the arm64 Bench package, versionCode 2008, Asia/Hebron 13:11 on 2026-10-29. Every pair matched. Native is first. File separate insert 398.4 ms and 434.3 ms, ratio 1.09, size 36.0 KB and 108.3 KB, sum 500500. File transaction insert 128.5 ms and 101.6 ms, ratio 0.79, size 64.2 KB. File separate update 533.6 ms and 460.6 ms, ratio 0.86, size 124.4 KB, sum 501500. File bulk update 1.1 ms and 11.0 ms, ratio 10.41, size 88.3 KB, sum 501500. File search 169.6 ms and 9.9 ms, ratio 0.06, size 124.3 KB. File point lookup 139.8 ms and 9.8 ms, ratio 0.07, size 64.2 KB. File VACUUM 896 µs and 16 µs, ratio 0.02, hits 1, size 64.2 KB. File separate delete 491.3 ms and 537.1 ms, ratio 1.09, rows 0, sum 0, size 136.5 KB. File delete all 14.1 ms and 403 µs, ratio 0.03, rows 0, sum 0, size 52.2 KB. Memory separate insert 90.6 ms and 2.7 ms. Memory transaction insert 125.1 ms and 4.3 ms. Memory separate update 115.9 ms and 14.3 ms. Memory bulk update 1.0 ms and 69 µs. Memory search 141.3 ms and 10.0 ms. Memory point lookup 130.2 ms and 12.5 ms. Memory VACUUM 882 µs and 55 µs. Memory separate delete 121.1 ms and 8.9 ms. Memory delete all 144 µs and 135 µs. The file size includes the redo. This is one sample. The phone model was not in the log.
- The same Bench engine was packaged for the other two ABIs. No engine code changed, and the compare tests were not re-run. `bench-armeabi-v7a.apk` 17253245 bytes, versionCode 1008, sha256 `0bfebdf11bf97c473a04a1b45067272db1985749073f70da82f1735563fbd4a7`. `bench-x86_64.apk` 21227050 bytes, versionCode 4008, sha256 `096d28b08b799ee3f730dfc8aaebdc458531886817d0dcfdd8b2b039e309547e`. Debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0, launcher Bench. Neither was installed here.
- `examples/notes` pubspec build number is 4. `flutter analyze` reported no issues. `flutter test` passed 14 tests. `flutter build apk --split-per-abi --release` wrote three Margin packages, debug keystore, application id `dev.sqliteplus.margin_notes`, versionName 1.0.0, launcher Margin. `margin-notes-arm64-v8a.apk` 19997995 bytes, versionCode 2004, sha256 `ba72c0265fcbcf827b5469f79afc73bb3c3c9e088898eaeca42cdcd0d18d6620`. `margin-notes-armeabi-v7a.apk` 17613957 bytes, versionCode 1004, sha256 `bc1934543c1bb01fb6bd06cfd09a42dba0f8133c7cd0a1533b4aee9364ae013c`. `margin-notes-x86_64.apk` 21554994 bytes, versionCode 4004, sha256 `c304e3766d0a93a31781612eb1f3a1bda98b44d8e6f8b08d247120807433ba00`. Margin still stores `margin.db` as an `exportImage` snapshot. None of these three packages was installed here.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — File commits sync the redo and defer the database pages

- The versionCode 2008 phone log, Asia/Hebron 13:11 on 2026-10-29, still had three file operations slower than native: separate insert 434.3 ms against 398.4 ms, ratio 1.09; separate delete 537.1 ms against 491.3 ms, ratio 1.09; bulk update 11.0 ms against 1.1 ms, ratio 10.41. Checksums matched. The other pairs on that log were faster than native.
- A file commit now appends the changed byte ranges, or one logical integer addend, and syncs that redo once. The database file is written when the redo passes 16 MiB or the pager closes. Restart applies the redo onto the database bytes, so the commit is durable before those pages are written. Opening the database bytes alone, without the journal, sees the pre-checkpoint image. The redo magic is `SQREDO` version `0x02`. It is not an official SQLite journal header. A torn tail is ignored. A bad header throws and does not write.
- A bulk integer update journals the addend. The live rows keep it, and recovery or close applies it to the leaves. A later page-image commit checkpoints that addend first, so it is not applied twice. A deleted cell stays in place as a freeblock. Inserts still repack a page instead of reusing that freeblock.
- `packages/sqlite_plus`: `dart format --output=none --set-exit-if-changed .` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10519 tests.
- `examples/compare`: `flutter analyze` reported no issues and `flutter test` passed 17 tests. Those tests do not open `sqflite`.
- Linux x64, Dart 3.13.7, JIT, not AOT and not a phone. One sample of 1000 `bench` rows, each file operation on its own database. Checksums: insert 1000 rows and sum 500500, bulk 1000 and 501500, delete 0 and 0. With `flushSync`: insert 636765 µs, 0 database writes, 1000 journal writes of 109329 bytes, 1000 journal syncs; bulk 2330 µs, 1 journal write of 44 bytes, 1 journal sync; delete 443518 µs, 1000 journal writes of 588952 bytes, 1000 journal syncs. Without `flushSync`: insert 90965 µs, bulk 222 µs, delete 115676 µs. Sizes before close, database plus journal: insert 117764 bytes, bulk 29146 bytes, delete 618054 bytes. This is not a phone measurement and not a comparison with sqflite.
- `flutter build apk --split-per-abi --release` wrote three Bench packages, debug keystore, application id `dev.sqliteplus.engine_bench`, versionName 1.0.0, launcher Bench. `bench-arm64-v8a.apk` 19670051 bytes, versionCode 2009, sha256 `89b8c0f1d3742272f2fedd8e2dfcc2c3a4cebc7ff47084478b977bf8fe6dd611`. `bench-armeabi-v7a.apk` 17286013 bytes, versionCode 1009, sha256 `2ec2f0aee1e65875e01bc5b0fa477aa303b90701a664212647e92290932d9e6b`. `bench-x86_64.apk` 21227050 bytes, versionCode 4009, sha256 `293896d63ec03c81425b439dee4409d97864e42e777f77a975e5a1c338294b27`. None was installed here. The bench file size is taken before close, so it includes the redo.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — Phone log for versionCode 2009

- One 1000-row sample of the arm64 Bench package, versionCode 2009, Asia/Hebron 14:00 on 2026-10-29. Every pair matched. sqlite_plus was faster on every operation. Native is first. File separate insert 326.8 ms and 162.2 ms, ratio 0.50, size 36.0 KB and 115.0 KB, sum 500500. File transaction insert 81.0 ms and 72.6 ms, ratio 0.90, size 36.0 KB and 28.4 KB. File separate update 477.6 ms and 381.2 ms, ratio 0.80, size 36.0 KB and 82.9 KB, sum 501500. File bulk update 915 µs and 246 µs, ratio 0.27, size 36.0 KB and 28.5 KB. File search 129.4 ms and 11.7 ms, ratio 0.09, size 52.0 KB and 64.7 KB. File point lookup 105.9 ms and 7.6 ms, ratio 0.07, size 36.0 KB and 28.4 KB. File VACUUM 923 µs and 13 µs, ratio 0.01, hits 1, size 36.0 KB and 28.4 KB. File separate delete 413.8 ms and 345.5 ms, ratio 0.84, rows 0, sum 0, size 16.0 KB and 603.6 KB. File delete all 773 µs and 259 µs, ratio 0.34, rows 0, sum 0, size 16.0 KB and 28.5 KB. Memory separate insert 99.0 ms and 5.0 ms, ratio 0.05. Memory transaction insert 82.1 ms and 2.1 ms, ratio 0.03. Memory separate update 92.4 ms and 10.7 ms, ratio 0.12. Memory bulk update 336 µs and 106 µs, ratio 0.32. Memory search 108.0 ms and 6.5 ms, ratio 0.06. Memory point lookup 97.7 ms and 9.6 ms, ratio 0.10. Memory VACUUM 781 µs and 10 µs, ratio 0.01. Memory separate delete 93.7 ms and 7.3 ms, ratio 0.08. Memory delete all 195 µs and 97 µs, ratio 0.50. Separate insert, transaction insert, search, point lookup, and VACUUM sums are 500500. Separate update and bulk update sums are 501500. Deletes leave 0 rows and sum 0. VACUUM hits are 1. The other hit counts are 1000. The file size is taken before close and includes the redo. Separate delete stays large because close has not truncated the redo. This is one sample. The phone model was not in the log.
- The 13:11 versionCode 2008 log remains the earlier sample. On that log, file separate insert, file bulk update, and file separate delete were slower than native. The README charts were redrawn from this 14:00 file round. Each row has its own scale. The separate-delete bar stays long because the size includes the redo before close.
- No engine code changed for this note. The packages were not rebuilt. The armeabi-v7a and x86_64 files were not part of this sample. Margin is unchanged.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — version 0.0.3

- Package versions are `0.0.3`. The ORM depends on `sqlite_plus: ^0.0.3`. The generator depends on `sqlite_plus_orm: ^0.0.3`.
- `*.apk` is gitignored. The Bench and Margin release packages stay on disk as build output. Their byte sizes and checksums remain in the example READMEs.
- M9 stays unchecked. Item 108 stays open.

## 2026-10-29 — Familiar names for the two opens

- `openInMemory` in `sqlite_plus.dart` calls `MutableSqliteDatabase.create`. `openDatabase` in `sqlite_plus_io.dart` calls `DatabaseOwner.open`. The previous names remain. A false `directoryEntriesDurable` still throws before an isolate starts. That flag is still a caller attestation, not a power-loss result.
- `packages/sqlite_plus`: `dart format --output=none --set-exit-if-changed .` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10526 tests. The ORM and generator suites were not re-run. No engine behavior changed.
- M9 stays unchecked. Item 108 stays open. Nothing was uploaded to pub.dev.

## 2026-10-29 — Version 0.1.1

- `sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.1`. The package pages lead with short practical samples. The phone charts are the versionCode 2009 memory round and file round, each row on its own linear scale. The numbers are the same one-phone sample. No engine, ORM, or generator behavior changed, and the suites were not re-run.
- M9 stays unchecked. Item 108 stays open.

## 2026-11-01 — DB Browser readiness sequence

- `IMPLEMENTATION_PLAN.md` records B1–B5 for a Flutter browser that opens an official SQLite file. B1 is file open and recovery, B2 is paged reads, B3 is the pasted SQL statement, B4 is schema rebuilds, and B5 stays in the application. No engine behavior changed. No suite was re-run.
- M9 stays unchecked. Item 108 stays open.

## 2026-11-01 — B1 read path for official files

- The read path opens an auto-vacuum image. Pointer-map pages are decoded and are not treated as B-tree pages. `PRAGMA auto_vacuum` on that path is 0, 1, or 2 from the header. A pinned SQLite 3.53.1 FULL auto-vacuum file, source id `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`, returned the same short rows as `/tmp/sqlite-build/sqlite3`. The file bytes were unchanged. The CLI reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `sqlite_stat4` opens and is not scanned for planning. The pin CLI without `SQLITE_ENABLE_STAT4` reserves that name, so the image was built with `/tmp/sqlite-build/sqlite3-stat4` from the same source id. The pin CLI then read the same `small` row and the same `sqlite_stat4` count. An engine image with opposite stat4 samples kept the stat1 plan, and the query page-read delta matched the image without stat4. No wall-clock timing was run. No speedup is claimed.
- `openReadOnlyFile` recovers a pending `-wal` and a hot `-journal` in memory. The database, journal, and wal bytes stay unchanged, and `-shm` is not created. A pending WAL row was `pending` and `PRAGMA journal_mode` was `wal`. The same bytes alone have no table, which the pin CLI also reported. A valid hot journal restored `committed` for both. A torn journal shortened the image. A zeroed header was ignored. A bad checksum after growth left a truncated image that this engine rejects with `FormatException` and the pin CLI rejects as malformed. A bad checksum at the same size left `changed` for both.
- Write version 2 is accepted only when the read version matches. `MutableSqliteDatabase.fromImage` still rejects a write version other than 1 and a non-zero largest root page. `PRAGMA auto_vacuum` writes still throw. FULL auto-vacuum delete shrink is not implemented.
- A NONE delete does not shrink. Two hundred padded rows, a DELETE, and a VACUUM were page_count/freelist 4/0, 4/2, and 2/0 in this writer and in the pin CLI, with `integrity_check` ok. The freelist does not allow a shrink on that DELETE. VACUUM does shrink.
- The shared lock is database byte 0x40000002. While `openReadOnlyFile` held it, the pin CLI `BEGIN EXCLUSIVE` failed with `locked` and `SELECT` returned the row. A pin CLI `BEGIN EXCLUSIVE` then made `openReadOnlyFile` throw `SqlException`. When `-shm` exists, one shared lock among bytes 123–127 is taken. Another process holding all five made the open throw. Holding one still allowed the pending WAL row to be read. A non-vacuum one-row query read 1 page at open and 2 pages after `SELECT`. That is the cost check. No AOT benchmark was run.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10533 tests on Dart 3.13.7, Linux x64. The two native FTS opens set `PRAGMA auto_vacuum=NONE` because this pin CLI defaults to FULL and the writer still rejects those images.
- B2, B3, B4, and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B2 paged browse

- `SqliteDatabase.browse` and `MutableSqliteDatabase.browse` read one single-table `LIMIT`/`OFFSET` window, including bound parameters and ascending `rowid` order, and stop after `offset + limit` rows. A join or any other shape still uses `query`. `query` itself is unchanged.
- On an 80-row table, `query('SELECT v FROM t')` and `query('SELECT v FROM t LIMIT 100000')` read the same number of pages. `browse('SELECT v FROM t LIMIT 1')` reads fewer. `browse` of `LIMIT 0` adds no page reads. The pinned CLI at `/tmp/sqlite-build/sqlite3`, source id `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`, returned the same window, the same `ORDER BY rowid` window, the same empty offset, and the same one-row join.
- `zeroblob(16777217)` makes `query` throw `FormatException`. `browse('SELECT v FROM t LIMIT 1')` returns that blob. The pinned CLI reports length 16777217 and zero bytes at both ends. A well-formed record larger than 1000000000 bytes was not created, so the CLI length-limit text was not compared. `browse` passes that cap to the B-tree reader, which rejects a larger declared payload before allocation.
- No wall-clock timing was run. No speedup is claimed.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10536 tests on Dart 3.13.7, Linux x64.
- B3, B4, and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 json_pretty

- `json_pretty` formats a JSON value with a newline and a repeated indent. NULL input returns NULL. An omitted or NULL indent is four spaces. A text, number, or blob indent is that value's text, cut at the first NUL. Empty objects and arrays stay `{}` and `[]`. The result keeps the JSON subtype, so `->` and `json_type` see it.
- The gap-ledger case `json-pretty` is a match. `db_browser_b3_json_pretty_test.dart` compared NULL, nested values, duplicate keys, comments, escapes, custom indents, numeric and blob indents, and a NUL-truncated indent with `/tmp/sqlite-build/sqlite3`. That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- Malformed JSON raises `malformed JSON`, which the CLI also reports. The engine rejects a bad arity with `Invalid arguments to json_pretty`. The CLI says `wrong number of arguments`. JSON input stays capped at 1 MiB. Pretty output stays capped at 16 MiB; the boundary test uses the indent string. An indent byte `0xFF` is kept as code unit U+00FF. Storing that string was not compared. No wall-clock timing was run. No speedup is claimed.
- `packages/sqlite_plus`: `dart format` passed for the edited Dart files. `dart analyze --fatal-infos` passed. `dart test` of `db_browser_b3_json_pretty_test.dart`, `json_functions_test.dart`, and `gap_oracle_test.dart` passed 749 tests on Dart 3.13.7, Linux x64. The full package suite was not re-run for this note. `python3 tool/generate_gap_oracle.py --verify` passed.
- The rest of B3 stays unchecked, including EXPLAIN bytecode, EXPLAIN QUERY PLAN text, the double-quoted-string mode, ICU and locale collations, FTS3/FTS4 writes, the named FTS5 options, `VACUUM INTO`, `journal_mode` switches, `auto_vacuum` writes, and a durable commit across two attached databases. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 correlated json_each

- `json_each` and `json_tree` evaluate a column, a nested `json_each(j.value)`, or a scalar subquery once per outer row. Constant arguments are still read once. `generate_series` still rejects a non-constant argument. Two calls in one `FROM` no longer share one row set.
- `db_browser_b3_json_each_test.dart` compared comma joins, an inner join, a left join, `docs RIGHT JOIN json_each`, a full join, `json_tree`, a nested call, and a scalar subquery with `/tmp/sqlite-build/sqlite3`. That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. Malformed JSON is rejected by both. `json_each(docs.label) RIGHT JOIN docs` throws `No such column: docs.label`. The same CLI statement returns `0`. That shape stays open.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` of the JSON, virtual-table, pragma-table, metadata, and gap-ledger files passed 782 tests on Dart 3.13.7, Linux x64. The full package suite was not re-run for this note. No wall-clock timing was run. No speedup is claimed.
- The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 double-quoted strings

- `doubleQuotedStrings` defaults to false. An unqualified double-quoted identifier that is not a column stays `No such column: missing`, so the gap-ledger case `dqs-fallback` stays rejected. The pinned CLI result is `'missing'`.
- When the flag is on, that identifier is a string. `db_browser_b3_dqs_test.dart` matches `/tmp/sqlite-build/sqlite3` for a missing name, its original spelling, an empty identifier, an escaped quote, a space, a keyword, a real column including a different case, concatenation, `count(*)`, `GROUP BY`, `typeof`, a `CHECK`, a scalar subquery, a column whose name contains a dot, and a keyword or spaced column name. Brackets, backticks, qualified names, and `INSERT` column lists stay identifiers. Turning the flag off restores the column error. That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- Two visible columns with the same name raise `Ambiguous column: title`. The CLI says `ambiguous column name: title`. A failed `CHECK` is `CHECK constraint failed`. The CLI appends the expression. Unquoted `a.title`, when table `a` also has a column named `a.title`, still returns the dotted column. The CLI returns the `title` column (`bare`). That lookup was not changed.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10660 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The rest of B3 stays unchecked: native EXPLAIN bytecode, closer EXPLAIN QUERY PLAN text, `json_each(docs.label) RIGHT JOIN docs`, the unquoted `a.title` lookup above, ICU and locale collations, FTS3/FTS4 writes, FTS5 porter, trigram, detail, tokendata, locale, and multi-page leaves, `VACUUM INTO`, `journal_mode` switches, `auto_vacuum` writes, one durable commit across two attached databases, and the remaining DML syntax. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 json_each RIGHT JOIN

- `json_each(docs.label) RIGHT JOIN docs` returns 0 rows. The table function is scanned with no JSON argument, and the preserved `docs` rows are not added. `json_tree`, `FULL JOIN`, `LEFT JOIN`, an unqualified `label`, and `main.docs.label` do the same. `json_each(missing)` and `json_each(docs.nope)` still raise `No such column`. The pinned CLI text is `no such column: missing` and `no such column: docs.nope`.
- `db_browser_b3_json_each_test.dart` compared those statements with `/tmp/sqlite-build/sqlite3`. That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3. `docs RIGHT JOIN json_each` still matches the pin. Malformed JSON on a comma join is still rejected.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10660 tests on Dart 3.13.7, Linux x64. The new RIGHT JOIN checks are inside the existing comparison test, so the count did not grow. No wall-clock timing was run. No speedup is claimed.
- The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 qualified a.title

- Unquoted `a.title` is column `title` of alias `a`. A column whose name is `a.title` no longer hides that slot. `"a.title"` and `a."a.title"` still read the dotted column. `db_browser_b3_dqs_test.dart` matches `/tmp/sqlite-build/sqlite3` for the pair, `main.a.title`, `SELECT *`, a join, and `title INT` plus one. Unquoted `a.title` when that is the only column raises `No such column: a.title`. The CLI text is `no such column: a.title`.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10660 tests on Dart 3.13.7, Linux x64. The new checks are inside `db_browser_b3_dqs_test.dart`, so the count did not grow. No wall-clock timing was run. No speedup is claimed.
- The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 literal EXPLAIN bytecode

- `EXPLAIN SELECT 1` returns the pinned opcode rows. The columns are `addr`, `opcode`, `p1`, `p2`, `p3`, `p4`, `p5`, and `comment`. A result column that is one literal opcode uses `Integer`, `Int64`, `Real`, `String8`, `Blob`, or `Null`, then `ResultRow`, `Halt`, and `Goto`. The gap-ledger case `explain-bytecode` is a match. `db_browser_b3_explain_test.dart` also matches signed 32-bit edges, signed 64-bit edges, hex literals, `TRUE` and `FALSE`, reals including `Inf`, and blobs, on both `query` and `browse`.
- `EXPLAIN SELECT 1+1`, `EXPLAIN SELECT 1 WHERE 1`, `EXPLAIN SELECT * FROM t`, and `EXPLAIN INSERT` still throw `EXPLAIN bytecode is not implemented`. The CLI program for `EXPLAIN SELECT 1+1` contains `Add`. `EXPLAIN SELECT title` is `no such column: title` on the CLI. This is not a VDBE. EXPLAIN QUERY PLAN is unchanged.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10663 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The rest of B3 stays unchecked: closer EXPLAIN QUERY PLAN text, ICU and locale collations, FTS3/FTS4 writes, FTS5 porter, trigram, detail, tokendata, locale, and multi-page leaves, `VACUUM INTO`, `journal_mode` switches, `auto_vacuum` writes, one durable commit across two attached databases, and the remaining DML syntax. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 EXPLAIN QUERY PLAN still differs

- The gap-ledger case `explain-query-plan` stays a difference. The pinned row for `EXPLAIN QUERY PLAN SELECT a FROM t WHERE a=1` on `t(a INTEGER PRIMARY KEY)` is `id=2`, `parent=0`, `notused=33`, `detail=SEARCH t USING INTEGER PRIMARY KEY (rowid=?)`. A full scan is `2,0,216,'SCAN t'`. `WHERE a>1` is `2,0,196,'SEARCH t USING INTEGER PRIMARY KEY (rowid>?)'`. `EXPLAIN QUERY PLAN SELECT 1` is `1,0,0,'SCAN CONSTANT ROW'`. `EXPLAIN QUERY PLAN SELECT * FROM missing` is `no such table: missing` on the CLI.
- This engine still returns one `detail` column. It does not invent opcode address 2 or the `rRun` cost 33. `db_browser_b3_eqp_test.dart` compares those CLI rows with `/tmp/sqlite-build/sqlite3` and checks that the engine text is not that detail. A covering plan still contains `COVERING`. `EXPLAIN SELECT 1` still returns bytecode.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10665 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The EQP sub-item stays unchecked. The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 ICU and locale collations stay absent

- The pinned CLI was built without ICU. `CREATE TABLE t(v TEXT COLLATE ICU)` and `'a'='A' COLLATE ICU` fail with `no such collation sequence: ICU`. `COLLATE en_US` fails with `no such collation sequence: en_US`. An empty collation name fails with `no such collation sequence:`. This engine says `Unknown collation` for the table and `No such collation: ICU` for the expression. `SELECT 'a' COLLATE ICU` returns `a` on the CLI and throws `No such collation: ICU` here.
- `BINARY`, `NOCASE`, and `RTRIM` still match, including `'á'<'b' COLLATE NOCASE` which is `0` on both. The pin's `PRAGMA collation_list` also names `decimal` and `uint`. Those sequences are not implemented. `db_browser_b3_collation_test.dart` records the comparison.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10667 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The ICU sub-item stays unchecked. The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 FTS3 and FTS4 writes stay rejected

- The pinned CLI creates `fts4(body)`, inserts `hello world`, and `MATCH 'hello'` returns `hello world`. `fts3` returns `hello`. An empty insert leaves one row. `DELETE ... MATCH 'hello'` leaves zero rows. `SELECT` from a missing table is `no such table: missing` on the CLI.
- This engine rejects `CREATE VIRTUAL TABLE ... USING fts3` and `fts4` with `FTS3 and FTS4 writes are not implemented`. The table is not created. An FTS5 `INSERT` of `kept` still matches. `db_browser_b3_fts34_test.dart` records the comparison.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10669 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The FTS3/FTS4 write sub-item stays unchecked. The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 FTS5 porter, trigram, detail, tokendata, and locale stay open

- Porter `MATCH 'run'` returns `running` on the pinned CLI. Trigram `MATCH 'bcd'` returns `abcdef`, and `MATCH 'zz'` returns `0`. `detail=none` returns `hello`. `tokendata=1` and `locale=1` create successfully and return an empty result. An unknown tokenizer is `no such tokenizer: nope` on the CLI.
- This engine says `no such tokenizer: porter`, `no such tokenizer: trigram`, and `fts5 option is not implemented` for `detail`, `tokendata`, and `locale`. A 2000-token `unicode61` insert returns the same `length(body)` on both. The FTS5 leaf pages were not compared, so multi-page leaves stay open. An ordinary FTS5 insert of `kept` still matches. `db_browser_b3_fts5_test.dart` records the comparison.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10671 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- This sub-item stays unchecked. The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 VACUUM INTO stays short of the pinned file

- The pinned CLI `VACUUM INTO` writes a new database. `integrity_check` is `ok` and the copied rows are `1` and `3`. The source query still returns those rows. Writing the same path again is `output file already exists`. `VACUUM` inside a transaction is `cannot VACUUM from within a transaction`. `VACUUM main INTO` also writes the file.
- This engine says `Unknown database: into` and does not create the file. `VACUUM main INTO` is `Unsupported or trailing SQL`. Plain `VACUUM` still returns the same rows. `db_browser_b3_vacuum_into_test.dart` records the comparison.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10673 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The `VACUUM INTO` sub-item stays unchecked. The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 journal_mode switches stay listed

- On pinned `:memory:`, `PRAGMA journal_mode` and assignments to `memory`, `off`, `delete`, and `wal` all return `memory`. On a file, the pin starts at `delete`, `journal_mode=off` stays `delete`, and `journal_mode=memory` returns `memory` while the inserted row remains `1`.
- This engine reads `rollback`. `journal_mode=memory` throws `journal_mode memory is not implemented`. `journal_mode=off` throws `journal_mode off is not implemented`. `journal_mode=delete` throws `journal_mode delete is not implemented`. Assigning the current `rollback` mode still reads `rollback`. The gap cases `journal-mode-memory`, `journal-mode-off`, and `journal-mode-read` stay listed. `db_browser_b3_journal_test.dart` records the comparison. This is not the official journal.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10675 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The journal_mode sub-item stays unchecked. The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 auto_vacuum writes stay rejected

- `PRAGMA auto_vacuum=FULL` is an empty result on the pinned CLI. The same session then reads `1`. `INCREMENTAL` then reads `2`, and `incremental_vacuum` adds no further row. `NONE` and `auto_vacuum=3` then read `0`.
- This engine throws `auto_vacuum is not implemented` for `FULL`, `INCREMENTAL`, `NONE`, and `3`. A later read stays `0`. A delete still leaves `count(*)` = 0, and no pointer-map shrink was added. The gap case `auto-vacuum-full` stays rejected. `db_browser_b3_autovacuum_test.dart` records the comparison.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10677 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The auto_vacuum sub-item stays unchecked. The rest of B3 stays unchecked. B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 cross-database insert stays rejected

- `INSERT INTO aux.u SELECT v FROM t` is an empty result on the pinned CLI. The same session then reads `count(*)` = 1 and `v` = `m` from `aux.u`, and `t` still holds `m`. Inserting into a missing `aux.u` is `no such table: aux.u` on the CLI.
- This engine throws `cross-database statement is not supported`. `aux.u` stays empty. `t` still holds `m`, and a later insert of `n` is visible. The gap case `cross-insert` stays rejected. `db_browser_b3_cross_insert_test.dart` records the comparison. No second durable commit was added.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10679 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The cross-database commit stays unchecked. Remaining DML, B4, and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 remaining gap-ledger DML

- The gap ledger's only other DML write is `cross-insert`, and that case stays rejected. `db_browser_b3_dml_test.dart` matches `/tmp/sqlite-build/sqlite3` for `INSERT DEFAULT VALUES`, `REPLACE`, `ON CONFLICT DO NOTHING`, `UPDATE ... RETURNING`, `DELETE ... RETURNING`, `SET v=v||'x'`, and `INSERT ... SELECT`. This is not a claim that every DML form was compared.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10681 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- B4 and B5 stay unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B4 structure-dialog rebuild

- A structure-dialog rebuild creates the replacement table, copies the kept columns, drops the old table, renames the replacement, and recreates the index. `db_browser_b4_test.dart` matches `/tmp/sqlite-build/sqlite3` for `integrity_check`, the rows, and `sqlite_schema`. The engine image opens in that CLI. A CLI image built with `auto_vacuum=NONE` opens here, and a later insert still passes the CLI `integrity_check`. The writer still rejects a pointer-map file.
- Renaming fails with `error in view v: no such table: main.t` when a view names a table that was dropped. The same script with a trigger is `error in trigger tr: no such table: main.t`. The bytes stay unchanged. `DROP COLUMN` matches the pin for a primary key, a column `UNIQUE`, the last column, a secondary index, a table `UNIQUE`, a table `CHECK`, a generated column, a column-level foreign key, a table foreign key, an `INSERT` or `UPDATE` target the pin does not resolve, and an edit beside an FTS5 table. This is not every schema form.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed. `dart test` passed 10686 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed. Storage bytes did not change format. A rejected rename keeps the previous image.
- B3 stays open. Its unmatched parts stay listed with the CLI result. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 EXPLAIN QUERY PLAN matches the compared rows

- `EXPLAIN QUERY PLAN SELECT a FROM t WHERE a=1` matches the pinned CLI: `2,0,33,'SEARCH t USING INTEGER PRIMARY KEY (rowid=?)'`. A full scan is `2,0,216,'SCAN t'`. `WHERE a>1` is `2,0,196,'SEARCH t USING INTEGER PRIMARY KEY (rowid>?)'`. `WHERE a>=1` uses that same cost and `rowid>?`. `WHERE a<1` and `WHERE a<=1` are `2,0,196,'SEARCH t USING INTEGER PRIMARY KEY (rowid<?)'`. `WHERE a>1 AND a<9` is `2,0,156,'SEARCH t USING INTEGER PRIMARY KEY (rowid>? AND rowid<?)'`. `EXPLAIN QUERY PLAN SELECT 1` is `1,0,0,'SCAN CONSTANT ROW'`. `EXPLAIN QUERY PLAN SELECT * FROM missing` is `no such table: missing`.
- A covering index predicate is `2,0,55,'SEARCH wide USING COVERING INDEX i (a=?)'`. Selecting the uncovered column is `3,0,62,'SEARCH wide USING INDEX i (a=?)'`. `SELECT *` through an index on the non-rowid column is `2,0,56,'SEARCH keyed USING COVERING INDEX ib (b=?)'`. That label does not change the read path. An aliased scan is `2,0,216,'SCAN x'`. The query spelling `T` is kept. The gap case `explain-query-plan` is a match. Multi-table addresses and stat1-adjusted costs were not compared. `EXPLAIN SELECT 1` still matches. `EXPLAIN SELECT 1+1` still throws.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10559 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The EXPLAIN QUERY PLAN sub-item is checked. The B3 parent stays open. The other B3 parts stay open. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 ICU and locale collations match the pin

- This pin has no ICU library. `CREATE TABLE t(v TEXT COLLATE ICU)`, `'a'='A' COLLATE ICU`, and `CREATE INDEX ... COLLATE ICU` fail with `no such collation sequence: ICU`. `COLLATE en_US` fails with `no such collation sequence: en_US`. `COLLATE Icu` keeps that spelling. An empty name fails with `no such collation sequence:`. `SELECT 'a' COLLATE ICU` and `SELECT 'a' COLLATE ""` return `a`. `NULL='a' COLLATE ICU` and an untaken `CASE` comparison also raise that sequence error. `1 OR 'a'='b' COLLATE ICU` and `0 AND 'a'='b' COLLATE ICU` stay valid.
- `PRAGMA collation_list` matches the pin: `decimal`, `BINARY`, `NOCASE`, `RTRIM`, `uint`. `decimal` and `uint` comparisons, column `ORDER BY`, and `GROUP BY` match, including `'1.50'='1.5' COLLATE decimal` = `1`, `'1E-2'='0.01' COLLATE decimal` = `0`, `'a10'<'a2' COLLATE uint` = `0`, and `'x00123y'='x123y' COLLATE uint` = `1`. `BINARY`, `NOCASE`, and `RTRIM` still match. A custom `rev` collation still orders `c`, `b`, `a`. `createCollation` rejects `decimal` and `uint`.
- A `UNIQUE` column rejects a second decimal or uint spelling that compares equal. The pin's message is `UNIQUE constraint failed: t.v`. This engine still says `UNIQUE constraint failed`. Decimal text longer than 10,000,000 digits was not compared. No speedup is claimed.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10563 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The ICU and locale collation sub-item is checked. The B3 parent stays open. The other B3 parts stay open. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 FTS3 and FTS4 SQL rows match; the inverted index does not

- `CREATE VIRTUAL TABLE` using `fts3` and `fts4` succeeds. FTS4 `MATCH 'hello'` returns `hello world`. FTS3 returns `hello`. An empty FTS4 insert leaves `count(*)` = 1. `DELETE ... MATCH 'hello'` leaves `count(*)` = 0. `CREATE VIRTUAL TABLE f USING fts4()` reads column `content`. `Hello` matches `hello`. An FTS5 insert of `kept` still matches. A native FTS4 image still rejects `INSERT` with `FTS3 and FTS4 writes are not implemented`, and its bytes stay unchanged.
- The missing-table text is still `No such table: missing` here. The CLI text is `no such table: missing`.
- An image written by this engine fails the pinned CLI `integrity_check` with `unable to validate the inverted index for FTS4 table main.f`. That CLI's `MATCH 'hello'` on the file returns no row. Official segment, segdir, docsize, and stat bytes were not written. The FTS3/FTS4 write sub-item stays unchecked for that reason.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10566 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The FTS3/FTS4 write sub-item stays unchecked. The B3 parent stays open. The other B3 parts stay open. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 FTS5 porter, trigram, detail, tokendata, and locale match the pin

- Porter `MATCH 'run'` returns `running`. `Running`, `cats` for `cat`, `caresses` for `caress`, `relational` for `relat`, `happy` for `happi`, and `controll` for `control` match. `runner` does not match `run`. A token shorter than 3 bytes (`to`) and `feed` stay unchanged. A 64-byte token is stemmed. A 65-byte token is not. Trigram `MATCH 'bcd'` returns `abcdef`. `MATCH 'zz'`, `MATCH 'z'`, and `MATCH 'ab'` return 0. `MATCH 'ABC'` folds by default. `case_sensitive 1` does not. `detail=none` returns `hello`. A phrase or `NEAR` when detail is not `full` is `fts5: phrase queries are not supported (detail!=full)` or `fts5: NEAR queries are not supported (detail!=full)`. A column filter on `detail=none` is `fts5: column queries are not supported (detail=none)`. `tokendata=1` and `locale=1` succeed, and `MATCH 'hello'` returns `hello`. An unknown tokenizer is `no such tokenizer: nope`. `tokenize='simple'` is `no such tokenizer: simple`. A bad porter or trigram constructor is `error in tokenizer constructor`.
- The `f_data` blocks for porter `running`, trigram `abcdef`, `detail=none` `hello`, `detail=columns` `hello`, `tokendata=1` `hello`, `locale=1` `hello`, and a 2000-token `unicode61` insert match `/tmp/sqlite-build/sqlite3`. Each exported image's `integrity_check` is `ok`. `detail=none` stores no token positions. That 2000-token insert still returns `length(body)` = 11999. An ordinary FTS5 insert of `kept` still matches.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10566 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The FTS5 sub-item is checked. The B3 parent stays open. The FTS3/FTS4 inverted index, `VACUUM INTO`, `journal_mode`, `auto_vacuum`, and the cross-database commit stay open. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 VACUUM INTO matches the pin

- `VACUUM INTO` writes a new file. The pinned CLI `integrity_check` is `ok` and the copied rows are `1` and `3`. The source query still returns those rows. A second write is `output file already exists`. `VACUUM INTO NULL`, `VACUUM INTO 1`, `VACUUM INTO x'61'`, and an unbound `VACUUM INTO ?` are `non-text filename`. A missing parent directory and a directory path are `unable to open database:` followed by that path. Inside a transaction, `VACUUM` and `VACUUM INTO` are `cannot VACUUM from within a transaction`. `VACUUM main INTO` writes the file. `VACUUM INTO ('dir/' || 'name')` writes the file. An empty filename succeeds and writes no file. A zero-length existing file is replaced. `VACUUM aux INTO` copies the attached row `m`. `VACUUM temp` and `VACUUM temp INTO` succeed, write no file, and leave the temp row, including `VACUUM temp` inside a transaction and `VACUUM TEMP INTO NULL`.
- A crash after the temporary file is flushed and before rename leaves the destination absent. That temporary file's pinned `integrity_check` is `ok` and the row is `3`. The source rows stay. A retry writes the destination and removes the temporary file. Plain `VACUUM` still returns `1` and `3`.
- Page bytes of the output file were not compared with the pin. No speedup is claimed.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10566 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The `VACUUM INTO` sub-item is checked. The B3 parent stays open. The FTS3/FTS4 inverted index, `journal_mode`, `auto_vacuum`, and the cross-database commit stay open. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 journal_mode matches the compared pin results

- On `:memory:`, `PRAGMA journal_mode` and assignments to `memory`, `off`, `delete`, `wal`, `persist`, `truncate`, `rollback`, and an unknown name all return `memory`. `CREATE TABLE` and `INSERT` still return the row. `exportImage` bytes stay unchanged. Header byte 18 stays 1, so `sqlJournalMode` of that byte is still `rollback` and a read-only open of the image still says `rollback`. `fromImage` of write version 2 still throws.
- On a file, the mode starts at `delete`. `journal_mode=off` stays `delete`. `journal_mode=memory` returns `memory` and a later read is `memory`. `SELECT v` stays `1`. Header bytes 18 and 19 stay 1, which is what the pin file shows after `journal_mode=memory`. `journal_mode=delete` returns `delete` and the row stays. File `wal`, `persist`, and `truncate` throw `journal_mode wal is not implemented`, `journal_mode persist is not implemented`, and `journal_mode truncate is not implemented`. Official journal-file bytes were not compared. This engine's redo log is not an official SQLite journal.
- `temp.journal_mode` starts at `delete`. `off` stays `delete`. `memory` returns `memory`. The main image bytes stay.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10566 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The `journal_mode` sub-item is checked for those rows. File `wal`, `persist`, and `truncate` stay unswitched. The B3 parent stays open. The FTS3/FTS4 inverted index, `auto_vacuum`, and the cross-database commit stay open. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 auto_vacuum writes match the compared pin rows

- `PRAGMA auto_vacuum=FULL` is an empty result. The same session then reads `1`. `INCREMENTAL` reads `2`. `NONE` and `auto_vacuum=3` read `0`. `-1` and `nope` read `0`, and `Full` then reads `1`. `incremental_vacuum`, `incremental_vacuum(0)`, and `incremental_vacuum(-1)` add no row on that empty database. After `CREATE TABLE`, `FULL` stays `0`. After `user_version=3`, `FULL` stays `0` and `user_version` stays `3`. `FULL` then `INCREMENTAL` reads `2`, a later `NONE` stays `2`, and `1` reads `1`. `temp.auto_vacuum=FULL` reads `1` and `main` stays `0`.
- The compared FULL, INCREMENTAL, and NONE images match `/tmp/sqlite-build/sqlite3` for `auto_vacuum`, `page_count`, `freelist_count`, `integrity_check`, and the selected value. The pointer-map bytes of the one-index image and the `zeroblob(5000)` image match that CLI. The gap case `auto-vacuum-full` matches.
- A pointer-map byte `9` is `*** in database main ***` followed by `Failed to read ptrmap key=3`. `SELECT v` is still `1`. An incremental cookie with largest root `0` is `*** in database main ***` followed by `incremental_vacuum enabled with a max rootpage of zero`. `SELECT v` is still `1`, and `auto_vacuum` reads `0`.
- A crash during the commit of a second insert on a FULL image recovers either the first row or both rows. `integrity_check` is `ok` and `auto_vacuum` stays `1`.
- `incremental_vacuum` does not move pages. After `INCREMENTAL`, `INSERT` of `zeroblob(5000)`, and `DELETE`, this engine has `page_count` 3 and `freelist_count` 0. The pin keeps `page_count` 4 and `freelist_count` 1 until `incremental_vacuum`. NONE reads still skip pointer maps. No AOT timing was run. No speedup is claimed.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10575 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The `auto_vacuum` sub-item is checked for those rows. Incremental page movement stays unimplemented, with the freelist difference named above. The B3 parent stays open. The FTS3/FTS4 inverted index and the cross-database commit stay open. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 one durable commit across two attached databases matches the pin

- `INSERT INTO aux.u SELECT v FROM t` is an empty result. The same session then reads `count(*)` = 1 and `v` = `m` from `aux.u`. Main `t` still holds `m`. The gap case `cross-insert` matches. An empty source changes 0 rows. `''`, NULL, a bound comparison, a two-column `RETURNING` insert, and `INSERT INTO t SELECT v FROM aux.u` keep the compared rows. `ROLLBACK` leaves `aux.u` empty. `DETACH` of a modified `aux` inside a transaction is `database aux is locked`. `DETACH` of an unmodified attachment is not restored by `ROLLBACK`.
- `db_browser_b3_cross_insert_test.dart` matches `/tmp/sqlite-build/sqlite3` for the memory script, the empty source, `''` and NULL, the reverse insert, and `ROLLBACK`. The same CLI reads the engine's reopened main and aux files as `1`, `m`, `m`, and `integrity_check` `ok`. Reopening both files in this engine returns the same rows.
- A transaction that inserts into main and into `aux.u` syncs one schema-commit record before either database page is published. Every injected crash, with unsynced writes kept and dropped, recovers both files old or both files new. Both outcomes occurred. `integrity_check` is `ok`. That record is not an official SQLite master journal, and those bytes were not compared. Without the schema-commit journal the commit throws `durable commit across databases requires a schema commit journal`, and `ROLLBACK` restores both images.
- `UPDATE` and `DELETE` that read the other schema still throw `cross-database statement is not supported`. The pin performs those writes. Without the attachment, the pin says `no such table: aux.u` and this engine says `Unknown database: aux`.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. It reports `COMPILER=gcc-13.3.0`. `manifest.json` still records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10582 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The cross-database commit sub-item is checked for those rows. `UPDATE` and `DELETE` across schemas stay rejected, with the difference named above. The B3 parent stays open. The FTS3/FTS4 inverted index stays open. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — B3 FTS3/FTS4 inverted index and cross-schema UPDATE and DELETE match the pin

- Contentful FTS3 and FTS4 writes rebuild one segment. `db_browser_b3_fts34_test.dart` compares the exported image with `/tmp/sqlite-build/sqlite3`. `PRAGMA integrity_check` is `ok`. FTS4 `MATCH 'hello'` returns `hello world`. FTS3 returns `hello`. An empty FTS4 insert leaves `count(*)` = 1. `DELETE ... MATCH 'hello'` leaves `count(*)` = 0. `CREATE VIRTUAL TABLE f USING fts4()` reads column `content`. A two-column insert with `docid` 5 and 9 returns `Hello World` for `hello` and `other` for `other`. A native FTS4 file opens here. Parenthesized `MATCH` returns `hello world`. A later insert keeps `integrity_check` `ok`, and `MATCH` returns `hello world` and `text`. A damaged root leaf is `malformed inverted index for FTS4 table main.f` on that CLI. The content row is still `hello world` here. A crash during an FTS4 insert recovers the empty image or the inserted row. Both outcomes occurred. That CLI's `integrity_check` is `ok`, and `MATCH 'hello'` returns 0 or 1. An FTS5 insert of `kept` still matches. Contentless FTS3/FTS4 writes still throw `FTS3 and FTS4 writes are not implemented`. Byte-identical segment bytes were not compared.
- `UPDATE aux.u SET v = (SELECT v FROM t)` changes 1 row and leaves `v` = `m` in both tables. `WHERE 0` changes 0. `DELETE FROM aux.u WHERE v IN (SELECT v FROM t)` leaves the row that is not in `t`. `UPDATE aux.u SET v = t.v FROM t` copies the joined value. A `group_concat` update, a same-named table, a NULL subquery, and `ROLLBACK` match the compared rows. `db_browser_b3_cross_insert_test.dart` matches that CLI for those scripts. Without the attachment, `UPDATE aux.u SET v = 1` and `DELETE FROM aux.u` are `no such table: aux.u`. `UPDATE AUX.U SET v = 1` is `no such table: AUX.U`. `INSERT INTO aux.u VALUES ((SELECT v FROM t))` still throws `cross-database statement is not supported`.
- A file commit of `UPDATE aux.u SET v = (SELECT v FROM t)` reopens both files with `m` and `integrity_check` `ok`. A crash between that update and `DELETE FROM t WHERE v = (SELECT v FROM aux.u)` recovers both files old or both files new. Both outcomes occurred. `integrity_check` is `ok`. The schema-commit record is not an official SQLite master journal.
- `UPDATE main.t SET v = (SELECT v FROM temp.t)` changes 1 row. Main `t` becomes `temp`. Temp `t` stays `temp`.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. This run's binary reports `COMPILER=clang-18.1.3`. `PRAGMA compile_options` matches `manifest.json` except that compiler string. `manifest.json` records clang-22.1.3. Explain comments are absent. `DQS=0` is not set.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10590 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The FTS3/FTS4 write sub-item is checked. The cross-schema `UPDATE` and `DELETE` rows are checked on the durable-commit sub-item. The B3 parent is checked. B1, B2, and B4 stay checked. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — Cross-schema INSERT VALUES matches the pin

- `INSERT INTO aux.u VALUES ((SELECT v FROM t))` inserts `m`. `changes()` is 1. `last_insert_rowid()` is the inserted row, not the rowid left by the source insert. An empty subquery inserts NULL and still changes 1 row. Two scalar subqueries fill two columns. `ORDER BY` keeps the first row. `SELECT main.t.v FROM main.t` beside an `aux.t` returns `main` and leaves `aux.t` as `aux`. `RETURNING`, two VALUES rows, a CTE, `ON CONFLICT(id) DO UPDATE SET v = excluded.v`, and `INSERT INTO t VALUES ((SELECT v FROM aux.u))` match `/tmp/sqlite-build/sqlite3`. `aux.sqlite_schema` after the copy is only the destination tables. A missing table is `No such table: missing`; the CLI says `no such table: missing`. Two subquery columns are `Scalar subquery must return one column`; the CLI says `sub-select returns 2 columns - expected 1`. A short VALUES list is `INSERT width mismatch`; the CLI says `table aux.u has 2 columns but 1 values were supplied`.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. This run's binary reports `COMPILER=gcc-13.3.0`. `manifest.json` records clang-22.1.3. Explain comments are absent. `DQS=0` is not set.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10591 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- B1, B2, B3, and B4 stay checked. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. Contentless FTS3/FTS4 writes, file `journal_mode=wal`, `persist`, and `truncate`, `incremental_vacuum` page movement, `EXPLAIN` beyond a literal projection, and an official master journal stay open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — Bounded EXPLAIN arithmetic, scans, and constant INSERT match the pin

- `EXPLAIN` for constant arithmetic and concatenation, a constant `WHERE`, one ordinary table scan, and one `INSERT` or `REPLACE` of constants matches `/tmp/sqlite-build/sqlite3` in `db_browser_b3_explain_test.dart`. `EXPLAIN SELECT 1+1` is `Add` with the shared literal coded once. `EXPLAIN SELECT 1 WHERE 0` is `Goto`. `EXPLAIN SELECT 1 WHERE 0.0` is `IfNot`. `CREATE TABLE t(a); EXPLAIN SELECT a FROM t` is `OpenRead` on root 2, and `Transaction` p3 is the schema cookie `1`. After a second table, `EXPLAIN SELECT b FROM u` opens root 3 and the cookie is `2`. `EXPLAIN INSERT INTO t VALUES (1)` is `OpenWrite`, `NewRowid`, `MakeRecord`, and `Insert` p5 `57`. `DEFAULT VALUES`, a full column list, a reversed column list, and a missing untyped column match. `browse` returns the same rows as `query`.
- A subquery, `EXPLAIN SELECT title`, `SELECT rowid`, an `INTEGER PRIMARY KEY` scan, `WITHOUT ROWID`, `SELECT *` from a generated column, `INSERT` of two `VALUES` rows, and `INSERT` into a typed column still throw `EXPLAIN bytecode is not implemented`. `EXPLAIN SELECT title` is `no such column: title` on the CLI. The CLI still produces a program for the integer-primary-key scan. This is not a VDBE.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. This run's binary reports `COMPILER=gcc-13.3.0`. `manifest.json` records clang-22.1.3. `DQS=0` is not set. `PRAGMA auto_vacuum` on a fresh database is `0`.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10592 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed.
- The native `EXPLAIN` bytecode sub-item stays checked for these shapes. Subqueries, joins, integer primary keys, `WITHOUT ROWID`, generated columns, and typed or multi-row inserts stay outside it. B5 stays unchecked. M9 stays unchecked. Item 108 stays open. Contentless FTS3/FTS4 writes, file `journal_mode=wal`/`persist`/`truncate`, and `incremental_vacuum` page movement stay open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — Incremental auto-vacuum page movement matches the pin

- After `PRAGMA auto_vacuum=INCREMENTAL`, `INSERT` of `zeroblob(5000)`, and `DELETE`, `page_count` is 4 and `freelist_count` is 1. `PRAGMA incremental_vacuum`, `incremental_vacuum(0)`, and `incremental_vacuum(-1)` then read 3 and 0. `zeroblob(20000)` leaves 7 and 4. `incremental_vacuum(1)` leaves 6 and 3. A second blob whose overflow page sits past a free page is moved onto that free page. `length(v)` stays 5000. `integrity_check` is `ok`.
- `db_browser_b3_autovacuum_test.dart` matches `/tmp/sqlite-build/sqlite3` for those rows, including a native hole image opened here and vacuumed by one page. A freelist count of 99 throws `FormatException`. Opening that image for writing is rejected. The commit still uses this engine's rollback redo. No separate crash injection was added for the vacuum statement. No AOT timing was run. No speedup is claimed.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. This run's binary reports `COMPILER=gcc-13.3.0`. `manifest.json` records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed for the edited files. `dart analyze --fatal-infos` passed for those files. `dart test` passed 10594 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run.
- B5 stays unchecked. M9 stays unchecked. Item 108 stays open. Contentless FTS3/FTS4 writes, file `journal_mode=wal`/`persist`/`truncate`, and an official master journal stay open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — Contentless FTS4 matches the pin

- `CREATE VIRTUAL TABLE f USING fts4(body, content='')` creates no `f_content` table. `INSERT INTO f(docid, body) VALUES(7, 'hello world')` then `SELECT rowid FROM f WHERE f MATCH 'hello'` returns 7. A second insert is visible to `MATCH`. A missing term returns no row. `PRAGMA integrity_check` is `unable to validate the inverted index for FTS4 table main.f: SQL logic error`. A scan without `MATCH`, `SELECT body`, and `DELETE` are `SQL logic error`. An insert without a docid is `constraint failed`. A native contentless file opens here, and a later insert of docid 9 is visible. FTS3 `content=''` is a second column named `content`, not a contentless table. FTS5 contentless behavior is unchanged.
- `db_browser_b3_fts34_test.dart` matches `/tmp/sqlite-build/sqlite3` for those rows. This is one rebuilt segment. Byte-identical segment bytes were not compared.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. This run's binary reports `COMPILER=gcc-13.3.0`. `manifest.json` records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed for the edited files. `dart test` passed 10596 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run.
- B5 stays unchecked. M9 stays unchecked. Item 108 stays open. File `journal_mode=wal`/`persist`/`truncate` and an official master journal stay open in the notes below. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — File journal_mode wal, persist, and truncate match the pin

- On a file, `journal_mode=wal` returns `wal`. Header bytes 18 and 19 become 2. The change counter and the version-valid-for field each increase by 1. No `-wal` file is written. The pinned CLI reads that file as `wal`, the stored row, and `integrity_check` `ok`. Inside a transaction the errors are `cannot change into wal mode from within a transaction` and `cannot change out of wal mode from within a transaction`. Leaving `wal` restores bytes 18 and 19 to 1.
- `journal_mode=persist` returns `persist`. The next commit leaves a journal whose first 28 bytes are 0. Its length is one 512-byte sector plus the changed pages. Header bytes 18 and 19 stay 1. The pinned CLI reads the new row and `integrity_check` `ok`. `journal_mode=truncate` returns `truncate` and leaves a 0-byte journal. The pinned CLI reads the new row. `temp.journal_mode=wal` stays `delete`. `temp` `persist` and `truncate` switch.
- A hot official journal rolls the open file back to the old `user_version` and the journal is removed. Zeroing the first 28 bytes leaves the new `user_version` in place. Delete-mode commits still use this engine's redo log. The wal path checkpoints the database file. It does not write a multi-frame WAL. Persist page order was not compared with the pin.
- `db_browser_b3_journal_test.dart` matches `/tmp/sqlite-build/sqlite3` for those rows. That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. This run's binary reports `COMPILER=gcc-13.3.0`. `manifest.json` records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed for the edited files. `dart test` passed 10596 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run.
- B5 stays unchecked. M9 stays unchecked. Item 108 stays open. An official master journal stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-01 — Cross-schema VALUES errors match the pin wording

- `INSERT INTO aux.u VALUES ((SELECT v FROM missing))` is `no such table: missing`. `INSERT INTO aux.u VALUES ((SELECT a, b FROM t))` is `sub-select returns 2 columns - expected 1`. `CREATE TABLE aux.u(a, b)` then `INSERT INTO aux.u VALUES ((SELECT v FROM t))` is `table aux.u has 2 columns but 1 values were supplied`. `db_browser_b3_cross_insert_test.dart` matches `/tmp/sqlite-build/sqlite3` for those three texts. `SELECT body FROM missing` is `no such table: missing`.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. This run's binary reports `COMPILER=gcc-13.3.0`. `manifest.json` records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed for the edited files. `dart test` passed 10596 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run.
- B5 stays unchecked. This machine has no Flutter SDK, so plots and CSV import or export were not added to the Flutter app. M9 stays unchecked. The scenario harness rejects a row count above 10000, and iOS, macOS, Windows, power loss, and pub.dev were not run here. Item 108 stays open. An official master journal stays open. Subqueries, joins, integer primary keys, `WITHOUT ROWID`, generated columns, and typed or multi-row `EXPLAIN` programs stay outside the checked bytecode. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-02 — Bounded EXPLAIN covers the remaining named shapes

- `EXPLAIN SELECT 1 FROM (SELECT 1)` is a coroutine. An unused inner column is `Null`, and a used column is `Copy`. `EXPLAIN SELECT a FROM t` after `CREATE TABLE t(a INTEGER PRIMARY KEY)` is `Rowid` with `OpenRead` p4 `0`. `SELECT rowid` from an ordinary table is the same opcode. `WITHOUT ROWID` opens cursor 1. Implicit binary key info is `k(1,)`, `COLLATE binary` is `k(1,B)`, `COLLATE NOCASE` is `k(1,NOCASE)`, and `DESC` is `k(1,-)`. `SELECT *` from `b AS (a+1)` is `IfNullRow` then `Add`. `INSERT INTO t(a INT) VALUES (1)` puts `D` on `MakeRecord`. `INSERT INTO t VALUES (1),(2)` is `InitCoroutine`. `db_browser_b3_explain_test.dart` matches `/tmp/sqlite-build/sqlite3` for those rows.
- An `INTEGER PRIMARY KEY` insert and `EXPLAIN SELECT 1 FROM (SELECT 1), (SELECT 2)` still throw `EXPLAIN bytecode is not implemented`. `EXPLAIN SELECT title` is `no such column: title` on the CLI. This is not a VDBE.
- That CLI's `sqlite_source_id()` is `2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`. This run's binary reports `COMPILER=gcc-13.3.0`. `manifest.json` records clang-22.1.3.
- `packages/sqlite_plus`: `dart format` passed. `dart analyze --fatal-infos` passed for the edited libraries. `dart test` passed 10596 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run.
- `examples/notes` exports and imports CSV and plots notes by UTC day. Those functions do not call the engine. `dart examples/notes/tool/note_exchange_check.dart` passed. This machine has no Flutter SDK, so the widgets were not executed. B5 stays unchecked. M9 stays unchecked. The scenario harness rejects a row count above 10000, and iOS, macOS, Windows, power loss, and pub.dev were not run here. Item 108 stays open. An official master journal stays open. This is not a full SQLite claim and not a DB Browser clone.

## 2026-11-02 — ORM row functions

- `@DbScalar()` marks an instance method or getter. The body reads mapped fields and takes no parameters. `selectWhere((row) => row.twice() > 20)` runs that body for each row. The context registers `table_method`. A null stored in a non-nullable field makes the call null. A thrown body fails the statement with `User function <name> failed`.
- A column, a JSON path, or a call accepts engine scalars, including `abs`, `upper`, `lower`, `length`, `trim`, `substr`, `replace`, `round`, `coalesce`, `ifNull`, `concat`, `sign`, `floor`, `ceil`, `sqrt`, `date`, `time`, `dateTime`, `unixEpoch`, and `julianDay`.
- `packages/sqlite_plus_orm`: `dart format` passed, `dart analyze --fatal-infos` passed, and `dart test` passed 185 tests on Dart 3.13.7, Linux x64. `packages/sqlite_plus_generator`: the same format and analysis passed, and `dart test` passed 58 tests. The engine package was not changed. M9 stays unchecked. Item 108 stays open. This is not a full SQLite claim.

## 2026-11-02 — Version 0.1.3

- `sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.3`. The ORM depends on `sqlite_plus: ^0.1.3`. The generator depends on `sqlite_plus_orm: ^0.1.3`. The three example projects use the same constraints and stay `publish_to: none`.
- The release notes cover incremental auto-vacuum, contentless FTS4, file `journal_mode` `wal`/`persist`/`truncate`, the three cross-schema `VALUES` errors, the bounded `EXPLAIN` shapes, the margin-notes CSV and plot helpers, and ORM row functions.
- The engine suite that covers this tree passed 10596 tests. The ORM suite passed 185 tests. The generator suite passed 58 tests. Those suites were not re-run for the version number itself. The example projects were not re-run.
- On the committed tree, `dart pub publish --dry-run` reported 0 warnings for `sqlite_plus` (690 KB), `sqlite_plus_orm` (504 KB), and `sqlite_plus_generator` (406 KB). This environment has no pub.dev credential, so nothing was uploaded.
- The pub.dev API lists `0.1.3` as latest for `sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator`. The uploads were accepted in that order. A package page can take up to 10 minutes to show the new version. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim.

## 2026-11-03 — ORM documents

- `@DbDocument()` stores one object as JSON text. `Codecs.document` calls the class `fromJson` and `toJson`. Nested objects are `Map<String, Object?>`. `DocumentField.path` binds `json_extract`. A query decodes the rows it returns. The model schema records `"document": true` and the column stays `TEXT`.
- The generator emits `Codecs.document` and `DocumentField`. `fromJson(Map<String, dynamic>)` is wrapped. A `String` field, a key, a version, a virtual table, and a missing `fromJson` or `toJson` are reported before a file is written. The part does not import another package.
- In this tree the same ORM is `0.1.4` and depends on `sqlite_plus` `^0.1.5`, beside `sqlite_plus_arabic` `0.1.0` and `sqlite_plus_vec` `0.1.0`. `sqlite_plus_generator` is `0.1.5`.

## 2026-11-03 — Arabic FTS and vec0 nearest neighbors

- `DbModules`, `DbTokenizers`, and `DbVectorMetrics` are documented `String` constants. `DbVectorLimits` documents 1 and 4096. `module`, `tokenizer`, and `metric` stay strings, so a name that is not in the list can still be written by hand. The ORM creates `fts5`, `rtree`, and `vec0`. An unknown module is rejected. An unknown tokenizer or metric identifier is kept until the table is created. `ForeignKeyAction`, `MigrationSafety`, `EntityState`, and `MigrationKind` stay enums.
- `tokenizers.register` adds an FTS tokenizer and rejects `unicode61`, `porter`, `trigram`, `ascii`, and `simple`. `VirtualTableModule.storesRows` creates a shadow table. `INSERT`, `UPDATE`, and `DELETE` write that table. `DROP` removes the shadows named by `ownedShadows`. A `MATCH` handler can answer a virtual table before FTS does.
- `sqlite_plus_arabic` 0.1.0 registers `arabic`. Diacritics and tatweel are removed. One prefix and one suffix are removed when three letters remain. A prefix that cannot be removed also keeps the suffix, so `الله` stays `الله`. `حديقة`, `الحديقة`, and `بالحديقة` share a token. `search('سيارة')` does not return a garden note. Token text uses one code unit per UTF-8 byte, the same representation as `unicode61`. `MATCH 'مرحبا'` still returns 2. This is not the ICU Arabic tokenizer.
- `sqlite_plus_vec` 0.1.0 registers `vec0`. One column is little-endian float32, dimensions 1 to 4096. `l2` is Euclidean distance. `cosine` is one minus cosine similarity. `column MATCH ? AND k = ?` scans every row. Engine `k` is 1 to 100000. ORM `nearest` accepts `k` from 1 to 4096. A `ROLLBACK` leaves the shadow empty. Reopening an image needs another `register`. This is not a sqlite-vec file and not an approximate index.
- The generator emits `tokenizer`, `Codecs.vector`, `search`, and `nearest`. The generated part does not import either package. A consumer that registers both packages saves four rows, finds `في الحديقة`, and returns the nearer vector. Unknown modules, a tokenizer off FTS5, a vector off `vec0`, dimensions outside 1 to 4096, and a reserved `distance` column fail before a file is written.
- `sqlite_plus` is `0.1.5`. `sqlite_plus_orm` is `0.1.4` and depends on `sqlite_plus` `^0.1.5`. `sqlite_plus_generator` is `0.1.5` and depends on `sqlite_plus_orm` `^0.1.4`.
- `dart format` passed in each of the five packages. `dart analyze --fatal-infos` passed for each. `dart test` passed 10609 engine tests, 188 ORM tests, 70 generator tests, 3 Arabic tests, and 4 vec tests on Dart 3.13.7, Linux x64. The Arabic example printed `في الحديقة | missed true | stable true`. The vec example printed `1.0 | stable true`. No wall-clock timing was run. No speedup is claimed.
- macOS, Windows, Android, iOS, and pub.dev were not run. This tree has not been uploaded. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim, not a full SQLCipher claim, not a sqlite-vec file, and not the ICU Arabic tokenizer.

## 2026-11-03 — SQLCipher 4 file codec

- `SqlCipherDatabase.create` and `open` keep a plaintext image whose reserve byte is 80. `encryptedImage` applies AES-256-CBC and HMAC-SHA512. PBKDF2-HMAC-SHA512 uses 256000 iterations by default. The HMAC key is PBKDF2 of the encryption key over the salt with each byte XOR `0x3a`, for 2 iterations. Page 1 stores a 16-byte salt and restores `SQLite format 3` after the HMAC matches. A wrong passphrase, a flipped byte, or a swapped page throws `SQLCipher page authentication failed` and does not return an image. A later export reuses the derived keys. `database.exportImage` is the decrypted image.
- `saveSqlCipher` replaces the whole file and flushes it. That write is not the rollback journal. `openInMemory` and `openDatabase` do not call the codec. The cell geometry of a reserve of 0 is the previous page size, so an unencrypted rebuild takes the same path. Fast page patches still return no image when the reserve is nonzero and the compact rebuild runs. Auto-vacuum together with a reserve is rejected.
- `test/fixtures/sqlcipher4-default.db` is SQLCipher 4.5.6 community with the default 256000 iterations. `sqlcipher4-kdf2.db` is the same CLI with `cipher_default_kdf_iter = 2`. Both open here and return `kept` and a value of length 3000. A file written here opens in that CLI, `integrity_check` is `ok`, and a raw `x'` key opens. An encrypted FTS5 `MATCH` and an R-tree box reopen. WAL files, SQLCipher 1–3, rekey, a plaintext header, and auto-vacuum with the reserve are unsupported.
- `packages/sqlite_plus` is version `0.1.4` and depends on `pointycastle` 4.0.0. `sqlite_plus_orm` stays `0.1.3`. `dart format` passed. `dart analyze --fatal-infos` passed. `dart test` passed 10607 tests on Dart 3.13.7, Linux x64. No wall-clock timing was run. No speedup is claimed. The ORM and generator suites were not re-run. This tree has not been uploaded. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLCipher claim, not a full SQLite claim, and not a DB Browser clone.

## 2026-11-03 — Documents, Arabic search, and vec0 in one tree

- `@DbDocument()` stores one object as JSON text beside the Arabic tokenizer and `vec0`. `row.card.path(r'$.title')` binds `json_extract`. A returned row is decoded. `Kept Garden` comes back with 320 pages. A later save writes pages 321 and revision 1. The other note stays at revision 0. `search('الحديقة')` returns `في الحديقة`. `nearest(const [0.9, 0.1], k: 1)` returns `[1.0, 0.0]`.
- `sqlite_plus` is `0.1.5`. `sqlite_plus_orm` is `0.1.4` and depends on `sqlite_plus` `^0.1.5`. `sqlite_plus_generator` is `0.1.5` and depends on `sqlite_plus_orm` `^0.1.4`. `sqlite_plus_arabic` and `sqlite_plus_vec` are `0.1.0`. The engine page lists each package with a reading-note example.
- `packages/sqlite_plus/lib` and `packages/sqlite_plus/test` match the revision that passed 10609 engine tests. That suite was not re-run. `dart format` in that package reported 0 changed files. `dart analyze --fatal-infos` passed.
- `packages/sqlite_plus_orm`: `dart format` passed, `dart analyze --fatal-infos` passed, and `dart test` passed 190 tests on Dart 3.13.7, Linux x64.
- `packages/sqlite_plus_generator`: `dart format` passed, `dart analyze --fatal-infos` passed, and `dart test` passed 78 tests.
- `packages/sqlite_plus_arabic`: `dart format` passed, `dart analyze --fatal-infos` passed, and `dart test` passed 3 tests.
- `packages/sqlite_plus_vec`: `dart format` passed, `dart analyze --fatal-infos` passed, and `dart test` passed 4 tests.
- Each package example passed `dart analyze --fatal-infos` and 1 test: the engine tour, the reading log, the generated library, the Arabic garden note, and the nearest vector.
- The earlier Arabic entry's 188 ORM tests and 70 generator tests are that revision before `@DbDocument` was merged. The document-only counts are not the counts of this tree.
- macOS, Windows, Android, iOS, and pub.dev were not run. This tree has not been uploaded. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim, not a full SQLCipher claim, not a sqlite-vec file, and not the ICU Arabic tokenizer.

## 2026-11-03 — Database browser

- `browser/` is a Flutter program beside `packages/`. It is not a workspace member. The screen lists `sqlite_schema`, pages a table 50 rows at a time, edits a cell by `rowid`, deletes a row, and runs one statement. A window at least 900 wide keeps the schema beside the rows. A narrower window uses a drawer and a Rows / SQL bar. Open reads the picked file bytes into `MutableSqliteDatabase.fromImage`. Save writes `exportImage()`. A WAL image is still rejected with `Writer requires a complete rollback-format database image`. A `WITHOUT ROWID` table is readable and is not edited from the cell dialog. Blob cells show their length.
- Add sample rows creates `books` and inserts Kept Garden, 320 pages, and Other Atlas, 40 pages. The grid test shows Kept Garden and `Memory · unsaved`. The SQL test creates `books`, sees `0 changed`, inserts one row, sees `1 changed`, and changes 320 to 321.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 6 tests: 4 session tests and 2 widget tests. `flutter build linux` was not run. This machine has CMake and Clang and does not have `gtk+-3.0` or Ninja. Android, iOS, macOS, and Windows were not launched. This is not a claim that the program opens every official SQLite file. M9 stays unchecked. B5 stays unchecked. Item 108 stays open.

## 2026-11-03 — Browser arm64 APK

- `flutter build apk --release --target-platform android-arm64` produced one release package. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `1`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 19405861 bytes, sha256 `7c09e4e709cf487d66e021caab354429547e1ff6923be124296bac11159be66d`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The build finished at 21:40 Asia/Hebron on 3 November 2026. The release type is signed with the Android debug keystore. The launcher label is `sqlite_plus_browser`.
- `file_picker` 8.3.7 declares compileSdk 34. `browser/android/build.gradle.kts` raises every Android library module to 36 so `flutter_plugin_android_lifecycle` can link. The engine suites were not re-run. The package was not installed on a device or an emulator. iOS, macOS, and Windows were not launched. The package is committed at `browser/dist/sqlite-plus-browser-arm64-v8a.apk` so it can be downloaded. Other `*.apk` files stay ignored. M9 stays unchecked. B5 stays unchecked. Item 108 stays open.

## 2026-11-03 — Browser schema, pages, and SQL completion

- The schema tree lists each table with its columns, type, primary key, and NOT NULL mark, and nests that table's indexes under it. Views and triggers stay in their own sections.
- A table page uses `MutableSqliteDatabase.browse` and asks for one extra row. A full page of 50 leaves `total` at `-1` and does not scan `count(*)`. The next page is the remaining rows. `countRows` fills the exact total once and keeps it until a write. The grid builds rows as they scroll.
- The SQL editor completes the word at the cursor from keywords, tables, views, and columns. `SEL` offers `SELECT`. `FROM bo` offers `books`. `books.` offers that table's columns. Text inside quotes offers nothing. `CREATE TABLE` does not offer an existing table name.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 9 tests: five session tests, one completion test, and three widget tests. The sample grid shows Kept Garden, the schema shows PK and TEXT, and `SEL` inserts `SELECT`.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 22:00 Asia/Hebron on 3 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `2`, minSdk `24`, targetSdk `36`, and `native-code: arm64-v8a`. The file is 19537521 bytes, sha256 `74f77b02d79ae81d7268893cc3ef869cf7a7df8d51fce852c064b9b4cc63f9b2`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open.

## 2026-11-03 — Browser completion popup and schema detail

- The SQL popup lists only the tokens that can follow the text at the cursor, then filters that list by the prefix being typed. An empty statement offers the starting keywords. `SEL` offers `SELECT`. `SELECT title` offers `FROM` and `AS`. `FROM` offers tables and views. `books.` offers that table's columns. A shared column name is qualified. Text inside quotes offers nothing. `CREATE TABLE` does not offer an existing table name. Choosing a row replaces the prefix and adds a trailing space.
- The schema rail lists tables, indexes, views, and triggers. Each table shows column type, default, primary key, and NOT NULL, foreign keys with ON DELETE or ON UPDATE when the action is not NO ACTION, unique indexes with their columns, and the triggers on that table. The data page repeats those facts above the grid.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 10 tests: six session tests, one completion test, and three widget tests. The schema test reads a default of `'Kept'`, `author_id` referencing `authors.id` with ON DELETE CASCADE, unique index `idx_title` on `title`, and trigger `tr` on `books`.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 22:32 Asia/Hebron on 3 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `3`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 19537685 bytes, sha256 `a3045209cba915e409f480f41d2973b65822adce0fa2f69eda3bdd7be5b340d6`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-03 — Structure tree, page filter, and SQL log

- The schema pane is a structure tree with columns Name, Type, and Schema. The folders are Tables, Indices, Views, and Triggers, each with a count. A table expands to its columns. The schema cell for a column is the definition: quoted name, type, PRIMARY KEY, NOT NULL, DEFAULT, and REFERENCES with ON DELETE or ON UPDATE when the action is not NO ACTION. The table row shows its CREATE statement on one line. Create table and Create index drop a draft into the SQL editor.
- The data grid has a filter field under each column. The filter applies to the rows already loaded on the current page. The pager sits under the grid: first, previous, the range, next, last, and go to a page. The SQL page keeps the last 12 statements that ran.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 10 tests: six session tests, one completion test, and three widget tests. The sample screen shows `Tables (1)`, `Indices (0)`, `Views (0)`, `Triggers (0)`, PK, TEXT, `"title" TEXT NOT NULL`, and `"id" INTEGER PRIMARY KEY`.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 22:40 Asia/Hebron on 3 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `4`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 19537765 bytes, sha256 `f5ec31265030fa925835e2349ad09efc533c5b7747608bcc4b32a563429de3fb`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-03 — SQL result pages

- A `SELECT`, `VALUES`, or `WITH` read that has no outer `LIMIT` is executed with `LIMIT 51 OFFSET n` through `browse`. The grid shows 50 rows. A full page means another page follows, and that page is the next offset. `LIMIT` inside a subquery, a quote, or a comment does not count as the outer limit. A statement that already has an outer `LIMIT` runs as written, and the grid still pages those rows 50 at a time. A trailing semicolon is removed before the page limit is added.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 12 tests: seven session tests, one completion test, and four widget tests. `SELECT n FROM nums` on 55 rows returns `0` through `49`, then `50` through `54`.

## 2026-11-03 — Formatted SQL code view

- The create-statement dialog formats the stored SQL before showing it. A `CREATE TABLE` or `CREATE INDEX` puts the header on one line and each column or indexed expression on its own line, so `PRIMARY KEY` stays together. The view uses JetBrains Mono, line numbers, and separate colors for keywords, types, strings, and numbers. The font file is `browser/fonts/JetBrainsMono-Regular.ttf` under the SIL Open Font License, with `browser/fonts/OFL.txt`.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 13 tests: eight session tests, one completion test, and four widget tests. The sample dialog shows `id INTEGER PRIMARY KEY` and `title TEXT NOT NULL` on their own lines.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 23:19 Asia/Hebron on 3 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `6`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 19731940 bytes, sha256 `abd541ece5a5cd76b05cdef152f59c14202e8539f08ea922d1dbfaa66471011d`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 23:14 Asia/Hebron on 3 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `5`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 19537765 bytes, sha256 `3b64fc0280540997fa1989d4dbd14faceca14b59d1e624d41d8e2d51c86f8ece`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-03 — SQL editor code view

- The SQL editor uses the same JetBrains Mono code view as the create-statement dialog: a dark panel, line numbers, and colors for keywords, types, strings, and numbers. The field text is transparent so the highlight stays under the caret.
- Formatting runs at a boundary. A newline indents by the open-paren depth. A comma inside parentheses starts an indented line. A balanced `)` or `;` formats the statement, so a finished `CREATE TABLE` keeps each column, including `PRIMARY KEY`, on one line. A space after a clause keyword formats too and keeps that space, so `SELECT ` stays `SELECT `. A prefix such as `SEL` is left as typed. An unclosed `CREATE` is not collapsed.
- The completion popup lists only the next valid token. It sits beside the caret, uses a short row for each token, and closes when the tap is outside the editor and the menu. A tap on a row still inserts that token.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 14 tests: nine session tests, one completion test, and four widget tests. `SEL` inserts `SELECT `. A tap on the statement title closes the popup. `SELECT n FROM nums` on 55 rows still pages 50 then 5.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 23:33 Asia/Hebron on 3 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `7`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 19731940 bytes, sha256 `e2119562f5d9481b169b8ce4be289c0d89d6b3852013556999e31506d2455e7a`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-03 — Typed cell editor

- The cell dialog follows the declared column type. `INTEGER` is a whole number with minus and plus. `REAL`, `FLOAT`, `DOUBLE`, `NUMERIC`, and `DECIMAL` take a decimal. `TEXT` is a multiline field. `BOOLEAN` is on or off and stores 1 or 0. `DATE`, `TIME`, and `DATETIME` keep a text value and open a date or time picker. A `NOT NULL` column does not offer NULL. A blob value still reports its length and stays out of the dialog.
- The dialog is a white card. The column name sits beside a type chip. Save is a filled button.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 16 tests: ten session tests, one completion test, and five widget tests. The pages cell shows `INTEGER`, the stepper changes 320 to 321, and save stores 321. A `REAL` cell shows `Decimal number`, a `TEXT NOT NULL` cell hides the NULL switch, and `BOOLEAN`, `DATE`, `TIME`, and `DATETIME` open their own controls.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 23:42 Asia/Hebron on 3 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `8`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 20125616 bytes, sha256 `c039812df62f0b1b8de47ccf8562f6882561985c9cef64d41c23edf84b3f7c4f`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQL caret alignment

- The highlighted SQL and the text field share one font. That font does not inherit the theme, and its letter spacing is zero. A text field otherwise keeps the Material body letter spacing of half a pixel per character, so the caret and the selection move ahead of the glyphs. On `CREATE INDEX idx_name ON events (` that shift was 6.625 pixels at `events`. With the shared font the caret and the highlighted word start at the same horizontal position, within one pixel.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 21 tests: eleven session tests, one completion test, and nine widget tests.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 00:14 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `10`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 20322464 bytes, sha256 `02142dc9ab49ed79a2d0b98a8a5fcd43813eb6c025d5189a146d73a2fa91d20e`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Phone SQL screens, create forms, and a schema graph

- On a narrow window the SQL page is two screens. Query holds the statement, the run button, and the log. Result holds the grid and its pager. Run moves to the result when a new statement finishes. A wide window still shows the editor and the grid together.
- Create table and Create index open a form. The table form takes a name and columns, and a key control marks the primary key. One key is a column primary key. Several keys become a table-level primary key. The index form takes the table, the columns, and unique. A blank index name becomes `idx_<table>_<columns>`. The statement runs immediately and the SQL editor stays closed.
- Graph draws each table as a card and a curve for each foreign key. Link, then a column in another table, adds a new nullable column: `ALTER TABLE child ADD COLUMN ... REFERENCES parent(column)`. The engine does not add a primary key to a column that already exists, so primary keys are chosen in the new-table form.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 20 tests: eleven session tests, one completion test, and eight widget tests. A 400-wide window hides the grid until the statement runs, then hides the editor on the result screen. The form creates `notes` and `idx_notes_title` without opening `sql-input`. Linking `books` to `authors.id` stores `authors_id` and shows `→ authors.id`.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 00:06 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `9`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 20322464 bytes, sha256 `429cb71a5422c7b38f108b8a10fead6645a2eae48f89b057fce71b43280c1793`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Statement progress

- Running a statement or applying a create form paints a card before the work starts. The card says Running, shows the statement, and has an indeterminate circular indicator and a progress bar in the same green as the app. The work waits until that card has been painted, so a heavy `CREATE INDEX` does not freeze the screen with no signal. The card closes when the statement finishes. Turning a page of a result that is already loaded does not show it.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 23 tests: eleven session tests, one completion test, and eleven widget tests. `CREATE TABLE pace (id INTEGER)` shows the Running card, then `0 changed` and `schema-table-pace`.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 00:20 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `11`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 20322464 bytes, sha256 `48f0cd0f97ad37c20f5e74d9c205b17ae302df47c56ff726564f127f1a6c0853`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Add a column to an existing table

- Add column opens a form. It takes the table, the column name, the type, NOT NULL, a default, and an optional reference to another column. The statement is `ALTER TABLE ... ADD COLUMN` and it runs without opening the SQL editor. A `NOT NULL` column needs a default so the rows already stored receive a value. A reference leaves those rows null and does not take another default. A name that already exists on the table is refused. A primary key still belongs to the new-table form, because the engine rejects adding a primary key column.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 25 tests: twelve session tests, one completion test, and twelve widget tests. Adding `note` to `events` as `TEXT NOT NULL` with default `Kept` stores that column. The save button stays disabled until the default is entered.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 00:29 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `12`, minSdk `24`, targetSdk `36`, compileSdk `36`, and `native-code: arm64-v8a`. The file is 20453536 bytes, sha256 `c364f635ed7c8a76baffc0b416110a76a05d0cc006b42c7d4149769b78df4c75`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Index facts, home, and the Sqlite Browser name

- An index page shows its entry count and its size. The engine has no `dbstat` table. The count is every cell in that index, including a key promoted onto an interior page, and the size is the pages that walk reaches, including overflow, times the page size. An empty index is 0 entries. An index over 300 rows is 300 entries. A partial index `WHERE value > 0` on that table is 299 entries.
- The launcher name and the window title are Sqlite Browser. The open file is the line under that title. The launcher mark is an original teal tile with a dark card of three rows and a gold key.
- With no database open, the first screen offers Open and the recent files. New is beside Open. A readable path is opened from that path again. A phone URI that cannot be read later falls back to a copy kept with the list. Android registers VIEW for the sqlite mime types and for `.db`, `.sqlite`, `.sqlite3`, and `.db3`, and the activity reads the URI on the first launch and on a later intent. That association was not tried on a device.
- Create table is a plus beside Tables, Add column is a plus beside each table, and Create index is a plus beside Indices. The new-table form puts each column on a card: name, type, key, and NOT NULL.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 27 tests: thirteen session tests, one completion test, and thirteen widget tests. The home screen reopens `sample.db` and shows `kept`.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 07:24 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `13`, minSdk `24`, targetSdk `36`, compileSdk `36`, application-label `Sqlite Browser`, and `native-code: arm64-v8a`. The file is 20814667 bytes, sha256 `9c6245477812e7cc96561169fb11adc465cb34053ed853f6774751361dddbd0e`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQLite Browser mark, progress, and the graph board

- The launcher name is SQLite Browser. The mark is an ink field, a cream table grid, one emerald cell, and a short link. The home screen, the schema tree, the app bar, and the graph board use that ink and emerald.
- The Running card is inserted on the root overlay, so a create from the open schema drawer still shows it. The card is painted before the statement runs.
- The graph board pans horizontally and vertically. Dragging a table moves that table. Tapping a column, then a column on another table, opens a confirmation and writes nothing until Confirm. The parent column has to be a primary key or a unique column, and the child column must not already have a foreign key. sqlite_plus cannot add `REFERENCES` to an existing column with `ALTER TABLE`, so Confirm rewrites that table inside a transaction, copies the rows, and creates the indexes and triggers again. A failure rolls the transaction back. Linking `books.title` to `authors.id` keeps the row `Kept` and the index `idx_books_title`, and the card shows `→ authors.id`. `authors.name` is refused.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 30 tests: fifteen session tests, one completion test, and fourteen widget tests. Dragging `books` moves its card. Panning the empty board moves every card. Creating an index with the schema drawer open hit-tests the Running card.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 07:55 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `14`, minSdk `24`, targetSdk `36`, compileSdk `36`, application-label `SQLite Browser`, and `native-code: arm64-v8a`. The file is 20784887 bytes, sha256 `3ef7e68dc760ab7c9f34229b5e7e310569ac25d84e01c22b4d8810756b9513c6`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Clear messages, column menus, graph zoom, and the light mark

- A result is a card. An error such as `UNIQUE constraint failed` is red with white text. A saved change is emerald. A row count is blue. Dismiss clears the card. The text stays `0 changed` and `1 changed`.
- The always-visible filter row is gone. Each column header opens A to Z, Z to A, a search of the whole table, and Clear. Sort is `ORDER BY` with `COLLATE NOCASE`. Search is `instr(lower(CAST(column AS TEXT)), ?)`, so ASCII letters fold and the match covers every page, not only the 50 rows on screen. The SQL result grid has no column menu. `lower()` folds A–Z only.
- The graph still pans and still drags a table. Pinch, the plus and minus buttons, and Ctrl or Meta with the wheel zoom the board. The scale stays between 0.45 and 2.6, and the zoom keeps the point under the gesture.
- The launcher mark is a cream field, an emerald database cylinder, and a feather. The adaptive background color is `#FFF6F1E6`. The name stays SQLite Browser.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 32 tests: sixteen session tests, one completion test, and fifteen widget tests. Sorting `pages` ascending puts 40 before 320. Searching `title` for `kept` returns one row, `Kept Garden`, and the unfiltered count stays 2. Zooming in widens the graph board.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 08:10 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `15`, minSdk `24`, targetSdk `36`, compileSdk `36`, application-label `SQLite Browser`, and `native-code: arm64-v8a`. The file is 20855055 bytes, sha256 `e7300dc5c495db2e5bc9b89f14248c38d03f71122f8b3e43cbba3be4ddfd5925`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Graph targets and closing a database

- The graph board no longer shows the instruction paragraph. Choosing a column disables every column that cannot be the parent of that foreign key, and highlights each column that can. A parent is the table's only primary key, a one-column unique index, or `UNIQUE` on that column. A table-level primary key of several columns is not a single-column parent. A column that already has a foreign key leaves no parent available. Tapping the chosen column again clears it. Confirm still writes nothing until it is pressed.
- The overflow menu item Close database returns to the home screen. Unsaved changes ask first. Stay keeps the database open. Continue closes it and clears the unsaved mark.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 34 tests: seventeen session tests, one completion test, and sixteen widget tests. After `books.title` is chosen, `authors.name` and `books.id` do not accept a tap, and `authors.id` does. Close database on a dirty image stays open for Stay and returns home for Continue.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `15`, 20855055 bytes, sha256 `e7300dc5c495db2e5bc9b89f14248c38d03f71122f8b3e43cbba3be4ddfd5925`, built at 08:10 Asia/Hebron on 4 November 2026. That package does not include this graph behavior or Close database. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Delete confirmation and column types in completion

- Deleting a row opens a warning first. Cancel leaves the row. Delete removes it. Running a statement whose first word is `DELETE` or `DROP` opens the same kind of warning, and the statement runs only after Delete or Drop.
- A column in the completion popup shows its declared type in a green chip, such as `INTEGER` or `TEXT`. The word `column` is no longer the caption when a type is known.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 36 tests: seventeen session tests, one completion test, and eighteen widget tests. Cancel on the first row of `books` keeps `Kept Garden`. Confirming removes it. `DELETE FROM books` waits for confirmation, and confirming reports `1 changed`. `SELECT books.` offers `id` as `INTEGER`, `title` as `TEXT`, and `pages` as `INTEGER`.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `15`, 20855055 bytes, sha256 `e7300dc5c495db2e5bc9b89f14248c38d03f71122f8b3e43cbba3be4ddfd5925`, built at 08:10 Asia/Hebron on 4 November 2026. That package does not include the delete warning or the column type chip. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQLite Browser versionCode 16

- One arm64 package now carries the browser changes that were tested separately: colored notices, per-column sort and search, graph zoom, the cream cylinder-and-feather mark, highlighted link targets, Close database, a warning before a row delete or a `DELETE` or `DROP` statement, and the declared column type on a completion.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 36 tests: seventeen session tests, one completion test, and eighteen widget tests. That run was the one recorded before this package, on the same sources apart from the build number.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 08:50 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `16`, minSdk `24`, targetSdk `36`, compileSdk `36`, application-label `SQLite Browser`, and `native-code: arm64-v8a`. The file is 20855239 bytes, sha256 `f8b68071ff136717e130bf1b076adb793ed1d02aaba97066a4df4f388c8f7fcd`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Dart classes for the open database

- The overflow menu item Dart classes writes one library for the open tables. Each ordinary table becomes an `@DbEntity` class. `@DbEntity(table:)` keeps the SQL table name. `@DbColumn(name:)` keeps a SQL column name that is not the Dart field name. A single integer primary key is `BigInt?` with `@DbKey(generated: true)`. A column `UNIQUE` stays `unique: true`. A one-column foreign key is `@DbReference`, including `ON DELETE`. A foreign key of several columns, a table with no primary key, a virtual table, its internal tables, a view, and a trigger stay in comments. The dialog lists the four steps: save `lib/models.dart`, add `sqlite_plus_orm` and `sqlite_plus_generator`, run `dart run sqlite_plus_generator --input lib/models.dart`, then open `DbContext(connection, generatedModel)` and `ensureCreated`. Copy and Save are on the dialog. The same steps are comments at the top of the file.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 38 tests: seventeen session tests, one completion test, one model export test, and nineteen widget tests. `authors.name` is unique, `books.author_id` references `Authors` with `ON DELETE CASCADE`, `cover` is `Uint8List?`, and `pair` has `@DbKey(order: 0)` and `@DbKey(order: 1)`. `docs` and its internal tables and the view `names` are comments. The dialog shows `class Books` and the generator command.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `16`, 20855239 bytes, sha256 `f8b68071ff136717e130bf1b076adb793ed1d02aaba97066a4df4f388c8f7fcd`, built at 08:50 Asia/Hebron on 4 November 2026. That package does not include Dart classes. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQLite Browser versionCode 17

- One arm64 package now carries Dart classes with the browser changes already in versionCode `16`: colored notices, per-column sort and search, graph zoom, the cream cylinder-and-feather mark, highlighted link targets, Close database, a warning before a row delete or a `DELETE` or `DROP` statement, and the declared column type on a completion. Dart classes writes one `@DbEntity` class for each ordinary table and shows the four generator steps.
- The Linux tests for this package are the run recorded with the Dart classes change: `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 38 tests. That run was on these sources apart from the build number.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 09:42 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `17`, minSdk `24`, targetSdk `36`, compileSdk `36`, application-label `SQLite Browser`, and `native-code: arm64-v8a`. The file is 20855239 bytes, sha256 `aaef3885f27d298ee53ba34533485d25bf9c34d3a811fe7705a774033f3f2102`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQLite Browser versionCode 18

- Dart classes keeps the steps behind How to use. Opening it shows four numbered cards: save the file under `lib/` (for example `lib/models.dart`, with related classes in that one library), add `sqlite_plus_orm` and `sqlite_plus_generator`, run `dart run sqlite_plus_generator` from the package root, and open `lib/sqlite_plus_migrations.g.dart`. Each ordinary table is its own card, with the class name, the SQL table, a field count, and the source. Classes that the generator does not own stay under Not generated.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 38 tests: seventeen session tests, one completion test, one model export test, and nineteen widget tests. That run was on these sources apart from the build number. How to use is closed at first. Opening it shows `dart run sqlite_plus_generator`. The Books card shows `class Books`. `authors`, `books`, and `pair` are separate cards, and the virtual table and the view stay in the notes.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 10:04 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `18`, minSdk `24`, targetSdk `36`, compileSdk `36`, application-label `SQLite Browser`, and `native-code: arm64-v8a`. The file is 20855471 bytes, sha256 `67127ebb601bb81313f00003cdfd44daba763ed4f08d4b7ad78580b307d50f5a`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Schema drawer returns to the open object

- The schema drawer is built again each time it opens, so the list was starting at the top. Opening it now scrolls to the selected table, view, index, or trigger. A selected object that is already in view stays where it is. The folder that contains it is open.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 39 tests: seventeen session tests, one completion test, one model export test, and twenty widget tests. On a 420 by 740 window, opening `t9` and opening the drawer again shows `t9` and leaves `t0` above the list.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `18`, 20855471 bytes, sha256 `67127ebb601bb81313f00003cdfd44daba763ed4f08d4b7ad78580b307d50f5a`, built at 10:04 Asia/Hebron on 4 November 2026. That package does not scroll to the open object. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Shorter schema list

- The side list no longer has Type and Schema columns. A column shows a symbol for its type, the declared length when the type has one, and PK when it is a key. `NVARCHAR(160)` shows the text symbol and `160`. A reference shows a link symbol. The create statement stays on the open table.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 40 tests: seventeen session tests, one completion test, one model export test, and twenty-one widget tests. On a 420 by 740 window, `cities.name` shows `160` inside the drawer, and the word Schema is absent. The sample `title` is a text symbol, and `id` and `pages` are number symbols. `id` still shows PK. Adding `note` stores `"note" TEXT NOT NULL DEFAULT 'Kept'` in the create statement.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `18`, 20855471 bytes, sha256 `67127ebb601bb81313f00003cdfd44daba763ed4f08d4b7ad78580b307d50f5a`, built at 10:04 Asia/Hebron on 4 November 2026. That package still shows Name, Type, and Schema. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — New, Open, and Save in the more menu

- The three bar icons move into the more menu, each with its icon. Save stays disabled until a database is open. The title keeps the width those buttons used.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 41 tests: seventeen session tests, one completion test, one model export test, and twenty-two widget tests. On a 420 by 740 window the title `SQLite Browser` is fully visible. The more menu lists New, Open, and Save, and Save is enabled for an open database.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `18`, 20855471 bytes, sha256 `67127ebb601bb81313f00003cdfd44daba763ed4f08d4b7ad78580b307d50f5a`, built at 10:04 Asia/Hebron on 4 November 2026. That package still shows New, Open, and Save as bar icons. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQLite Browser versionCode 19

- One arm64 package now carries the browser changes that landed after versionCode `18`: the schema drawer scrolls to the open object, the side list is one column with a type symbol and the declared length, New, Open, and Save are in the more menu, and a foreign key or an index is shown in that list instead of above the rows. Dart classes, the colored notices, the column menus, graph zoom, Close database, the delete confirmation, and the column type on a suggestion stay in this package.
- The Linux tests for this package are the run recorded with the schema-list links: `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 41 tests. That run was on these sources apart from the build number.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 11:32 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `19`, minSdk `24`, targetSdk `36`, compileSdk `36`, application-label `SQLite Browser`, and `native-code: arm64-v8a`. The file is 20855943 bytes, sha256 `ef0976bead769070ef57253dea729e9082f2e1fac43bc03a818e652b34762e7e`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Relationships sit in the schema list

- The links that sat above the rows now live in the schema list. A foreign key is a line under its column, `→ artists.ArtistId`, and an index shows its columns, `IFK_AlbumArtistId (ArtistId)`. ON UPDATE and ON DELETE appear on that line when they are not NO ACTION. The rows page no longer shows that strip.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 41 tests: seventeen session tests, one completion test, one model export test, and twenty-two widget tests. After `books.title` references `authors.id`, the schema list shows `→ authors.id` and the rows page does not show `title → authors.id`.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `18`, 20855471 bytes, sha256 `67127ebb601bb81313f00003cdfd44daba763ed4f08d4b7ad78580b307d50f5a`, built at 10:04 Asia/Hebron on 4 November 2026. That package still shows those links above the rows. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Column sizes and related rows

- The new-column form is grouped into the column, its rules, and an optional reference. Cancel and Add stay at the bottom. Text takes a length and is stored as `VARCHAR(n)`. An integer takes a digit count, `INTEGER(n)`. Real and numeric take digits and decimal places, such as `REAL(10, 2)`. A size that is not a whole number cannot be saved.
- A column that references another table has a button in its header. The button loads the rows of that table which match the values on this page and shows that one table directly under the column. Opening another column replaces it. When the column references more than one column, the form asks which one the rows should use.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 44 tests: eighteen session tests, one completion test, one model export test, and twenty-four widget tests. `amount` is stored as `REAL(10, 2)`. The related rows of `books.author_id` show Ada and not Grace. A column that references both `authors.id` and `people.id` asks which one to use, and loading `people.id` shows Person.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `19`, 20855943 bytes, sha256 `ef0976bead769070ef57253dea729e9082f2e1fac43bc03a818e652b34762e7e`, built at 11:32 Asia/Hebron on 4 November 2026. That package still uses the plain new-column form and has no related-rows button. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQL course

- Learn SQL is on the home screen and in the more menu. Twelve levels run from reading rows through filters, order, changes, tables, patterns, summaries, joins, subqueries, indexes, views, and one report. Each level shows examples with the result of running them, then three questions, then one statement. The program runs that statement on a fresh database and compares the result. The next level opens only after the level is passed. Progress is stored in `course.json` beside the recent files. The course runs on sqlite_plus. It is a practical path, not every SQLite feature.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 48 tests: eighteen session tests, one completion test, one model export test, four course tests, and twenty-four widget tests. Every example runs. Every official statement passes. An empty statement, two statements, a query written for a change, a change written for a query, a mismatched result, and a reversed order are rejected. A wrong answer stays on the question. `SELECT 1` reports `The result does not match.` Passing the first level opens Filtering rows and leaves the following level locked.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `19`, 20855943 bytes, sha256 `ef0976bead769070ef57253dea729e9082f2e1fac43bc03a818e652b34762e7e`, built at 11:32 Asia/Hebron on 4 November 2026. That package has no Learn SQL screen, and it still uses the plain new-column form with no related-rows button. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQLite Browser versionCode 20

- One arm64 package now carries the browser changes that landed after versionCode `19`: the new-column form takes a text length or a digit count, a reference column opens one related table under that column, and Learn SQL is on the home screen and in the more menu. The schema list, the more menu, Dart classes, the colored notices, the column menus, graph zoom, Close database, the delete confirmation, and the column type on a suggestion stay in this package.
- The Linux tests for this package are the run recorded with the SQL course: `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 48 tests. That run was on these sources apart from the build number. It includes the column-size form, the related-rows table, and the twelve course levels.
- `flutter build apk --release --target-platform android-arm64` replaced the downloadable package at 12:33 Asia/Hebron on 4 November 2026. `aapt dump badging` reports `dev.sqliteplus.sqlite_plus_browser`, versionName `1.0.0`, versionCode `20`, minSdk `24`, targetSdk `36`, compileSdk `36`, application-label `SQLite Browser`, and `native-code: arm64-v8a`. The file is 21118287 bytes, sha256 `d891c7e212d7aec9deebef12ec4d7b98cb3677663d422ce5de82356033f5f877`. `lib/arm64-v8a` contains `libapp.so` and `libflutter.so`. The release build is signed with the Android debug keystore. It was not installed on a device or an emulator. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Linux opens SQLite files

- Starting the program on Linux registers SQLite Browser for `application/vnd.sqlite3` and `application/x-sqlite3`. The user MIME database gains `*.db`, `*.sqlite`, `*.sqlite3`, and `*.db3`. The desktop entry names this program as the handler for those types. A file path on the command line, including a `file:` URI, opens that database.
- Flutter 3.47.9, Dart 3.13.7, Linux x64. `flutter analyze --fatal-infos` reported no issues. `flutter test` passed 52 tests: eighteen session tests, one completion test, one model export test, four course tests, four Linux file tests, and twenty-four widget tests. `desktop-file-validate` accepts the installed entry. The MIME cache lists both SQLite types. `library.db` passed at startup shows Opened Book.
- The arm64 package was not rebuilt. The downloadable file remains versionCode `20`, 21118287 bytes, sha256 `d891c7e212d7aec9deebef12ec4d7b98cb3677663d422ce5de82356033f5f877`, built at 12:33 Asia/Hebron on 4 November 2026. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Browser course editor, schema rail, SQL log, and graph layout

- Learn SQL keeps the twelve graded levels. The practice field now uses the SQL page editor: JetBrains Mono, live coloring, formatting at a clause boundary, and suggestions from the tables that step creates. Examples use the same colors. Moving between the level list, examples, questions, and practice fades the new step in. A wrong answer still stays on that question, and the next level still opens only after the level is passed.
- On a wide window the schema rail starts at half the width. Dragging the divider changes it, clamped between 0.22 and 0.75 of the window and leaving room for the work. A narrow window still keeps the schema in the drawer.
- Statements that run are listed on a Log tab in the wide switch and in the narrow bar. The SQL page no longer shows that list. The list still keeps the latest 12 statements and clears when the database closes.
- Schema graph card positions are stored in `graphs.json` in the app data folder: `$HOME/.sqlite-browser` on desktop, and the documents `sqlite-browser` folder on Android. The key is the database path or content URI, not the image bytes. Opening that file again restores the cards. A table another program removed or renamed is dropped. A new table is placed beside the ones that remain, and that reconciled layout is written back. Column changes do not move a card. A memory database has no path, so its arrangement is not stored. Saving a memory database to a path starts storing under that path. The layout is not written into the database file.
- Flutter 3.47.9, Dart 3.13.7, Linux x64: `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 54 tests at 13:46 Asia/Hebron on 4 November 2026. Eighteen session tests, one completion test, one model export test, five course tests, two graph-layout tests, and twenty-seven widget tests. The versionCode `20` package was not rebuilt. It does not include this polish. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — Linux file association and browser polish together

- The Linux file registration and the browser polish are both on `main`. Opening a SQLite file from the Linux file manager still reaches this program, and the course editor, the half-width schema rail, the Log tab, and the saved graph layout stay. A file path is still the key for `graphs.json`.
- Flutter 3.47.9, Dart 3.13.7, Linux x64: `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 58 tests at 13:51 Asia/Hebron on 4 November 2026. Eighteen session tests, one completion test, one model export test, five course tests, four Linux file tests, two graph-layout tests, and twenty-seven widget tests. The versionCode `20` package was not rebuilt. It does not include the Linux registration or this polish. `flutter build linux` was not run: this machine does not have `gtk+-3.0` or Ninja. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite file browser.

## 2026-11-04 — SQLCipher CLI absence

- `SQLCipher 4.5.6 reads a file this engine encrypted` skips when `sqlcipher` is not on `PATH`. `Process.run` throws `ProcessException` in that case, and a non-zero version command still skips. With SQLCipher 4.5.6 community on the path, the same test passed at 15:58 Asia/Gaza (UTC+2) on 4 November 2026. With the CLI hidden, the test reported `sqlcipher is not installed` and skipped at 15:59 Asia/Gaza.

## 2026-11-04 — Package pages at 0.1.7

- `sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.7`. `sqlite_plus_arabic` and `sqlite_plus_vec` are version `0.1.1` and depend on `sqlite_plus` `^0.1.7`. `sqlite_plus_geo` is version `0.1.0` and depends on `sqlite_plus` `^0.1.7` and `sqlite_plus_orm` `^0.1.7`. Each README links the six package pages on pub.dev and includes a short example of each library.
- The browser Dart-class steps name `sqlite_plus` `^0.1.7`, `sqlite_plus_orm` `^0.1.7`, and `sqlite_plus_generator` `^0.1.7`. The program still links the engine by path. The versionCode `20` archive was not rebuilt.
- pub.dev already served `sqlite_plus` `0.1.6`, `sqlite_plus_orm` `0.1.6`, `sqlite_plus_generator` `0.1.6`, `sqlite_plus_arabic` `0.1.0`, and `sqlite_plus_vec` `0.1.0` before this note. `sqlite_plus_geo` was not on pub.dev.

## 2026-11-04 — Tables without a primary key

- The Dart classes export now owns an ordinary table that has no `PRIMARY KEY`. The class key is the SQLite row id: `BigInt?` with `@DbKey(generated: true)`. The SQL name is `rowid`. If that name is already a column, the name is `oid`, then `_rowid_`. A table that already uses all three names stays in the Not generated notes. A `WITHOUT ROWID` table whose primary key was not detected stays there too. A declared integer primary key is unchanged.
- The ORM adopts that table without rebuilding it. A generated integer key named `rowid`, `oid`, or `_rowid_` is the implicit row id when `table_xinfo` has no primary key and does not list that name. `plan()` does not ask for a new column. A table that already has a primary key, a `WITHOUT ROWID` table, and any other missing column still need a reviewed migration. Saving a new row, changing one, and deleting one through that key was checked on `boundary(name TEXT)`.
- `packages/sqlite_plus_orm`: `dart analyze --fatal-infos` reported no issues and `dart test` passed 191 tests on Dart 3.13.7, Linux x64. `browser/`: `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 59 tests at 15:35 Asia/Hebron on 4 November 2026. Eighteen session tests, one completion test, two model export tests, five course tests, four Linux file tests, two graph-layout tests, and twenty-seven widget tests. The versionCode `20` package was not rebuilt. It still leaves a table with no primary key in a comment. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim.

## 2026-11-04 — sqlite_plus_geo

- `packages/sqlite_plus_geo` 0.1.0 is a Pure Dart spatial library on `sqlite_plus` 0.1.5 and `sqlite_plus_orm` 0.1.4. It registers spatial SQL through `SqlFunctionRegistry` and stores geometry as EWKB. The spatial index is the existing `rtree` virtual table. Boxes written to that index are expanded to enclosing float32. `GeoSession.search`, `nearest`, and `join` read the index once and then apply the exact predicate. `EXPLAIN QUERY PLAN` does not show that index. `SpatialPlan.describe()` does. `ST_SetSRID` assigns metadata. `ST_Transform` transforms EPSG:4326, EPSG:3857, and WGS84 UTM zones 32601–32660 and 32701–32760. Another datum throws. Planar distance stays in the stored axes. Sphere and spheroid distances are metres and, for the registered SQL distance functions, points. The engine, ORM, and generator sources were not changed. The generator does not emit a geometry field. The codec is `sqlite_plus_geo/orm.dart`.
- Names that are not implemented stay unregistered: `ST_Polygonize`, ellipsoidal polygon area, and spheroidal distance for a non-point. Shapefile, KML, GPX, FlatGeobuf, and GeoPackage are not in this package. This is not an OGC, PostGIS, SpatiaLite, or GeoPackage certification.
- Dart 3.13.7, Linux x64, 15:19 Asia/Hebron on 4 November 2026. `dart format --output=none --set-exit-if-changed .` passed. `dart analyze --fatal-infos` reported no issues. `dart test` passed 42 tests. The example analyzed clean, its one test passed, and `dart run bin/main.dart` printed `Clinic | North | 2 | 2.0 | true`.
- `dart run benchmark/bench.dart --size 1000` at 15:16 Asia/Hebron wrote `packages/sqlite_plus_geo/benchmark/results/linux_x64_1000.json`. Host Linux cursor, 6.12.94+, x86_64. Dataset: 1,000 uniform points in a 1000 by 1000 square, seed 20261104. Query polygon `(0,0)-(50,0)-(50,50)-(0,50)`, five repetitions. Indexed insert 27899442 µs. Unindexed insert 3416027 µs. Indexed query samples 21524, 23053, 24984, 34426, 36254 µs, median 24984, candidates 4. Unindexed query samples 8341, 8967, 9898, 10398, 10694 µs, median 9898, candidates 1000. Both returned 4 rows. RSS after the process was 365453312 bytes and is not a sampled peak. Sizes 10000, 100000, and 1000000 were not run. No speedup is claimed.
- The arm64 browser package was not rebuilt. It remains versionCode `20`, 21118287 bytes, sha256 `d891c7e212d7aec9deebef12ec4d7b98cb3677663d422ce5de82356033f5f877`, built at 12:33 Asia/Hebron on 4 November 2026. It does not include this package. `flutter build linux` was not run. iOS, macOS, and Windows were not launched. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim.

## 2026-11-04 — pub.dev 0.1.7 and sqlite_plus_geo

- Pulled `main` at `1bf0838`. Uploaded `sqlite_plus` `0.1.7`, `sqlite_plus_orm` `0.1.7`, `sqlite_plus_generator` `0.1.7`, `sqlite_plus_arabic` `0.1.1`, `sqlite_plus_vec` `0.1.1`, and `sqlite_plus_geo` `0.1.0`. The pub.dev API lists those versions as latest. A package page can take up to 10 minutes to show them.
- The engine and ORM archives also keep `DatabaseClient.inTransaction`, `DbSet.openMemory`, and `DbSet.openDbFile` from the published `0.1.6` packages. Those files are still local modifications. The git worktree was dirty, so the upload used `dart pub publish --force`. These files are not committed.
- `dart analyze --fatal-infos` reported no issues for all six packages. `sqlite_plus_geo` `dart test` passed 42 tests. `database_owner_test.dart` passed 9 tests. The ORM file-open and migration tests passed 34 tests. The full engine suite was not re-run. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim, not a full SQLCipher claim, and not an OGC or GeoPackage certification.

## 2026-11-05 — File open and the clinic shelf

- `DatabaseClient.inTransaction`, `DbSet.openMemory`, and `DbSet.openDbFile` are in this tree. They were already in the published `0.1.6` and `0.1.7` archives. `sqlite_plus_search` is `0.1.0-dev.3` and its README walks a clinic shelf: diacritic folding, a bound shelf filter, an insert seen by `autoUpdate`, Arabic light stemming, and a hybrid rank from an exact fixture map. A missing fixture string fails. This is not a language model. The search package was not uploaded in this note. `sqlite_plus_arabic` `0.1.2` and `sqlite_plus_vec` `0.1.2` were not uploaded in this note. `dart analyze --fatal-infos` passed for the search package and its example. The example test and the search suite were not re-run for this note. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim.

## 2026-11-02 — Package-wide generator

- `sqlite_plus_generator` is version `0.1.4` and depends on `sqlite_plus_orm` `^0.1.3`. `sqlite_plus` and `sqlite_plus_orm` stay `0.1.3`. `dart run sqlite_plus_generator` from a package root scans `lib/` and writes a part for every public `@DbEntity` class. A class with only a conventional `id` stays out of that scan. `--input lib/models.dart` still selects that class. The command also writes `lib/sqlite_plus_migrations.g.dart`. Its `generatedModel` collects every selected entity and foreign key for `ensureCreated`, `plan`, and `applySafe`. The command does not open a database. A `@DbReference` target still has to be a `@DbEntity` class in the same library. Each output carries a source stamp. A later run prints what it found, leaves a matching part unchanged, and does not resolve that library again. The run ends with a summary of created, updated, unchanged, and stale files.
- `packages/sqlite_plus_generator`: `dart format` passed, `dart analyze --fatal-infos` passed, and `dart test` passed 60 tests on Dart 3.13.7, Linux x64. `dart pub publish --dry-run` reported 0 warnings and a 411 KB archive. The pub.dev API lists `sqlite_plus_generator` `0.1.4` as latest. `sqlite_plus` and `sqlite_plus_orm` remain `0.1.3`. A package page can take up to 10 minutes to show the new version. The engine and ORM suites were not re-run. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim.

## 2026-11-02 — Direct table open

- `DbSet.openMemory(type)` opens a memory database, creates that table, and returns the set. `saveChanges`, `migrations`, and `close` forward to its context. `close` releases the whole context. `DbContext(connection, model)` and `context.set` stay for an existing connection or more than one table. This is not in the published `sqlite_plus_orm` `0.1.3`.
- `packages/sqlite_plus_orm`: `dart format` passed, `dart analyze --fatal-infos` passed, and `dart test` passed 187 tests on Dart 3.13.7, Linux x64. The reading-log example passed its one test. The engine and generator suites were not re-run. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim.
- The reading-log example no longer writes `EntityType`. `@DbEntity(table: 'books')` on `Book`, plus `@DbJson()` and `@DbVersion()`, is the mapping. `dart run sqlite_plus_generator --input lib/reading_log.dart` writes `BookMapping`. `Column` and `EntityType` remain for a hand-written mapping. The example test passed again after that generation.

## 2026-11-02 — File table open

- `DbSet.openDbFile(type, path)` is the file form of `DbSet.openMemory` on the same class. A missing database file and a missing `-journal` are created. An existing database file is not replaced, so a later open keeps its rows. Passing `directoryEntriesDurable: false` writes nothing and throws. That flag remains a caller attestation, not a power-loss result. On the Web the call throws `UnsupportedError`. `DbSet.openMemory`, `DbContext`, and `openDatabase` stay. This is not in the published `sqlite_plus_orm` `0.1.3`.
- `DatabaseClient.inTransaction` reports whether that client owns an open transaction, including after a SQL error that rolls the transaction back.
- `packages/sqlite_plus_orm`: `dart format` passed, `dart analyze --fatal-infos` passed, and `dart test` passed 191 tests on Dart 3.13.7, Linux x64.
- `packages/sqlite_plus`: `dart analyze --fatal-infos` on the owner files passed, and `dart test --reporter failures-only` passed 10543 tests with 26 skipped. The skips print `pinned sqlite3 is not installed`. The generator suite was not re-run. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim.

## 2026-11-03 — pub.dev 0.1.6 and the two new packages

- `sqlite_plus` `0.1.6`, `sqlite_plus_orm` `0.1.6`, and `sqlite_plus_generator` `0.1.6` are uploaded. `sqlite_plus_arabic` `0.1.0` and `sqlite_plus_vec` `0.1.0` are uploaded. The pub.dev API lists those versions as latest. A package page can take up to 10 minutes to show them. `0.1.5` stayed the earlier upload, so the SQLCipher codec, `@DbDocument`, Arabic search, and `vec0` went out as `0.1.6` and `0.1.0`. The git worktree was dirty. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim, not a full SQLCipher claim, not a sqlite-vec file, and not the ICU Arabic tokenizer.

## 2026-11-02 — Version 0.1.5

- `sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.5`. The ORM depends on `sqlite_plus` `^0.1.5`. The generator depends on `sqlite_plus_orm` `^0.1.5`. Each package README links to the other two at `https://pub.dev/packages/sqlite_plus`, `https://pub.dev/packages/sqlite_plus_orm`, and `https://pub.dev/packages/sqlite_plus_generator`. The pub.dev API lists `0.1.5` as latest for all three. A package page can take up to 10 minutes to show that version. The upload used `dart pub publish --force` because the git worktree was dirty and the engine and ORM versions skipped `0.1.4`. These files are not committed.
- The ORM README and `packages/sqlite_plus_orm/example/lib/shared_shelf.dart` show `DbSet.openMemory`, `DbSet.openDbFile`, two types on one memory `DbContext`, a second file open rejected with `StateError`, a second `saveChanges` rejected with `OrmStateException`, and two queries that both finish. The example test passed 4 tests on Dart 3.13.7, Linux x64. The engine and generator suites were not re-run for this version bump. M9 stays unchecked. B5 stays unchecked. Item 108 stays open. This is not a full SQLite claim.

## 2026-10-31 — Version 0.1.2

- `sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.2`. The logo is the feather, the database, and the plus. A Linux desktop release build of Bench compared 1,000 rows with sqflite through FFI. Every checksum matched. The package charts are that sample. No new engine suite was run for this note.
- M9 stays unchecked. Item 108 stays open.

## 2026-10-29 — Version 0.1.0

- `sqlite_plus`, `sqlite_plus_orm`, and `sqlite_plus_generator` are version `0.1.0`. The ORM depends on `sqlite_plus: ^0.1.0`. The generator depends on `sqlite_plus_orm: ^0.1.0`. `openInMemory` and `openDatabase` are the familiar names in this release. The previous names remain. `0.0.3` is still the newest version on pub.dev until this release is uploaded.
- M9 stays unchecked. Item 108 stays open.

## 2026-11-04 — Search integration inspection

- Created feature/sqlite-plus-search and documented engine/Arabic/vec integration,
  filtered vector candidate correctness, connection ownership and transactional
  change-log design. No runtime code changed in this milestone; format, analysis
  and tests are not applicable to this documentation-only commit.
- Search implementation and real multilingual model integration remain pending.

## 2026-11-04 — Search scaffold and local embedding boundary

- Added workspace package and local embedding interface; deterministic lookup
  fixture is explicitly not a semantic model. Validate dimensions, finite/nonzero
  vectors and float32 overflow/underflow using sqlite_plus_vec codecs.
- Dart 3.13.7/Linux: offline pub resolution, format, fatal-info analysis and 3
  tests passed. CLI required XDG_CONFIG_HOME=/tmp/sqlite-search-config with CI=true;
  analyzer state redirected with ANALYZER_STATE_LOCATION_OVERRIDE. Home stayed
  unchanged. No production model, search release or benchmark claims.

## 2026-11-04 — Search lexical foundation

- Added configurable Arabic mark/alef/ya/hamza and digit normalization, optional
  existing Arabic light stemming, and escaped literal MATCH expressions. General
  Unicode tokenization and BM25 remain in sqlite_plus, avoiding duplicate engines.
- Dart 3.13.7/Linux: format, fatal-info analysis and 7 search tests pass, including
  English BM25 ordering, Arabic normalization/stemming and Greek/CJK retrieval.
  These tests establish lexical behavior only, not multilingual semantics.

## 2026-11-04 — Persistent keyword search facade

- Added existing-table indexing, persisted metadata/mapping/FTS, schema/analyzer
  guards, atomic explicit rebuild, filtered exact candidates and deterministic
  pagination. Per-database facade queue rejects caller-owned transactions.
- 15 search tests pass on Dart 3.13.7/Linux, with format, fatal-info analysis and
  runnable example. Reopen, failed-rebuild rollback, mapping recovery, source edits
  followed by explicit rebuild and quoted/text keys are covered. Physical crash
  injection is not covered. Engine metadata reads use NOT INDEXED after reproducing
  stale empty unique lookups inside transactions; regression retained.

## 2026-11-04 — Search local vector integration

- Persist float32 embeddings/model identity; exact eligible-vector cosine ranking
  reuses sqlite_plus_vec codecs/distance without vec0's k/post-filter recall trap.
- Format, fatal-info analysis and 17 tests pass on Dart 3.13.7/Linux. New tests
  cover synthetic vector ranking, filtered top-k, persistence/model mismatch and
  atomic rollback on provider failure. Production semantic model still pending.

## 2026-11-04 — Search hybrid fusion

- Added RRF, optional component-rank/base-score explanations and deterministic
  hybrid pagination after filtering. No keyword fallback for missing embeddings.
- Format, fatal-info analysis and 19 tests pass on Dart 3.13.7/Linux, including
  duplicate/missing rank arithmetic and filtered hybrid retrieval. Real-model
  multilingual integration remains pending.

## 2026-11-04 — Search bounded local rank learning

- Two-feature bounded logistic feedback updates a collection-local linear rank
  adjustment. Persisted/versioned parameters support reset/export/validated import;
  duplicate labels are rejected and context history is capped at 1000 returned hits.
- Format, fatal-info analysis and 21 tests pass on Dart 3.13.7/Linux. Synthetic
  feedback moves a judged result from rank 2 to 1 (MRR .5 -> 1, NDCG@10
  .6309297535714574 -> 1); this is not held-out semantic quality. Evaluation fixtures
  cover known Recall@10/MRR/NDCG@10. Embedding weights are never trained.

## 2026-11-04 — Search incremental synchronization

- Transactional source triggers capture changed keys. Searches coalesce and replay
  only affected records/embeddings atomically, acknowledging only processed log
  entries. Missing triggers fail explicitly. Source records remain application-owned.
- Format, fatal-info analysis and 23 tests pass on Dart 3.13.7/Linux: insert/update/
  delete, unchanged-column suppression, primary-key changes, rollback, pending-log
  reopen and failed-provider retry. No physical crash-injection coverage. Source
  key lookup scans and secondary-unique REPLACE coverage remain limitations.

## 2026-11-04 — Search evaluation and AOT scale gate

- Added known Recall@10/MRR/NDCG@10 fixtures, language-analyzer extension contract,
  malformed-input/model-limit checks and an initial-write batch boundary regression.
- The per-record AOT implementation timed out at 120 seconds for 1000 records.
  Batching initial writes in groups of 100 completed: 7.901779 s indexing, median
  warm keyword 81.981 ms, hybrid 93.300 ms, update+replay+hybrid 2881.557 ms,
  feedback 2.142 ms. Raw results/host details are committed in the search benchmark
  directory. Memory backend, synthetic 2D provider, one shared-host Linux process.
- 10000 records reached source creation and timed out during indexing at 180 s;
  100000 similarly timed out at 60 s. No completed metrics for either. 1000000
  not practical before scale work. Benchmark milestone remains incomplete.
- 27 deterministic search tests pass with format/fatal-info analysis. Existing
  vec/Arabic tests: 4/3 pass. Relevant engine suites: 30 pass, 3 skipped because
  the pinned native SQLite executable is unavailable. Full engine suite not run.

## 2026-11-04 — Search documentation, example and CI configuration

- Added Linux/macOS/Windows deterministic search CI and JavaScript compilation.
  Remote CI was not run. The VM example demonstrates synthetic hybrid retrieval,
  local feedback and automatic insert indexing. Root package/status docs updated.
- JavaScript compilation succeeds but Node 24.19.0 execution fails on engine FTS
  insertion with UNIQUE constraint failed: rowid. tool/fts_js_repro.dart reproduces
  this using only sqlite_plus and passes on the VM. Browser support is explicitly
  blocked, rather than inferred from compilation. No engine SQL code was changed.
- Development version remains unpublished. Production local embedding runtime,
  real-model multilingual evaluation, large-scale optimization, cross-platform
  execution and physical crash-injection gates remain open. No network, native
  bindings, telemetry, automatic downloads or embedding-weight training were added.

## 2026-11-04 — Search hardening H1: crash boundaries

- Replaced permissive malformed-embedding assertions with ArgumentError checks;
  float32 overflow is now normalized to that documented public validation boundary.
- Added 12 crash scenarios covering 80 injected storage-operation failures across
  rebuild, incremental replay and feedback, delete/persist journals and both volatile
  and immediate persistence. Check atomic index/log and weight/label publication,
  successful retry and repeated recovery/integrity. This is a storage fault model,
  not a claim of real-device power-loss validation or every torn-byte pattern.
- Tests exposed that rollback after a failed commit masked the original storage
  error on the poisoned engine. Preserve the original error/stack during cleanup.
- Format, fatal-info analysis and all 39 search tests pass on Dart 3.13.7/Linux.

## 2026-11-04 — Search hardening H2: JavaScript runtime

- Fixed FTS5 block IDs: JavaScript truncates segid << 37 to 32-bit operations;
  multiplication by 137438953472 preserves the supported IDs. Added exact boundary
  arithmetic tests. No tokenizer/ranking or SQL syntax semantics were changed.
- Built official SQLite 3.53.1 manually as development-only tooling; source ID is
  the exact repository pin. 66 targeted engine FTS/oracle tests pass, including
  native leaf comparisons/cross-open integrity. Engine/search fatal-info analysis
  and formatting pass. Full engine suite is also running; not yet claimed passed.
- A shared assertion program passes on Linux VM and compiled JavaScript/Node
  24.19.0. Covers multilingual lexical queries, filter-before-vector-top-k, RRF,
  learning, rollback, incremental updates, index/model reopen, reset/import.
  CI executes it. Actual browser persistence and other OS runs are still open.

## 2026-11-04 — Search hardening H3: adversarial correctness

- All 56 deterministic search tests pass. New coverage compares 24 seeded edit/
  savepoint sequences against fresh rebuilds in all three modes; coordinates two
  handles around blocked/failed inference and proves independent databases progress;
  evaluates disjoint held-out synthetic queries/documents and an unchanged control.
- Nine corruption/rebuild cases cover mapping, zero/short vectors, missing FTS rows,
  corrupt FTS blocks/posting index, metadata and same-named trigger replacement.
  Explicit verifyIndex checks a persisted SHA-256 fingerprint. crypto is pure Dart;
  verification is read-only/full-scan, never an automatic per-query penalty.
- Corrupt stored vectors and JSON metadata now fail clearly. Invalid provider
  metadata is rejected even for empty collections; changing provider identity during
  inference and original provider failure propagation are tested.
- Secondary-unique REPLACE previously left displaced index entries with recursive
  triggers off. Replay now reconciles missing source keys; regression passes.
- Format/fatal-info analysis pass, 80 crash fault points remain verified (including
  recovered integrity baselines), and updated JavaScript/Node assertions pass.

## 2026-11-04 — Search hardening H4: indexing and final gates

- Index format 2 loads normalized content before one external-content FTS rebuild;
  batches contain 1000 derived records. Explicit rebuild is required for earlier
  development indexes. Source data is never migrated. The engine's positional
  external-content loader requires body first after the rowid alias; regression,
  native comparison and VM/Node tests verify the owned schema arrangement.
- Replay replaces FTS/vector rows once, uses typed key equality where suitable,
  and exposes synchronize. Tests verify coalesced inference count, NOCASE key
  changes, explicit old-format rejection/rebuild and the 1000-row batch boundary.
- Added real 1001-hit retention/expiry and repeated-feedback influence-bound tests.
  61 search tests pass (60 deterministic plus optional pinned-native integration).
  Format/fatal-info analysis and offline enforced-lockfile resolution pass.
- Full engine rerun: 10609 pass, 1 skip, with exact pinned SQLite 3.53.1. Initial
  sandboxed run had 9 loopback socket permission errors; affected tests and full
  rerun with required local socket permission pass. Updated VM/Node assertions pass.
- Actual AOT, synthetic 2D/memory/shared Linux: 1000 indexing 2.549333 s; 10000
  indexing 26.926220 s (historical attempt timed out at 180 s). 100000 still times
  out during indexing at 120 s; 1000000 not practical yet. Raw results and source
  hashes are committed. No concurrent test load was deliberately run during samples.
- Performance remains a release blocker: 10000 source update 12.795218 s, replay
  20.004185 s. Logical embedding updates are incremental, but underlying physical
  FTS/trigger persistence still reserializes data. No production-scale claim.
- Production embeddings/real-model multilingual quality, broader platforms, real
  browser IO, external-writer ownership and real-device/torn-byte crash gates remain
  open. No automatic model download, native binding or runtime network was added.

## 2026-11-05 — Search reuses arabic and vec

- `ArabicText.normalize` in `sqlite_plus_arabic` 0.1.2 owns the mixed-text fold:
  wider diacritics, optional ya and hamza, Arabic-Indic digits, and optional
  light stemming of Arabic runs. `ArabicTokenizer` output is unchanged. Search
  calls that function. Greek and CJK stay in the string, so search FTS remains
  `unicode61`.
- `rankVec0` in `sqlite_plus_vec` 0.1.2 scores requested `vec0` row ids before any
  neighbor limit and reads the shadow table in pages of 64. An empty id list
  reads nothing. `embedding MATCH ? AND k = ?` is unchanged and still applies `k`
  before a later predicate. A `MATCH` scan retains embedding bytes for the
  returned neighbors rather than a second copy of every stored blob.
- `sqlite_plus_search` 0.1.0-dev.2 stores embeddings in `vec0`, calls `rankVec0`,
  and drops the parallel vector table. Index format 3 rejects earlier development
  indexes until explicit `indexTable`. `open` does not rebuild a stored index.
  Keyword `MATCH` is not joined to other tables: that join returns no rows in
  this engine, so only match ids are resolved against the source filter.
- Local verification on Dart 3.13.7, Linux, after `dart format` and
  `dart analyze --fatal-infos`: arabic 4 tests, vec 5 tests, search 61 tests.
  The pinned SQLite external-content check is included in those 61. Format 2 AOT
  numbers were not remeasured. No speed claim. Packages were not published.
  Android, iOS, and a browser persistence backend were not run. B5, M9, and item
  108 remain unchecked. The database browser APK was not rebuilt.

## 2026-11-05 — Search query and index cost

- Keyword and semantic search no longer use a correlated `EXISTS` against the
  source table. An intermediate build that did was slower than format 2 on
  queries and was not kept. The recorded run loads source keys and the internal
  id map with two scans.
- `browse` stops a single-table window when the predicate is a rowid lower bound
  (`>`, `>=`, or the rowid alias) and `ORDER BY` follows the table. `query` is
  unchanged and still reads its input. Unfiltered `rankVec0` uses those stopped
  pages of 512. Source indexing uses the same window at 1000 rows.
- Non-contentless-delete FTS5 leaves pack many documents. The writer finds the
  longest prefix that fits by doubling, instead of re-encoding after every
  document. Contentless-delete stays one segment per row. A one-row sync still
  rewrites every posting. Native FTS5 and FTS3/4 pin tests that were run still
  pass.
- Format 3 AOT, Dart 3.13.7, Linux x64, memory, synthetic 2D, one process,
  five warm samples. 1000: index 1.189207 s, median warm keyword 49.681 ms,
  vector 36.054 ms, hybrid 62.974 ms, source update 359.419 ms, sync 616.455 ms,
  image 184320 bytes, RSS 51392512, peak 79622144. 10000: index 20.311424 s,
  median warm keyword 455.066 ms, vector 348.888 ms, hybrid 639.255 ms, source
  update 3008.387 ms, sync 5319.037 ms, image 1110016 bytes, RSS 77606912, peak
  226885632. Raw JSON is `linux_1000_format3.json` and
  `linux_10000_format3.json`. Format 2 numbers stay in RESULTS.md. A 100000-record
  attempt was stopped after 16 minutes while indexing; no metrics are reported.
  1000000 was not started. RSS is one sample.
- Local checks after `dart format` and `dart analyze --fatal-infos`: search 61
  tests, vec 5 tests, the FTS5 pin, the FTS3/4 pin, the search-engine tests, the
  rowid-window browse test, and the page-write tests. The full engine suite was
  not re-run. This performance edit has no new remote CI. Packages were not
  published. Android, iOS, and a browser persistence backend were not run. B5,
  M9, and item 108 remain unchecked. The database browser APK was not rebuilt.

## 2026-11-05 — Search row edits

- Ordinary commits can publish several changed rowid tables by page patch or a
  one-table rewrite. Untouched tables stay in the image. A WITHOUT ROWID table
  is rewritten only while it is still one index leaf. A changed unique key, a
  schema change, or a failed patch still rebuilds the image.
- External-content FTS replace of explicit nonnegative row ids edits the leaf
  that holds each row when the new leaf fits, plus averages and that docsize
  row. Empty leaves, prefixes, contentless-delete, and a leaf that no longer
  fits fall back to a full posting rebuild. `DELETE` of one `rowid` uses the
  same path.
- Single-token AND/OR `MATCH` can score from postings and docsize. `bm25()`
  with no column weights returns that stored score. Highlight still
  re-tokenizes the stored text. The all-matching benchmark did not show a warm
  query-time change outside the earlier format 3 range.
- AOT, Dart 3.13.7, Linux x64, memory, synthetic 2D, one process, five warm
  samples. 1000: index 1.092900 s, median warm keyword 48.142 ms, vector
  34.815 ms, hybrid 60.049 ms, source update 2.415 ms, sync 227.408 ms, image
  184320 bytes, RSS 49893376, peak 79724544. 10000: index 19.658282 s, median
  warm keyword 474.704 ms, vector 339.157 ms, hybrid 624.415 ms, source update
  27.872 ms, sync 2.117051 s, image 1110016 bytes, RSS 75509760, peak
  237608960. Raw JSON is `linux_1000_row_edits.json` and
  `linux_10000_row_edits.json`. The earlier format 3 numbers stay in
  RESULTS.md. 100000 was not started again; the earlier attempt was stopped
  after 16 minutes while indexing. 1000000 was not started. RSS is one sample.
- Local checks after `dart format` and `dart analyze --fatal-infos`: search 61
  tests, the native FTS integration test, the FTS5 pin, the FTS3/4 pin, the
  search-engine tests, the rowid-window browse test, and the page-write tests.
  The full engine suite was not re-run. Vec tests were not re-run; vec code
  did not change. No new remote CI. Packages were not published. Android, iOS,
  and a browser persistence backend were not run. B5, M9, and item 108 remain
  unchecked. The database browser APK was not rebuilt.

## 2026-11-05 — Search unique-key append and incremental sync

- A new unique key whose rowid is past the current maximum is appended to the
  table and inserted into the unique index. Unrelated tables stay in the image.
  An empty table, empty index, view, or trigger is appended to the schema leaf
  when the new schema row fits. Overflow schema rows, populated indexes, and
  autoincrement sequences still use the compact rebuild. Indexing creates the
  empty search shadows before it loads keys, so those creates do not serialize
  a filled key table.
- `autoUpdate` keeps a census. When it matches `count(*)`, sync reads only the
  pending keys. A mismatch still scans mapping and source keys, which covers a
  REPLACE that deletes an unlogged row. The integrity baseline is version 2, an
  order-independent sum of per-row hashes. That sync adjusts the changed key,
  docsize, and vector rows and rehashes the other owned shadows. `verifyIndex`
  still reads every derived row. A version 1 baseline fails until an explicit
  rebuild. The census is not part of the fingerprint. Restoring a transaction
  snapshot no longer treats the pre-change image as if it already held the
  saved rows.
- AOT, Dart 3.13.7, Linux x64, memory, synthetic 2D, one process, five warm
  samples. Times are Asia/Hebron (UTC+2) on 5 November 2026. 1000: index
  0.300666 s, median warm keyword 48.229 ms, vector 23.061 ms, hybrid 49.161
  ms, source update 2.587 ms, sync 191.076 ms, image 192512 bytes after index
  and at the end. 10000: index 4.704192 s, median warm keyword 475.981 ms,
  vector 215.387 ms, hybrid 498.088 ms, source update 35.599 ms, sync 1.699659
  s, image 1216512 bytes after index and 1118208 bytes at the end. 100000:
  index 75.807267 s, median warm keyword 5510.411 ms, vector 2444.129 ms,
  hybrid 5822.828 ms, source update 481.015 ms, sync 17.883826 s, image
  12226560 bytes after index and 11067392 bytes at the end. RSS is sampled
  after the source load, after indexing, after the warm queries, after sync,
  and at the end; peak RSS is 80805888, 225472512, and 633675776. Raw JSON is
  `linux_1000_append.json`, `linux_10000_append.json`, and
  `linux_100000_append.json`. The earlier row-edit and format 3 numbers stay
  in RESULTS.md. The 1,000,000 run exited 255 after 2914 seconds and wrote no
  result, so it has no timings. Every benchmark
  document matches the query, so query time still grows with the collection.
  The sync image is smaller than the post-index image, so that step still
  compacts the database.
- Local checks after `dart format` and `dart analyze --fatal-infos`: search 61
  tests and the full engine suite, 10614 tests. Vec tests were not re-run; vec
  code did not change. No new remote CI. Packages were not published. Android,
  iOS, and a browser persistence backend were not run. B5, M9, and item 108
  remain unchecked. Search release validation stays unchecked. The database
  browser APK was not rebuilt.
