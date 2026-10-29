# Bench

Bench is a Flutter application that runs the same SQL on Android SQLite and on sqlite_plus, then keeps a log of both. Every operation runs twice. The memory round opens both engines in memory. The file round opens both engines on a database file. The screen is English, left to right, and set in IBM Plex Sans Arabic under the SIL Open Font License. See `assets/fonts/OFL.txt`. Copy log places the whole log on the clipboard, oldest entry first, with a comparison line for each finished pair.

The application is `publish_to: none`. It is not a workspace member, because the workspace is resolved with the Dart SDK and this project needs the Flutter SDK. `dependency_overrides` points `sqlite_plus` at the package in this repository. Android SQLite is opened with `sqflite` inside this application only.

## What a run measures

The table is `bench(id INTEGER PRIMARY KEY, name TEXT, body TEXT, n INTEGER)`. Both engines execute the same statements. The count is a number from 1 to 10000.

| Operation | Measured statements |
|---|---|
| Separate insert | One autocommit `INSERT` per row |
| Transaction insert | The same `INSERT` statements. sqlite_plus uses `BEGIN` and `COMMIT`. Android SQLite uses one `sqflite` transaction |
| Separate update | `UPDATE bench SET n = n + 1 WHERE id = ?` once per row |
| Bulk update | `UPDATE bench SET n = n + 1` |
| Search | `SELECT id FROM bench WHERE name = ?` once per row, after `CREATE INDEX bench_name ON bench(name)` |
| Point lookup | `SELECT body FROM bench WHERE id = ?` once per row |
| VACUUM | `VACUUM` |
| Separate delete | `DELETE FROM bench WHERE id = ?` once per row |
| Delete all | `DELETE FROM bench` |

Preparation sits outside the measured interval. For search, preparation inserts the rows and creates `bench_name`. The log records that preparation on its own line. A memory sqlite_plus run also records the time and byte size of `exportImage`. A file run records the database file instead, and its export time is 0. The native file size includes a `-wal`, `-shm`, or `-journal` sidecar when one is present. A memory native size is `page_count * page_size`. Each finished pair compares row count, `SUM(n)`, and the number of hits inside one storage round. The screen shows `sqlite_plus / native` for the measured intervals.

Memory sqlite_plus work runs in a separate isolate. File sqlite_plus work opens `bench-sqlite-plus.db` with a rollback journal in that same isolate. An autocommit change is written to that file before the statement returns. A transaction is written on `COMMIT`, which is inside the measured interval. The bench writes an empty image and an empty journal, flushes both, then passes `directoryEntryIsDurable: true`. That flag is the caller attestation. It is not a power-loss result. This path does not open a loopback socket. Native memory is sqflite `:memory:` with `singleInstance: false`. Native file stays `bench-native.db` under the application documents directory, opened by sqflite with its default journal mode. The memory and CPU figures on the screen are for the whole process and keep updating while a run is in progress.

## 1000 rows

The table below is the earlier sample: native on a file, sqlite_plus in memory. Every pair matched on row count, `SUM(n)`, and hits. The ratio is the measured sqlite_plus interval divided by the measured native interval. The app now records a memory pair and a file pair separately. This checkout has no new phone log for those pairs.

![1000 rows, same SQL. Statement time on a logarithmic scale.](../../packages/sqlite_plus/doc/bench-time.png)

![Stored size for the same 1000-row statements.](../../packages/sqlite_plus/doc/bench-size.png)

| Operation | native | sqlite_plus | ratio | rows | sum | hits |
|---|---:|---:|---:|---:|---:|---:|
| Separate insert | 514.9 ms | 6.5 ms | 0.01 | 1000 | 500500 | 1000 |
| Transaction insert | 104.6 ms | 3.5 ms | 0.03 | 1000 | 500500 | 1000 |
| Separate update | 508.2 ms | 247.5 ms | 0.49 | 1000 | 501500 | 1000 |
| Bulk update | 1.3 ms | 92 µs | 0.07 | 1000 | 501500 | 1000 |
| Search | 126.3 ms | 7.6 ms | 0.06 | 1000 | 500500 | 1000 |
| Point lookup | 116.2 ms | 9.6 ms | 0.08 | 1000 | 500500 | 1000 |
| VACUUM | 1.2 ms | 9 µs | 0.01 | 1000 | 500500 | 1 |
| Separate delete | 352.7 ms | 168.0 ms | 0.48 | 0 | 0 | 1000 |
| Delete all | 732 µs | 105 µs | 0.14 | 0 | 0 | 1000 |

