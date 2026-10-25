# sqlite_plus

Pure Dart SQLite-compatible engine and convention-based ORM under development.
The engine provides byte storage, SQLite format decoding, table/index traversal,
schema/index mutations and exclusive-owner WAL/rollback transactions. M6 adds
relational queries, constraints, functions, window frames and index planning.
Full SQLite SQL semantics and ORM behavior remain unfinished. Production runtime
code uses Pure Dart, without native SQLite, FFI or WASM.

Read `MASTER_SPEC.md`, `AGENTS.md`, `IMPLEMENTATION_PLAN.md` and
`COMPATIBILITY_MATRIX.md` before developing.

## Packages

- `packages/sqlite_plus`: memory storage, SQLite format decoders, read-only pager and B-tree reader
- `packages/sqlite_plus_orm`: planned ORM
- `packages/sqlite_plus_generator`: planned metadata generator

## Development checks

CI uses Dart 3.13.7. Run from the repository root:

```sh
dart format .
python3 tool/generate_fixtures.py --verify
for package in sqlite_plus sqlite_plus_orm sqlite_plus_generator; do
  (cd packages/$package && dart pub get --enforce-lockfile && dart analyze --fatal-infos) || exit
done
(cd packages/sqlite_plus && dart test)
```

The ORM and generator are placeholders with no test suites. In the cloud setup,
source `/workspace/toolchains/env.sh` and add `--suppress-analytics` after `dart`
to avoid writing analytics files into the read-only home directory.

## Format API

```dart
final header = DatabaseHeader.decode(bytes);
final physicalPages = header.validateFileLength(bytes.length);
final page = BtreePageHeader.decode(firstPage,
    database: header, pageNumber: 1);
```

Import `package:sqlite_plus/sqlite_plus.dart`; inputs are `Uint8List`. Header
decoding accepts a 100-byte header or a larger buffer. Page decoding requires one
complete page and a one-based page number. Malformed formats throw
`FormatException`; an invalid page number throws `RangeError`. Decoded fields
are independent of the input buffer. `validateFileLength` checks main-file
framing and rejects an authoritative database size larger than the physical
file; stale or zero size fields do not override physical length. It does not
reconcile WAL or establish database integrity.

## Read-only database traversal

Use a stable database copy with no concurrent writer, hot journal or pending WAL.
The reader does not lock or recover databases and rejects WAL-format headers.
The backend becomes owned by the pager after a successful open; close the backend
yourself if opening fails. This example is for dart:io platforms:

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus/sqlite_plus_io.dart';

