## 0.1.14

Prepared for pub.dev. This version is not uploaded.

Linux x64, Dart 3.13.7, 12 November 2026 (Asia/Hebron): format and `dart analyze --fatal-infos` were clean. The engine suite passed 10811 tests and skipped 1 because the `sqlcipher` command is not installed. The same run passed ORM 259, Inspector 55, generator 78, Arabic 4, vec 5, geo 42, search 86, changes 41, sync 60, reactive 9, branch 49, jobs 55, and 10 example tests. Optimizer assertions passed on the Dart VM and on JavaScript.

No schema or file-format change. Integers stay `BigInt`. The production runtime stays Pure Dart. Query plans can differ from 0.1.13. Repaired results match pinned SQLite 3.53.1 in the recorded suites. This release does not claim SQLite optimizer equivalence, zero overhead, or the close of M9 and item 108. `sqlite_stat4` planning, skip-scan, index intersection, hash join, and flattening a correlated subquery into a join are not implemented. Most planner changes still have an open cost gate. Item 23's physical index seek is limited to two ordinary rowid tables and one single-column secondary index; other joins keep the previous path.

### Query planner

- A direct forward index scan can satisfy `ORDER BY`. A full reverse scan can satisfy a descending order. An ordered `LIMIT` with no `WHERE` stops early. An unordered table scan with `LIMIT` and no `WHERE` also stops. A filter still reads the rows it must check.
- A non-covering index that `sqlite_stat1` says will visit every row stays a table scan. Equal estimates prefer an order-providing plan, then a covering plan. Inclusive `BETWEEN` is two bounds.
- An automatic plan may use a partial index when a numeric comparison is stronger than the predicate and the column affinity is numeric. `INDEXED BY` still needs the exact predicate.
- A leading `IN` list or same-column `OR` of constants seeks each distinct value, at most 32, after collation and affinity agree. A longer list stays on the previous path.
- `WITHOUT ROWID` can use a secondary index. The primary tree is not reported as that seek.
- A `sqlite_stat1` range estimate is at least the next equality average. Stat text longer than 65536 characters is ignored. A recorded table cardinality is not inflated by a sibling index.
- `AND` and `OR` follow SQLite's context: a scalar keeps required operand evaluation, and a filter can skip a side that cannot change the result.
- Two to four simple cross joins with table statistics are ordered from the smallest. Five stay in the written order. Wildcard columns and `ORDER BY` ordinals keep that written order.
- An eligible two-table `INNER JOIN` reads the secondary B-tree for each distinct outer key. Denser indexes, explicit scans, and shapes outside that scope keep a scan or a temporary lookup. The temporary lookup holds at most 1024 distinct keys. `EXPLAIN` says `USING INDEX` for the physical seek and `USING TEMPORARY LOOKUP` for the memory path.
- An uncorrelated single-table `EXISTS` stops at the first match. An uncorrelated scalar subquery runs once. Two identical side-effect-free scalars share one result. `probe()` stays a separate call. A correlated subquery still runs per outer row.
- A repeated CTE runs once unless it is `NOT MATERIALIZED`. A derived `LIMIT` stays inside the derived query. An unused bare column of a derived query can become `NULL`; a function in that list stays.
- Ordered `DISTINCT` compares the previous row. `GROUP BY` sorts only when a new group arrives out of order.
- `MIN` and `MAX` of an unshadowed integer primary key read one end. `COUNT` and a filtered aggregate still read the input.
- Plain `count`, `sum`, `avg`, `total`, `min`, and `max` keep a running value. `DISTINCT`, `ORDER BY` inside the aggregate, user aggregates, and a bare grouped column still keep the group rows.
- Arithmetic with no column, parameter, or function becomes its value. `CAST` affinity and explicit collation stay. A false numeric filter on one direct table skips the scan; `count(*)` of that filter is 0. A function in the filter still runs.
- `WHERE a = ?` still chooses the index after the value is bound. Plans are computed for the current catalog and are not cached, so `ANALYZE` affects the next statement.
- `diagnoseQuery` can report an index seek, a one-end primary-key extreme, and `SEARCH` for a plain inner join. A join that calls a function still rejects before the callback.

### Explicit bounded query diagnostics

- Add opt-in read-only/mutable diagnoseQuery for supported scalar SELECTs.
- Bounded planner decisions, existing estimates and actual row/page/sort metrics;
  unavailable counters remain null and metadata excludes SQL/bindings/results.
- Preserve routing/exclusion; reduce redundant diagnostic BLOB copies with
  pre-await isolation tests. Measured scope/costs: workspace diagnostics evidence.

### Bounded ORDER BY/LIMIT selection

- Replace repeated linear worst-candidate search with a lazy in-place max-heap
  for eligible capacity >=32, retaining tie/projection/fallback behavior.