Preparation, export, file size, process CPU, and process RSS from the same log:

| Operation | Engine | CPU | Memory | Prepare | Export | Size |
|---|---|---:|---|---:|---:|---:|
| Separate insert | native | 430.0 ms | 171.38 MB → 177.42 MB | 510 µs | 0 µs | 36.0 KB |
| Separate insert | sqlite_plus | 20.0 ms | 177.79 MB → 178.40 MB | 2.8 ms | 3 µs | 28.0 KB |
| Transaction insert | native | 130.0 ms | 182.86 MB → 185.34 MB | 483 µs | 0 µs | 36.0 KB |
| Transaction insert | sqlite_plus | 0 µs | 185.33 MB → 185.33 MB | 986 µs | 3 µs | 28.0 KB |
| Separate update | native | 450.0 ms | 188.16 MB → 189.14 MB | 166.1 ms | 0 µs | 36.0 KB |
| Separate update | sqlite_plus | 370.0 ms | 188.55 MB → 189.17 MB | 4.2 ms | 4 µs | 28.0 KB |
| Bulk update | native | 0 µs | 191.61 MB → 191.61 MB | 134.5 ms | 0 µs | 36.0 KB |
| Bulk update | sqlite_plus | 0 µs | 191.41 MB → 191.54 MB | 4.0 ms | 3 µs | 28.0 KB |
| Search | native | 160.0 ms | 194.11 MB → 197.14 MB | 109.2 ms | 0 µs | 52.0 KB |
| Search | sqlite_plus | 10.0 ms | 197.37 MB → 197.37 MB | 107.6 ms | 4 µs | 44.0 KB |
| Point lookup | native | 150.0 ms | 199.83 MB → 202.65 MB | 184.7 ms | 0 µs | 36.0 KB |
| Point lookup | sqlite_plus | 10.0 ms | 202.64 MB → 202.64 MB | 4.4 ms | 3 µs | 28.0 KB |
| VACUUM | native | 0 µs | 182.77 MB → 182.82 MB | 114.7 ms | 0 µs | 36.0 KB |
| VACUUM | sqlite_plus | 0 µs | 182.80 MB → 182.80 MB | 4.8 ms | 3 µs | 28.0 KB |
| Separate delete | native | 230.0 ms | 185.20 MB → 187.22 MB | 90.9 ms | 0 µs | 16.0 KB |
| Separate delete | sqlite_plus | 220.0 ms | 187.20 MB → 187.22 MB | 3.0 ms | 1 µs | 8.0 KB |
| Delete all | native | 10.0 ms | 189.58 MB → 189.58 MB | 155.2 ms | 0 µs | 16.0 KB |
| Delete all | sqlite_plus | 0 µs | 189.25 MB → 189.25 MB | 4.5 ms | 2 µs | 8.0 KB |

## Run the tests

```sh
cd examples/compare
flutter pub get
flutter test
```

## Android

```sh
flutter build apk --split-per-abi --release
```

Each release APK holds one ABI. Flutter signs them with the debug keystore, so a device can install the matching file when that source is allowed. The application id is `dev.sqliteplus.engine_bench`. The launcher name is Bench. Version name 1.0.0. The split versionCode is the pubspec build number plus 1000 times the ABI index, so arm64-v8a is 2006.

| ABI | File | Bytes | versionCode | sha256 |
|---|---|---:|---:|---|
| arm64-v8a | `dist/bench-arm64-v8a.apk` | 19604515 | 2006 | `8277620f7fc8f46815bdcd2da2a657fd87f555746aa8e808ddc11b7c3d584b8e` |
| armeabi-v7a | `dist/bench-armeabi-v7a.apk` | 17154941 | 1006 | `85ae690596a25e56e37404312adf106769f7ede0fe51003ef6d3e89fc961778b` |
| x86_64 | `dist/bench-x86_64.apk` | 21161514 | 4006 | `291c5d01040cb486ce43773d4dee0cf9b4d9e17324d24ca298f480b764815598` |

A phone uses the arm64-v8a package. An older 32-bit phone uses armeabi-v7a. The 1000-row charts and tables above are the earlier arm64 package, versionCode 2003, native file against sqlite_plus memory. These versionCode 2006 packages were not installed here. VersionCode 2004 opened the sqlite_plus file through `DatabaseOwner`, and a phone rejected its loopback socket. VersionCode 2005 opened the file but left hot autocommit changes in memory. An earlier x86_64 package was installed on an API 35 emulator. The compatibility matrix records both.