final storage = await ReadOnlyFileStorageBackend.open('snapshot.db');
late final ReadOnlyPager pager;
try {
  pager = await ReadOnlyPager.open(storage);
} catch (_) {
  await storage.close();
  rethrow;
}
try {
  // Page 1 is sqlite_schema; the query API below resolves table names.
  await for (final record in BtreeReader(pager).scanTable(1)) {
    print('${record.rowId}: ${record.values}');
  }
} finally {
  await pager.close();
}
```

The core library has no dart:io imports. Other adapters can implement
`StorageBackend`; reads may return partial results, which the pager retries.
`scanTable(rootPage)` returns table leaf records ordered by signed rowid.
`scanIndex(rootPage)` includes both leaf and interior records in physical order;
it also reads WITHOUT ROWID table trees, whose primary key determines physical
column order. This low-level API accepts root pages explicitly; the query API below resolves table names.

`BtreeRecord.values` contains null, BigInt, double, String or copied Uint8List.
INTEGER PRIMARY KEY aliases are physically stored as null; use the separate
BigInt `rowId` for their value. Index records have a null `rowId`. All integers
use BigInt to avoid losing 64-bit precision on browser targets. Strings require
well-formed UTF-8 or UTF-16. Record lists are unmodifiable; blob values are
independent mutable copies. A scan can emit records before encountering later
corruption. Consume the stream completely before treating its tree as verified.
Payloads default to a configurable 16 MiB maximum per record. No SQL affinity,
collation validation, recovery, concurrent-writer support or complete database
integrity check is provided yet.

## Reference fixtures

SQLite 3.53.1 is pinned by source ID and compile configuration in
`packages/sqlite_plus/test/fixtures/manifest.json`. Fixtures include table and
index interior/leaf pages, WITHOUT ROWID and empty tables, three encodings,
signed 64-bit limits, blobs, floats, overflow chains, and local/overflow payload
boundaries at minimum/maximum page sizes. Tests compare 2,244 physical records
against SQLite SELECT results in `records.json`, and framing against `dbstat`.

`python3 tool/generate_fixtures.py --verify` checks committed file hashes without
requiring SQLite. To regenerate, use Python linked against the exact pinned
SQLite build and run `python3 tool/generate_fixtures.py`. It rejects a different
source ID or compile configuration, runs `integrity_check`, and writes
the fixture manifest. Regeneration was verified byte-for-byte on the pinned build.
The oracle is development-only and never called by the Dart runtime or tests.
See `COMPATIBILITY_MATRIX.md` for verification limits.

## M3 SELECT API

```dart
final database = await SqliteDatabase.openReadOnly(storage);
try {
  final result = await database.query(
      'SELECT id, value FROM sample WHERE id >= ? ORDER BY id DESC LIMIT ?',
      [128, 5]);
  print(result.columns);
  print(result.rows);
} finally {
  await database.close();
}
```

The existing stable-file requirements still apply. The original M3 subset supports a
catalog table (including sqlite_schema, sqlite_master and WITHOUT ROWID), `*`,
column/literal/expression projection, explicit `AS` aliases, `WHERE`, `DISTINCT`,
`ORDER BY` expressions/aliases/ordinals, and `LIMIT`/`OFFSET` (including comma
syntax). It supports positional `?`/`?NNN` parameters with an exact parameter
count, SQL quoting/comments, NULL/TRUE/FALSE, decimal/hex/blob literals,
arithmetic, concatenation, comparisons, IS [NOT], NOT/AND/OR and parentheses.
Bound Dart integers normalize to BigInt; integer bindings must fit signed 64
bits. Parameter data is never parsed as SQL. Errors use `SqlException`.

Column values apply rowid aliases and physical WITHOUT ROWID column mapping.
SELECT results are materialized and lists are unmodifiable (blob buffers remain
independent mutable values). The parser limits input to 1 MiB and expression
nesting to 128. M6 expands this grammar as described below. DML and transactions use the mutable
API. Unsupported syntax fails explicitly; full SQLite conformance remains unclaimed.

`python3 tool/generate_sql_oracle.py` regenerates the 726 SELECT oracle cases
using the pinned SQLite source/build, across all three database encodings.
`python3 tool/generate_sql_oracle.py --verify` checks its committed SHA-256.
The Dart tests use only the committed JSON and never execute native SQLite.

## M4 writes (limited subset)

`MutableSqliteDatabase.create(pageSize: 4096, encoding: 1)` creates an empty
SQLite image. `fromImage(bytes)` opens an independent existing image. M6 adds
CREATE/DROP TABLE/INDEX/VIEW/TRIGGER, ADD COLUMN/table rename, indexed rowid and WITHOUT ROWID
mutations, constraints and row triggers. `execute(sql, parameters)` returns the
direct change count and last inserted rowid. `exportImage()` copies the current
image. Statements are atomic in memory; durability requires an ImagePager.

The current writer validates page ownership/freelists before rebuilding compact
B-trees, secondary indexes and overflow pages. It supports complete images up to
64 MiB without auto-vacuum or reserved page bytes. It favors correctness and
simple atomic images over in-place updates; large write workloads are not tuned.

For durable commits, supply `RollbackJournalPager.open(database, journal)` to
`MutableSqliteDatabase.fromJournalPager`. Both backends must implement the
explicit `DurableStorageBackend` contract: distinct, already durably provisioned
files, durable ordered sync, and exclusive access. The optional
`DurableFileStorageBackend.openExisting(path, directoryEntryIsDurable: true)`
uses only existing regular files and file flush; it does not create/delete files
or establish that their directory entries are durable. The boolean is a caller
attestation, not automatic detection. Do not use it to assume fresh files are
power-loss safe. Pre-provision those files through a storage provider that can
guarantee directory-entry persistence. The journal retains its existing entry
and invalidates its header after database sync (PERSIST-style commit).

Any commit I/O failure poisons the writer; reopen the pager to recover before
accessing data again. Use the M5 owner protocol for cross-isolate access and WAL writes.
Transaction/savepoint control and offline WAL snapshots are described below. The image limit defaults to 64 MiB. The
reference verifies eight cross-open mutation snapshots and recovers a Dart hot
journal byte-for-byte. These are algorithm/interoperability checks, not physical
power-loss certification of the cloud filesystem.

Development-only verification, with the pinned SQLite/Python build and Dart on
PATH (run from repository root):

```sh
python3 tool/generate_write_fixture.py --verify
python3 tool/verify_mutation_oracle.py
python3 tool/verify_rollback_oracle.py
```

## M5 transactions and exclusive WAL ownership

The mutable API supports BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE], COMMIT/END,
ROLLBACK, SAVEPOINT, RELEASE [SAVEPOINT], and ROLLBACK [TRANSACTION] TO
[SAVEPOINT]. Transactions use private images and persist once at outer commit.
Closing an active transaction discards it; a commit I/O error poisons the session.
BEGIN modes share the exclusive-owner contract, not shared-reader lock escalation.

For file access across isolates, use one DatabaseOwner and share its SendPort:

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

final owner = await DatabaseOwner.open('snapshot.db',
    directoryEntriesDurable: true, wal: true);
try {
  final client = owner.client;
  await client.execute('BEGIN');
  await client.execute('UPDATE notes SET value=? WHERE id=1', ['updated']);
  await client.execute('COMMIT');
  await client.checkpoint();
  // Other isolates use DatabaseClient.connect(owner.sendPort).
} finally {
  await owner.close();
}
```