- No schema/API/dependency change; no reduced-page-read claim. Native/full/VM/JS
  verification and AOT benefits/control costs: `doc/OPTIMIZER.md`.

### Optional prepared statements

- Connection-bound reusable syntax with fresh bindings and schema invalidation.
- Typed ORM prepared reads/updates and optional bounded cache (default disabled).
- Existing adapter interception/capture paths retained; unsupported shapes fall back in ORM.
- See `doc/PREPARED.md` and workspace prepared benchmarks for measured scope.

### Guarded writes and job processing

- Narrow conservative integer rowid AND predicates while rechecking the original
  WHERE; retain callback/subquery/coercion/generated-column fallbacks.
- Reuse resolved index-column offsets and skip unchanged shared records during
  index-preservation checks, retaining value and constraint validation.
- Fix stale live equality-read indexes after prepared ordinary INSERT, including
  RETURNING; preserve the existing append-order read cache.
- No schema/file-format change. Evidence: ../../benchmark_results/jobs_performance/README.md.

### UPSERT/import performance

- Preserve successful row preparation during UPSERT conflict updates; avoid
  whole-database validation for eligible unchanged unique keys.
- Use SQL-comparator conflict trees and lazy row slots for ordinary UPSERTs.
  Retain constraint/trigger/FK and complex-index fallback behavior.
- No persistent schema or file-format change. Measured scope and limitations:
  [AOT evidence](../../benchmark_results/import_performance/README.md).

## 0.1.13

Cursor `page` on `openDatabase`, UTF-16 `NOCASE` and `RTRIM` comparisons, and narrower trigger reads. The README shows the next page of `notes.db`.

## Built-in collation correctness

- Compare NOCASE/RTRIM in UTF-8 regardless of database text encoding; preserve
  BINARY ordering. NOCASE keeps SQLite's shared-NUL/full-byte-length rule.
- Native comparisons and cross-open integrity cover UTF-8/UTF-16LE/UTF-16BE.
- Existing affected indexes may require explicit REINDEX after backup; no
  automatic index/schema rewrite is performed.

## Built-in pagination

- Integrated keyset `.page()` API with forward/backward portable cursors.
- Multi-column ASC/DESC, NULL placement, key tie-breakers and query-scope validation.
- Engine/read-only API and ORM filters, codecs, serialization and tracking.
- No stored format migration, automatic indexes or change to skip/take behavior.

## Engine reads

- Read physical catalog roots across multi-page/overflow sqlite_schema so indexed
  row appends do not rebuild an unrelated database merely because its schema grew.
  Preserve the single-leaf-only truncation guard and cache roots per current image.

- Reduce temporary image reconstruction for simple trigger reads to the ordinary
  unindexed rowid tables they actually reference, including scalar/IN subqueries.
  Complex sources, views, indexed tables and schema queries keep the full path.
  No change-log hooks or new persistent schema are installed.

- Export the built-in Unicode61Tokenizer for clients needing FTS-equivalent tokens.
- Refresh rowid lookup entries and invalidate value probes after a prepared
  same-rowid update; warmed reads must observe the current projected values.

## 0.1.12

`openFileImage` reads a database file into the in-process connection. A missing file starts empty and is not written. An existing file is not replaced. A tokenizer or a module registers on that connection. `openDatabase` still keeps the file itself. The README examples use `openDatabase` for an ordinary table and `openFileImage` when the connection must stay in this process.

## 0.1.11

`openDatabase` accepts `version`, `onCreate`, `onUpgrade`, and `onDowngrade`. The same connection has `insert`, `query`, `update`, `delete`, `transaction`, and `batch`. `query` reads a table and returns maps. `rawQuery` runs SQL. Integers in those maps, and insert ids, are `BigInt`. An `int` argument is stored as an integer. Linux x64, Dart 3.13.7: `dart analyze --fatal-infos` reported no issues and `dart test` passed 10631 tests.

## 0.1.10

`openDatabase('shelf.db')` creates a missing database file and a missing `-journal`. An existing database file is not replaced. `directoryEntriesDurable` defaults to true. Passing false writes nothing and throws. `wal: true` does not create a `-wal` file. `query` and `execute` on the owner call the same methods on its client. Linux x64, Dart 3.13.7: `dart analyze --fatal-infos` reported no issues and `dart test` passed 10623 tests.

## 0.1.9

The README opens on a file the application keeps. Each later sample is one engine feature. The catalog page and the other packages are at the end. Measured pages name the system and the result. The engine behavior is the 0.1.8 release.

## 0.1.8

Packed FTS5 leaves on Dart 3.13.7, Linux x64. 10613 tests passed.

