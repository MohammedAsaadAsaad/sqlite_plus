# Bench

Bench is a Flutter application that runs the same SQL on Android SQLite and on sqlite_plus, then keeps a log of both. The screen is English, left to right, and set in IBM Plex Sans Arabic under the SIL Open Font License. See `assets/fonts/OFL.txt`. Copy log places the whole log on the clipboard, oldest entry first, with a comparison line for each finished pair.

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

Preparation sits outside the measured interval. For search, preparation inserts the rows and creates `bench_name`. The log records that preparation on its own line. sqlite_plus also records the time and byte size of `exportImage`. The native column records the database file, including a `-wal`, `-shm`, or `-journal` sidecar when one is present. Each finished pair compares row count, `SUM(n)`, and the number of hits. The screen shows `sqlite_plus / native` for the measured intervals.

sqlite_plus work runs in a separate isolate. The memory and CPU figures on the screen are for the whole process and keep updating while a run is in progress. The native file path is `bench-native.db` under the application documents directory.

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

Each release APK holds one ABI. Flutter signs them with the debug keystore, so a device can install the matching file when that source is allowed. The application id is `dev.sqliteplus.engine_bench`. The launcher name is Bench. Version name 1.0.0. The split versionCode is the pubspec build number plus 1000 times the ABI index, so arm64-v8a is 2003.

| ABI | File | Bytes | versionCode | sha256 |
|---|---|---:|---:|---|
| arm64-v8a | `dist/bench-arm64-v8a.apk` | 19604515 | 2003 | `d59caf7a6e974feae0ace5e632aec1220a2758b694b34bb61093e4738803a1d9` |
| armeabi-v7a | `dist/bench-armeabi-v7a.apk` | 17105789 | 1003 | `7c76a676f75ac2b65cb696f5a26db61182c5bb8c38bb3117519251b68789d639` |
| x86_64 | `dist/bench-x86_64.apk` | 21095978 | 4003 | `a8114ec97ea6a2162a0efa22ddebe11e72c6744da0a881a2ebe50524f27a8ca4` |

A phone uses the arm64-v8a package. An older 32-bit phone uses armeabi-v7a. An earlier x86_64 package was installed on an API 35 emulator. These three files were built later and were not installed in that session. The compatibility matrix records both.