The durability attestation has the same pre-provisioning meaning as M4. WAL mode
requires an existing WAL-format main file and an existing durable `-wal` file;
rollback mode requires an existing `-journal`. Automatic mode switching and file
provisioning are unsupported. Existing `-shm` or unresolved journal state is
rejected; the owner never deletes it blindly.

All file handles live in one isolate. RPC requests serialize, and explicit
transactions belong to the client that began them; others receive a busy error.
An abandoned transaction is rolled back by owner shutdown. The owner takes an
exclusive SQLite lock-byte lease and a deterministic loopback-port lease to
exclude duplicate owners in other isolates before opening the main file. No SQL
is served over TCP. A port collision fails as busy. Use one canonical path and
no direct extra handles; hard-link aliases are unsupported. The raw file adapter
alone still has the documented POSIX process-lock limitations.

This design excludes external native SQLite connections until owner close. It
does not implement shared external readers or a shared-memory wal-index. Raw
WalPager callers must supply equivalent exclusive ownership and no wal-index.
The SQL and image limits documented below apply to both journal modes.

WalPager appends checksum-chained full-image transactions and acknowledges only
after WAL sync. Checkpoint syncs WAL, copies committed pages, syncs main, then
clears/syncs WAL. The WAL can restore an interrupted checkpoint. Payload/image
limits remain bounded; when the WAL limit is reached, checkpoint before retry.
Physical power-loss certification and cross-platform execution remain unverified.

WalSnapshot remains available for independent copied files. It does not make
uncoordinated reads of a changing external database safe. Development checks:

```sh
python3 tool/generate_wal_fixture.py --verify
python3 tool/verify_mutation_oracle.py --transactions
python3 tool/verify_wal_oracle.py
```