- Two or more documents are stored by term in leaves of at most 4050 bytes. The idx term is the first term on that leaf. A positive AND/OR of whole terms reads the covering leaves and one document-length blob. One document keeps the previous leaf bytes. An older index still searches until it is rebuilt.
- Linux AOT, 20,000 product names, not a phone: `بسكويت` returned 493 hits and 20 rows in 26.967 ms, then 20.819 ms, and 25.663 ms at offset 320. `biscuit` took 19.717 ms, 25.481 ms, and 25.621 ms. The image was 3,387,392 bytes and held 347 leaves.
- One arm64 phone running the catalog release 0.5.2 showed `20 of 493 matches · 47.236 ms` for `بسكويت`. The locked baseline on the previous phone build was 472.000 ms.
- Pinned SQLite 3.53.1 opened the packed image. `integrity_check` returned `ok`, and both queries returned 493 rows.

## 0.1.7

The README names every package on pub.dev and shows a short example of each. The engine behavior is the 0.1.6 library. `DatabaseClient.inTransaction` still reports whether this client owns the open transaction.

## 0.1.6

Published version of the 0.1.5 library. `sqlite_plus_orm` 0.1.6 and `sqlite_plus_generator` 0.1.6 depend on this version.

## 0.1.5

Custom FTS tokenizers and row-storing virtual tables on Dart 3.13.7, Linux x64. 10609 tests passed.

- `tokenizers.register` adds an FTS tokenizer. `unicode61`, `porter`, `trigram`, `ascii`, and `simple` cannot be replaced.
- `VirtualTableModule.storesRows` creates a shadow table. `INSERT`, `UPDATE`, and `DELETE` write that table. `DROP` removes the shadows named by `ownedShadows`.
- A `MATCH` handler on the statement's virtual-match board can answer a virtual table before FTS does.
- `sqlite_plus_arabic` and `sqlite_plus_vec` use these hooks. The engine does not contain the Arabic stemmer or the vector distance math.

## 0.1.4

SQLCipher 4 file codec on Dart 3.13.7, Linux x64. 10607 tests passed. An unencrypted database does not run it.

- `SqlCipherDatabase.create` and `open` keep a plaintext database whose header reserve is 80 bytes. `encryptedImage` is AES-256-CBC with HMAC-SHA512. The key is PBKDF2-HMAC-SHA512, 256000 iterations by default. The HMAC key uses the salt with each byte XOR `0x3a` for 2 iterations.
- Page 1 stores a 16-byte salt. A wrong passphrase, a changed byte, or a page moved to another number fails authentication.
- A SQLCipher 4.5.6 community file with the default schedule opens here. A file written here opens in that CLI when both sides use the same iteration count. `saveSqlCipher` replaces the whole file. It is not the rollback journal.
- WAL files, SQLCipher 1–3, rekey, a plaintext header, and auto-vacuum combined with the reserve are unsupported.
- A reserve of 0 keeps the previous page geometry. A nonzero reserve rebuilds when auto-vacuum is off.

## 0.1.3

Compared with pinned SQLite 3.53.1 on Dart 3.13.7, Linux x64. 10596 tests passed. pub.dev already serves `0.1.2`.

- Incremental auto-vacuum keeps the freelist page after an overflow delete. `incremental_vacuum` moves a live end page, then truncates.
- Contentless FTS4 stores no content table and returns the pinned `MATCH` row. FTS3 `content=''` is a column named `content`.
- File `journal_mode` `wal`, `persist`, and `truncate` follow the pinned header and journal bytes. This is not a multi-frame WAL log.
- Cross-schema `VALUES` errors use the pinned wording.
- `EXPLAIN` matches the pinned opcode rows for a constant subquery, an integer-primary-key scan, `WITHOUT ROWID`, a virtual generated column, a typed `INSERT`, and a multi-row `VALUES` insert. An integer-primary-key insert and a join of two subqueries stay rejected. This is not a VDBE.

## 0.1.2

Performance work and a Linux desktop experiment. A release build compared 1,000 rows with sqflite. Every checksum matched. The charts are that sample. The logo is the feather, the database, and the plus.

## 0.1.1

Package page: short SQL, JSON, search, and file samples, plus the measured 1,000-row comparison.

## 0.1.0

`openInMemory` is `MutableSqliteDatabase.create`. `openDatabase` is `DatabaseOwner.open`. The previous names remain.

## 0.0.3

Published release.

## 0.0.2

Published release. Same engine surface as the first pre-release.

## 0.0.1-dev.1

First pre-release.

- Pure Dart SQL, JSON, FTS5, R-tree, and geopoly.
- In-memory databases, `exportImage`, and a `dart:io` file adapter.
- The package README shows the 1000-row comparison with Android SQLite.
