# sqlite_plus

Pure Dart SQLite-compatible engine and convention-based ORM under development.
M2 provides a read-only pager, table/index B-tree traversal, overflow payload
reading and record decoding, with an optional Pure Dart file adapter. SQL
execution, durable writes and ORM behavior are not implemented. Production runtime code uses no native SQLite, FFI or WASM.

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
  // Page 1 is sqlite_schema. M3 will add catalog lookup by table name.
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
column order. Root pages must be supplied explicitly; there is no SQL query API.

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