The pinned reference verifies little/big-endian WAL appends, cross-open integrity,
checkpointing, native write continuation and owner lease handoff. Crash tests
cover every commit/checkpoint storage operation, torn writes, retained/lost
unsynced data, growth and shrinkage. WAL fixture regeneration uses SQLite salts,
so regenerated bytes may differ; committed fixture hashes are stable.

## M6 SQL support (milestone still open)

The engine now supports:

- INNER/LEFT/RIGHT/FULL/CROSS/NATURAL joins, ON/USING, qualified names,
  derived tables, scalar/correlated subqueries, EXISTS and IN subqueries.
- UNION/UNION ALL/INTERSECT/EXCEPT; ordinary/forward CTEs and bounded recursive
  CTEs (100,000 queued rows; recursive priority ORDER BY, LIMIT and OFFSET).
- IN lists, BETWEEN, CASE, CAST, LIKE/ESCAPE, GLOB, bitwise operations,
  BINARY/NOCASE/RTRIM collations, expression/ordinal/alias GROUP BY, HAVING
  aliases, and bare-column MIN/MAX selection in the verified cases.
- Core scalar functions and COUNT/SUM/TOTAL/AVG/MIN/MAX/GROUP_CONCAT aggregates.
  String helpers include INSTR/OCTET_LENGTH/CONCAT/CONCAT_WS/UNHEX/SIGN,
  variadic IF/IIF, decimal ROUND and compiled-reference math functions.
  Function outputs are bounded. Connection-local Dart scalar/aggregate callbacks
  support overloads, varargs, DISTINCT/FILTER and safe SQL-value conversion.
- ROW_NUMBER/RANK/DENSE_RANK/PERCENT_RANK/CUME_DIST/NTILE, LAG/LEAD,
  FIRST_VALUE/LAST_VALUE/NTH_VALUE and aggregate windows. PARTITION/ORDER,
  ROWS/GROUPS/RANGE frames, numeric offsets, EXCLUDE, named/inherited windows,
  aggregate FILTER and explicit NULLS FIRST/LAST are covered. Windows are limited
  to 10,000 input rows. Group aggregation and HAVING run before windows, including
  `SUM(COUNT(*)) OVER (...)` and windows over registered aggregate results.
- CREATE/DROP TABLE/INDEX/VIEW/TRIGGER, safe ALTER TABLE ADD/RENAME/DROP COLUMN and table rename, defaults,
  NOT NULL/UNIQUE/CHECK, STRICT types, AUTOINCREMENT, INSERT VALUES/DEFAULT
  VALUES/SELECT, UPDATE/DELETE, OR IGNORE/REPLACE/FAIL/ROLLBACK, and WITHOUT ROWID writes.
- `PRAGMA foreign_keys=1` enables FK checks/actions. Deferred keys validate at
  outer commit. Foreign keys default off. BEFORE/AFTER row triggers support
  OLD/NEW, UPDATE OF, WHEN, DML and SELECT/WITH/VALUES bodies, WHEN subqueries, and RAISE(ABORT/FAIL/ROLLBACK/IGNORE).
  Recursive invocation is controlled by PRAGMA recursive_triggers (default off,
  1,000-level bound). INSTEAD OF INSERT/UPDATE/DELETE view triggers are supported with zero direct
  change counts and view-row RETURNING values.

`execute` also accepts RETURNING projections on direct INSERT/UPDATE/DELETE
rows; `MutationResult.returning` contains the QueryResult, including an empty
result with known column labels when no rows change. AFTER-trigger changes are
excluded from these rows. Results survive DatabaseClient RPC with BigInt/blob
types intact. RETURNING in trigger bodies and aggregate/window RETURNING shapes
are rejected.

