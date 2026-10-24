# sqlite_plus

Pure Dart SQLite-compatible engine and convention-based ORM under development.
M1 provides read-only database-header decoding and structural B-tree page
validation. SQL execution, record decoding, durable writes and ORM behavior are
not implemented. Production runtime code uses no native SQLite, FFI or WASM.

Read `MASTER_SPEC.md`, `AGENTS.md`, `IMPLEMENTATION_PLAN.md` and
`COMPATIBILITY_MATRIX.md` before developing.

## Packages

- `packages/sqlite_plus`: memory storage and SQLite format decoders
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

## Reference fixtures

SQLite 3.53.1 is pinned by source ID and compile configuration in
`packages/sqlite_plus/test/fixtures/manifest.json`. Fixtures include table and
index interior/leaf pages, three encodings, and minimum/maximum page sizes.
Tests compare Dart decoding against SQLite's recorded `dbstat` output.

`python3 tool/generate_fixtures.py --verify` checks committed file hashes without
requiring SQLite. To regenerate, use Python linked against the exact pinned
SQLite build and run `python3 tool/generate_fixtures.py`. It rejects a different
source ID, records the actual compile options, runs `integrity_check`, and writes
the fixture manifest. Regeneration was verified byte-for-byte on the pinned build.
The oracle is development-only and never called by the Dart runtime or tests.
See `COMPATIBILITY_MATRIX.md` for verification limits.
