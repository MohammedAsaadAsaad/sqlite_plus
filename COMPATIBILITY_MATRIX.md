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
| Collations | BINARY/NOCASE/RTRIM plus one custom collation | Declared/explicit propagation, ASCII NOCASE, SQL filtering/grouping/distinct/sorting and index constraints. `createCollation` covers ORDER BY, UNIQUE, and an index on that collation. REINDEX of a custom collation name has no separate oracle. ICU and locale collations are absent |
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
| Metadata generator | Verified M7 baseline plus items 99–101 | Resolved conventions/annotations, constructors/aliases, mutable/immutable mappings, deterministic owned output and CLI. `@DbJson` emits `path` on the field helper. `@DbEntity(module: 'fts5')` emits a query `search` method and creates `USING fts5` without putting `rowid` in the argument list. `@DbEntity(module: 'rtree')` emits `Bounds` for `minX`, `maxX`, `minY`, and `maxY`. The checked-in example passes `--check`. This Linux run printed 53 generator package tests, and the example project passed its own test |
| Virtual table modules | Items 1–12 verified | Connection-local Dart modules and cursors. Equality and range constraints can be consumed; an unused predicate still scans and is checked by SQL. Hidden columns are omitted from `SELECT *`. Named `CREATE VIRTUAL TABLE` and eponymous `name(args)` both open, and calling a real table or a non-eponymous module as a function is rejected. `BEGIN`/`COMMIT`/`ROLLBACK` notify the module; rollback removes the virtual schema row with the ordinary insert. `DROP` leaves a neighbor table and its index. An unknown module does not write. `generate_series` follows the documented start/stop/step algorithm, including a zero step, NULL-as-zero, and int64 overflow. The pinned SQLite 3.53.1 library is not installed in this environment, so that oracle was not regenerated. A closed cursor or a bad column leaves the connection usable; a thrown `xCommit` poisons it |
| JSON / JSONB | Items 13–22 verified | `json`, `jsonb`, validity flags, type, error position, extract, `->`/`->>`, array/object/length, insert/replace/set/remove/patch, quote, both group functions, and `json_each`/`json_tree`. 714 cases across UTF-8, UTF-16le, and UTF-16be were generated by the SQLite 3.53.1 CLI whose `sqlite_source_id()` matches the pin. That CLI reports `COMPILER=gcc-13.3.0`; `manifest.json` records `COMPILER=clang-22.1.3`, so the generator does not rewrite the manifest. CI checks the checksum only. JSON text is capped at 1 MiB, the SQL tokenizer limit, while SQLite's default `SQLITE_MAX_LENGTH` is 1 GB. Depth 1000 is accepted and 1001 is rejected. Function output is capped at 16 MiB. A constant `json_each(...)` join matches the pinned rows. `json_each(other.column)` raises `Virtual table argument must be constant`; SQLite 3.53.1 evaluates that correlated call. JSON subtype survives a scalar subquery and is cleared for a derived-table or CTE column. `MappedField.at` binds the path to `json_extract`. `json_pretty` is not implemented |
| FTS / R-tree | Items 23–50 verified subset | FTS5 unicode61/ascii read and write, including column `MATCH`, bound patterns, bm25 order, highlight/snippet, prefix indexes, content, contentless, contentless-delete, and external content. External `MATCH` stays stale until `rebuild`. unicode61 is not an Arabic stemmer. FTS3/FTS4 native images open, including parenthesized `MATCH`; their writes are rejected before the image changes. R-tree rectangles and auxiliary columns round-trip as float32, and a written image passes the pinned CLI `integrity_check` after insert, update, and delete. Geopoly area, json, overlap, and within match the pinned polygons. Unimplemented options and commands fail before a write. 42 replay cases and 6 FTS3/FTS4 images across three encodings come from the SQLite 3.53.1 CLI (`COMPILER=gcc-13.3.0`; `manifest.json` records clang-22.1.3). CI checks checksums only. Multi-page FTS5 leaves, porter, trigram, detail, tokendata, locale, and FTS3/4 writes are not implemented. `MappedTable.search` and `Bounds.intersects` bind their arguments. ORM `ensureCreated` can create an `fts5` or `rtree` table. Those writers reject `RETURNING`, so a tracked save reads the row back. A later `plan()` is empty when the stored virtual SQL still matches |
| Connection schema | Items 51–55 verified subset | TEMP tables, indexes, views, and triggers stay out of the exported image. Unqualified names resolve temp, then main, then one attached schema. `ATTACH ':memory:'` or `attachFile` accepts one database up to 64 MiB. Duplicate names, `main`, `temp`, a second attachment, a missing file, and a missing reader are rejected. A statement that mutates two schemas throws `cross-database statement is not supported` before a partial write. A cross-schema SELECT uses a scratch image. Temp and attached images are not a second journal. A transaction snapshots all three |
| Connection pragmas | Items 56–59 verified subset | `journal_mode` reads header byte 18 (`rollback` or `wal`). Writing the current mode is a no-op. `memory`, `off`, `delete`, `persist`, `truncate`, and a rollback/wal switch throw before any byte change. A write-version 2 image is not opened for query. `cache_size` defaults to -2000, `busy_timeout` to 0, and `synchronous` to 2, and none of the three changes `exportImage`. `auto_vacuum` reads 0. A write throws. A non-zero largest root page fails at open |
| Plans, DQS, and errors | Items 60–68 verified subset | One custom collation. EXPLAIN QUERY PLAN returns this engine's `detail` text. EXPLAIN bytecode throws. A 2–3 table comma join with ORDER BY and stat1 can be reordered; the test compares rows. A covering index reads fewer pages than a query that needs the table. `sqlite_stat4` throws at open. Double quotes are identifiers. The gap ledger has 25 UTF-8 cases from the SQLite 3.53.1 CLI (`COMPILER=gcc-13.3.0`; `manifest.json` records clang-22.1.3). CI checks the checksum only. Recorded differences include DQS, `json_pretty`, EXPLAIN bytecode, journal modes, `auto_vacuum`, and a cross-database insert. `SqlErrorCode` is `constraint`, `syntax`, or `missingTable`. Record decoding rejects UTF-8 0xFF, an unpaired UTF-16 surrogate, and an odd UTF-16 length |
| Incremental page writes | Items 69–76 verified subset | A splitting insert, an emptying delete, and a same-length overflow update pass the pinned CLI `integrity_check`. The file does not shrink; freelist pages are reused, so page count stays level after a same-size delete and insert. A non-key update leaves an expression index and a partial index byte-identical. A key change uses the compact rebuild. Journal and WAL crash recovery match the current contract for those steps. WITHOUT ROWID, views, and triggers keep their existing writers. An auto-vacuum file is rejected. `benchmark_results/page_writes_linux_x64.json` is this revision's AOT sample only: batch inserts of 10,000 rows took 268581, 275709, and 288941 microseconds; one batch of 100,000 rows took 2686614 microseconds; 200 single-row inserts took 296606 microseconds; peak RSS was 214040576 bytes. No earlier binary was measured, so no delta is claimed. 100,000 single-row inserts were not run |
| Browser storage | Items 77–82 verified subset | `openBrowserStorage` tries OPFS, then IndexedDB database `sqlite_plus` version 1 object store `files`, through `dart:js_interop`. Production dependencies include neither WASM nor native SQLite. The caller reads `canRead`, `canWrite`, `durabilityPromised`, and `placement`. Memory and browser placements both set `durabilityPromised` to false, and a browser flag with that field true is rejected. A missing interface, including the Linux stub and a null probe, returns a new empty `MemoryStorageBackend`. A throwing probe propagates. The round trip is `MemoryBrowserByteStore`: close then open returns the saved row. That store is an in-process map, not OPFS, and power loss is not claimed. `dart compile js tool/browser_storage_compile.dart` compiles the web file and does not execute it. The Chrome page is a separate row. `BrowserDatabaseConnection` saves through the public ORM API, and `where(MappedField.equalTo(...))` returns the row after close and reopen |
| Linux x64 | Executed | Dart 3.13.7. Format and fatal-info analysis pass. This revision re-ran the package suites after each example became its own project: 10496 engine tests passed, 169 ORM tests passed, and 53 generator tests passed. Each example project passed 1 test and `dart run bin/main.dart`. The pinned SQLite CLI was present, so the native integrity tests ran. These counts are Linux x64 only. The packages are prepared for pub.dev at `0.0.1-dev.1` and are not published |
| 10,000-row scenarios | Linux x64 AOT | `benchmark_results/scenarios_10k_linux_x64.json`. Rows 10000, samples 3, ceiling 10000. `sizes_not_run` is `[100000,1000000]`. SDK `3.13.7 (stable) (Thu Oct 22 14:28:57 2026 -0700) on "linux_x64"`. Hostname `cursor`. OS `Linux 6.12.94+ #1 SMP PREEMPT_DYNAMIC Mon Oct 19 22:12:29 UTC 2026`. Runtime `AOT executable`. Cold is the first measured SQL query after the fill in the same process. Warm is the next repetition of that query. Population variance is the integer floor of `sum((sample - mean)^2) / sample_count`. Rows per second is `(rows_touched * 1000000) ~/ microseconds`. Memory SQL insert microseconds `[2601012,2518356,2478439]`, rows per second `[3844,3970,4034]`, variance `2605502394`. Memory SQL point cold `[3699,846,594]`, point warm `[1111,437,418]`, range cold `[66375,50091,48456]`, range warm `[71440,53338,51313]`, update `[737057,663964,693884]`, delete `[790531,535159,515625]`, image bytes `[98304,98304,98304]`. Memory ORM track `[7784,5962,11470]`, save `[2934430751,3092578591,2700874993]` at 3 rows per second, point cold `[552,633,3074]`, point warm `[441,450,524]`, range cold `[151407,165494,221424]`, range warm `[140809,139628,147875]`, update `[713464555,644367619,642860919]` at `[0,0,0]` rows per second, delete `[639607004,680642252,602419455]` at `[0,0,0]` rows per second, image bytes `[102400,102400,102400]`. File SQL ran: insert `[1941990,1996109,2015981]`, point cold `[573,648,606]`, point warm `[586,521,404]`, file bytes `[98304,98304,98304]`, journal bytes `[8720,8720,8720]`. Peak RSS `220463104`. The ORM image includes `_sqlite_plus_orm_model`. `directoryEntriesDurable` true is an attestation, not a power-loss result. This is not macOS, Windows, Android, iOS, or a native SQLite comparison. No earlier binary was measured, so no delta is claimed |
| macOS | CI succeeded for head 7afaaba | This environment is Linux. GitHub Actions run [40538509306](https://github.com/MohammedAsaadAsaad/sqlite_plus/actions/runs/40538509306) passed format, fatal-info analysis, and `dart test` for all three packages on `macos-latest` with Dart 3.13.7. That job's own counts are 10490 engine tests passed with 6 skipped, 169 ORM tests, and 53 generator tests. The six skips are the pinned CLI integrity tests. Those counts are macOS for commit `7afaaba` only. Run [40494640309](https://github.com/MohammedAsaadAsaad/sqlite_plus/actions/runs/40494640309) for commit `e320528` passed 10490 engine tests with 6 skipped, 167 ORM tests, and 53 generator tests. Heads after `7afaaba` do not have a macOS result yet |
| Windows | CI passed for head 7afaaba | Run [40494640309](https://github.com/MohammedAsaadAsaad/sqlite_plus/actions/runs/40494640309), head `e320528`, passed ORM (167) and the generator (53). The engine job printed 10489 passed, 1 failed, and 6 skipped. The failure was `database_owner_test.dart` tearDown `PathAccessException` errno 32. Run [40538509306](https://github.com/MohammedAsaadAsaad/sqlite_plus/actions/runs/40538509306), head `7afaaba`, passed all three packages on `windows-latest` with Dart 3.13.7. That job's own counts are 10490 engine tests passed with 6 skipped, 169 ORM tests, and 53 generator tests. The six skips are the pinned CLI integrity tests. `database_owner_test.dart` "stale shared-memory and missing sidecars fail without creation" passed. These counts are Windows for `7afaaba` only. Heads after `7afaaba` do not have a Windows result yet |
| Android | Executed on an API 35 x86_64 emulator | Flutter 3.47.8, Dart 3.13.7, debug APK, image `system-images;android-35;aosp_atd;x86_64`, emulator 37.2.12.0, `accel off`. `ro.build.version.release` is 15, ABI `x86_64`, model `Android ATD built for x86_64`, fingerprint `Android/sdk_slim_x86_64/emu64x:15/AE3A.240806.019/12368160:userdebug/test-keys`. Logcat at 2026-10-27 18:04:23.330: memory cards=1, title `Kept Garden`, pages 320, highlight `a garden [kept] in the margin`, finite bm25, R-tree place 1, user_version 7 after reopen, image 40960 bytes; ORM insert 2, update 1, idle 0, title `Kept Garden Revised`, revision 1; `DatabaseOwner` file version 7 and title `Kept Garden` under the app cache. The line is `packages/sqlite_plus/tool/android_probe_api35_x86_64.log`. Nested KVM hit `kvm_arch_vcpu_create`, so this run used software CPU. This is one debug APK on that image. It is not a release AOT run, not a physical device, and not iOS |
| Margin notes | Release APK on the same API 35 x86_64 emulator | `examples/notes` is a Flutter application on the ORM. `flutter test` passed 6 tests on Linux: four store tests, including a save that reopens from the image, and two widget tests. `flutter build apk --release` wrote a fat APK with `arm64-v8a`, `armeabi-v7a`, and `x86_64`. The copy is `examples/notes/dist/margin-notes.apk`, 54 MB, sha256 `a09263e40b4b0053de152610b0ea15ca178b0371b315c698332d22508f930f15`, signed by the Android debug certificate. Application id `dev.sqliteplus.margin_notes`. `adb install` succeeded. Logcat `Displayed dev.sqliteplus.margin_notes/.MainActivity` at 2026-10-28 04:11:48.895 on the emulator clock, which was UTC, so 06:11:48 Asia/Hebron. A note titled `Kept` with body `Garden` was saved from the editor and was still present after `am force-stop` and a new start. Same image, emulator 37.2.12.0, `accel off`, fingerprint `Android/sdk_slim_x86_64/emu64x:15/AE3A.240806.019/12368160:userdebug/test-keys`. This is not a physical device and not iOS |
| iOS | Not executed | Flutter 3.47.8 on this Linux host has no `flutter build ios` subcommand. No Mac, Xcode, or simulator was available, so no iOS binary ran |
| Chrome | Executed on Linux x64 | Google Chrome 156.0.8078.47 loaded `tool/chrome_orm.html`. The page text is `packages/sqlite_plus_orm/tool/chrome_orm_linux_x64.log`: `placement=browser`, `durabilityPromised=false`, `saved=2`, `before=kept`, `reopenBody=kept`, `result=pass`. Power loss is not claimed. This is not a macOS, Windows, Android, or iOS result |

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
valid STAT1 prefix cardinalities now rank eligible indexes. Two or three comma
joins with ORDER BY and stat1 counts can be reordered. A covering read skips
the table only for columns stored in the index or a rowid alias. A complete
native cost model, STAT4 statistics, and SQLite EXPLAIN bytecode remain
unsupported. EXPLAIN QUERY PLAN text is this engine's plan.

Read-only APIs require a stable rollback-format copy with no concurrent writer,
hot journal or pending WAL; they do not lock or recover the source. WAL headers
are rejected. A traversal/seek may yield rows before discovering later corruption;
unvisited seek branches are not validated. Raw BtreeRecord values are physical
records: rowid INTEGER PRIMARY KEY fields are NULL and the rowId is separate.
WITHOUT ROWID uses physical primary-key-first column order. Raw traversal provides no cross-tree/freelist integrity guarantee; the bounded
PRAGMA checks below use the validated image path. Media repair is not claimed.

## Writes and durability

The image writer checks B-tree/overflow ownership and freelist coverage before
reconstruction. A single changed rowid table can reuse its pages and the
freelist. Same-length overflow updates patch the overflow bytes. Other shapes,
including a key change to an expression or partial index, still use a compact
rebuild. Compact rebuilds maintain supported indexes and schema roots.
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
A transaction snapshots main, temp, and one attached image in memory. Those
extra images are not a second durable journal, and one statement cannot mutate
two schemas. Journal modes other than reading rollback/wal and rewriting the
current mode remain unsupported.

## Remaining milestones / release gates

M6's bounded main-schema engine baseline is defined separately from the remaining
SQLite targets in [ENGINE_SUPPORT.md](docs/ENGINE_SUPPORT.md). Items 51–76 add
the connection-schema, pragma, plan, and page-write subset recorded above.
DQS stays off. Native EXPLAIN bytecode, STAT4, auto-vacuum, and a durable
two-database commit stay unsupported. M7's ORM/generator gate passes for
the documented runtime/generator contract. M8 passes for the verified JSON,
virtual-table, FTS, and R-tree subset recorded above. The omissions in that
subset, including `json_pretty`, correlated `json_each`, multi-page FTS5 leaves,
porter/trigram/detail/tokendata/locale, and FTS3/FTS4 writes, stay open. Items
77–82 record an unpromised browser-storage subset above. The round trip is an
in-process simulation, the OPFS/IndexedDB file was compiled and not run, and
power loss is not claimed. That subset does not check M9. Items 83–90 record
the Linux reprint, the Chrome page, and separate macOS, Windows, Android, and
iOS rows above. They do not check M9. Items 91–98 are the Linux x64 AOT
file `benchmark_results/scenarios_10k_linux_x64.json`: 10000 rows, three
samples, and the SQL, ORM, file, cold, warm, point, range, insert, update,
and delete arrays quoted in the scenario row above. 100000 and 1000000 were
not run. That file does not check M9. The saved AOT samples for 10,000 and
100,000 row batch inserts are an earlier page-write sample only. They are not
a before/after delta and they are not this scenario file. Items 99–107 add
generated JSON, FTS, and R-tree helpers, the
root `LICENSE`, version `0.0.1-dev.1`, and this changelog boundary. The three packages are prepared for pub.dev at that pre-release and are not published. Publishing waits for an explicit request. That preparation does not check M9. The Linux
`packages` job runs `python3 tool/generate_*.py --verify`. A checksum mismatch
fails that job. Those steps compare hashes. They do not execute SQLite. The
macOS and Windows jobs do not run those scripts. Android, iOS, power loss,
DQS, `json_pretty`, EXPLAIN bytecode, STAT4, `auto_vacuum`, a durable
two-database commit, and journal modes other than reading rollback/wal remain
open. Item 108 and M9 stay open. No release-ready or all-milestones completion
claim is made.

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
runtime imports/execution. Items 77–82 add a separate unpromised image round
trip in an in-process store and a compiled `dart:js_interop` file. They do not
establish power-loss durability. The Chrome page on Linux is recorded on its
own row. Android and iOS are recorded on their own rows.