UPSERT supports one or more ON CONFLICT clauses, explicit column/rowid targets,
DO NOTHING, DO UPDATE with `excluded` values and an optional WHERE, including
INSERT SELECT and RETURNING. INSERT conflict policies compose with UPSERT; DO UPDATE always uses ABORT. Table renaming rewrites supported
index/FK/sequence metadata and resolved references in dependent views/triggers.
Column rename rewrites supported CHECK/key/index/FK references; explicit DROP
COLUMN rewrites stored records and rejects key/index/CHECK/FK dependencies.
Column rename also resolves dependent view/trigger fields and write targets.
Drops validate dependent SQL against the proposed schema before committing. No automatic destructive migration is performed.

RAISE(FAIL) reports an error while retaining prior rows and trigger effects;
these partial images cross the pager commit boundary outside an explicit
transaction. RAISE(ROLLBACK) discards the active transaction and savepoints.
ABORT discards the statement; foreign-key failures still abort the statement.
Owner clients release logical transaction ownership when ROLLBACK ends it.

OLD/NEW preserve stored value types and declared collations, with no comparison
affinity. BEFORE INSERT sees an unassigned automatic rowid as -1; actual
allocation follows BEFORE-trigger writes. SELECT and INSERT SELECT bodies use
working-image snapshots and typed pseudo-row context without SQL interpolation.

Expression indexes evaluate deterministic scalar expressions; partial indexes
store and enforce uniqueness only for rows whose WHERE predicate is true.
These keys are rebuilt for INSERT/UPDATE/DELETE, conflict handling and supported
schema changes, including WITHOUT ROWID primary-key suffixes. Explicit UPSERT
expression/partial targets use SQLite's stricter structural matching rules.

Expression equality/range plans require a matching expression tree. A partial
index is used only when the query proves its predicate through supported
conjunct/OR/null-rejection rules; otherwise the query scans. `index_info` and
`index_xinfo` report expression slots with cid -2. Index schemas reject parameters,
subqueries, aggregates/windows and non-deterministic functions. Dart scalar
callbacks require `deterministic: true` to participate in schema expressions.

Read-only PRAGMAs include page_size/page_count/freelist_count/schema_version,
user_version/application_id/encoding/table_info/table_xinfo/index_list/
index_info/index_xinfo/foreign_key_list/integrity_check/quick_check/foreign_key_check. Foreign-key state and user_version/
application_id can be set through the mutable API. Index metadata includes column/expression terms and partial status; unsupported
shapes fail explicitly.

Eligible rowid equalities/ranges and secondary-index equality prefixes/ranges
descend B-tree paths. Multi-column prefixes are preferred when more constraints
can be used; callback predicates retain a scan. `database.explain(sql, parameters)` reports the access/rootPage/rowid;
it is a diagnostic, not SQLite bytecode or a cost model. Other predicates scan.
All results are materialized. Numeric precision, resource limits and other
unsupported features are recorded in `COMPATIBILITY_MATRIX.md`.

The pinned M6 oracle currently contains 1,593 differential queries across the
three encodings. Development-only schema verification cross-opens Dart images
with SQLite after every mutation and runs integrity_check:

```sh
python3 tool/generate_semantics_oracle.py --verify
python3 tool/verify_schema_oracle.py
```

Connection-local callbacks are synchronous and receive copied SQL values:

```dart
database.functions.registerScalar('twice', 1,
    (args) => args.single == null ? null : (args.single as BigInt) * BigInt.two);
final result = await database.query('SELECT twice(?)', [21]);
```

Use `registerAggregate(name, argumentCount, factory)` with a fresh SqlAggregate
instance per group; `-1` selects varargs. Registered aggregates are not window
functions, but their grouped results can feed built-in windows. Closures are
connection-local and are not transferred through DatabaseClient RPC.

Date/time support includes DATE/TIME/DATETIME/JULIANDAY/UNIXEPOCH/STRFTIME/TIMEDIFF,
CURRENT_DATE/TIME/TIMESTAMP and dynamic defaults. A statement shares one clock.
Pinned cases cover time zones, fractional seconds, numeric epochs, calendar/
clock shifts, start/weekday modifiers, floor/ceiling and ISO week formatting.
Host local-time behavior, unsupported input/modifier edge cases and extreme
floating precision are not full native-conformance claims.

