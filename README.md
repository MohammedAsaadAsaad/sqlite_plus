# sqlite_plus

Pure Dart SQLite-compatible engine and convention-based ORM under development.
M3 adds catalog lookup and a read-only single-table SELECT API to the pager,
B-tree traversal and record decoding. M4 adds experimental image mutations and a rollback pager. ORM behavior is
not implemented. Full SQLite SQL semantics remain a later milestone. Production runtime code uses no native SQLite, FFI or WASM.

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

The existing stable-file requirements still apply. `query` supports a single
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
nesting to 128. Unsupported SQL is rejected; joins, aggregates, subqueries,
IN/LIKE, compound SELECTs, functions, non-BINARY collations, DDL is unsupported; DML and transactions use the limited mutable API below. Catalog constraints outside the supported
metadata grammar also fail explicitly.

`python3 tool/generate_sql_oracle.py` regenerates the 726 SELECT oracle cases
using the pinned SQLite source/build, across all three database encodings.
`python3 tool/generate_sql_oracle.py --verify` checks its committed SHA-256.
The Dart tests use only the committed JSON and never execute native SQLite.

## M4 writes (limited subset)

`MutableSqliteDatabase.fromImage(bytes)` creates an independent mutable image.
`execute(sql, parameters)` supports INSERT VALUES (including multiple rows),
UPDATE SET/WHERE and DELETE WHERE on simple rowid tables without indexes,
triggers, non-PK constraints, auto-vacuum or reserved space. Unsupported targets
fail explicitly. `exportImage()` returns a copy that SQLite can open. Statements
are atomic in memory; this alone is not durable storage. Rebuilding appends new
pages and puts old descendants/overflow pages on the freelist.

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
accessing data again. Concurrent writers, general cross-isolate locking and live WAL writing are not supplied.
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
The same unindexed/simple-table DML limits still apply.

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