Integrity checks are bounded to complete supported images up to 64 MiB without
auto-vacuum/reserved bytes. They verify tree/freelist ownership, constraints and
persisted index contents against table data. QUICK_CHECK omits index/table
content comparison; FOREIGN_KEY_CHECK reports violating rows independently of
foreign_keys enable state. Error wording is not native SQLite's exact wording.

M6 remains open for broader SQL/PRAGMA/function coverage, remaining UPSERT shapes,
additional ALTER operations, trigger/foreign-key edge cases, and planner work.
M7–M9 remain pending under the sequential milestone plan.

Real AOT benchmark samples are saved under `benchmark_results`. The index
benchmark builds a 10,000-row memory image and measures five batches of 100
queries. These small Linux workloads do not satisfy M9's full scale/platform
matrix. Reproduce with:

```sh
(cd packages/sqlite_plus && dart compile exe benchmark/planner.dart -o /tmp/sqlite-plus-index-benchmark)
(cd packages/sqlite_plus && /tmp/sqlite-plus-index-benchmark)
```

Generated columns support VIRTUAL/STORED expressions, deterministic scalar
functions, forward dependencies, affinity, constraints and secondary indexes.
INSERT positional values exclude generated columns; explicit writes to them
fail. ADD permits virtual columns; dependency-aware rename/drop and metadata
(table_info/table_xinfo hidden flags) are verified. Three pinned SQLite-created
fixtures cover stored/virtual values, overflow, WITHOUT ROWID and all encodings.

Schema-level PRIMARY KEY/UNIQUE/NOT NULL ON CONFLICT policies support ABORT,
IGNORE, REPLACE, FAIL and ROLLBACK, with explicit statement policies taking
precedence. REPLACE deletes fire row triggers when recursive_triggers is enabled;
BEFORE DELETE RAISE(IGNORE) leaves uniqueness enforcement active.

CREATE TABLE AS materializes SELECT/WITH/VALUES results, assigning rowids in
result order and SQLite-compatible column names and affinity types. It accepts
query parameters and copies values without source constraints or defaults.
REPLACE INTO is supported with the same conflict, UPSERT and trigger behavior
as INSERT OR REPLACE. String-quoted projection/source aliases are supported.

Named SQL parameters (:name, @name and $name, including namespace/suffix forms)
use the existing positional argument list. Repeated names share an index; case
and prefixes distinguish names. They compose with ?/?NNN placeholders and share
one index map through INSERT SELECT, UPSERT and RETURNING. Schema parameters
remain prohibited.

Aggregate ORDER BY supports multiple terms, direction, collations and NULLS
placement, including FILTER/DISTINCT and registered Dart aggregates. STRING_AGG
is available in grouped and window queries. ORDER BY inside window aggregate
calls remains prohibited, matching the reference.

Table renaming tracks parsed source bindings through views, subqueries, CTE
shadows, qualifiers, wildcards and trigger DML/WHEN bodies. Aliases and literals
retain their meaning. Unresolved/duplicate aliases and trigger pseudo-row/table
namespace collisions reject atomically. Dependent column alterations validate
view/trigger metadata and reject changes that break downstream output references.
The pinned SQLite 3.53.1 trigger-target rename also rebinds UPSERT EXCLUDED
qualifiers to the renamed target; this observed reference quirk is reproduced
and tested, including its effect on subsequent updates.

Column dependency checks use metadata-only resolution, including explicit view/
CTE aliases, correlated sources, trigger OLD/NEW/EXCLUDED fields and unused named
windows. View queries and dynamic unary defaults do not execute during metadata
parsing. NATURAL join rewrites follow the merged column origin for LEFT/RIGHT/FULL
joins; renaming USING keys rejects when the resulting join becomes invalid, as
in the reference. Real columns take precedence over implicit rowid aliases. More
complex schema/DQS fallback behavior is outside the verified subset.
