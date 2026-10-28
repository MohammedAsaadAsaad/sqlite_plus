# Bench

ميزان is a Flutter application that runs the same SQL on Android SQLite and on sqlite_plus, then keeps a log of both. The screen is Arabic, right to left, and set in IBM Plex Sans Arabic under the SIL Open Font License. See `assets/fonts/OFL.txt`.

The application is `publish_to: none`. It is not a workspace member, because the workspace is resolved with the Dart SDK and this project needs the Flutter SDK. `dependency_overrides` points `sqlite_plus` at the package in this repository. Android SQLite is opened with `sqflite` inside this application only.

## What a run measures

The table is `bench(id INTEGER PRIMARY KEY, name TEXT, body TEXT, n INTEGER)`. Both engines execute the same statements. The count is a number from 1 to 10000.

| Operation | Measured statements |
|---|---|
| إدراج منفصل | One autocommit `INSERT` per row |
| إدراج بمعاملة | The same `INSERT` statements. sqlite_plus uses `BEGIN` and `COMMIT`. Android SQLite uses one `sqflite` transaction |
| تحديث منفصل | `UPDATE bench SET n = n + 1 WHERE id = ?` once per row |
| تحديث دفعة | `UPDATE bench SET n = n + 1` |
| بحث | `SELECT id FROM bench WHERE name = ?` once per row, after `CREATE INDEX bench_name ON bench(name)` |
| جلب بالمفتاح | `SELECT body FROM bench WHERE id = ?` once per row |
| VACUUM | `VACUUM` |
| مسح منفصل | `DELETE FROM bench WHERE id = ?` once per row |
| مسح الكل | `DELETE FROM bench` |

Preparation sits outside the measured interval. For search, preparation inserts the rows and creates `bench_name`. The log records that preparation on its own line. sqlite_plus also records the time and byte size of `exportImage`. The native column records the database file, including a `-wal`, `-shm`, or `-journal` sidecar when one is present. Each finished pair compares row count, `SUM(n)`, and the number of hits. The screen shows `sqlite_plus / النيتف` for the measured intervals.

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

Each release APK holds one ABI. Flutter signs them with the debug keystore, so a device can install the matching file when that source is allowed. The application id is `dev.sqliteplus.engine_bench`. The launcher name is ميزان.

| ABI | File | Bytes | versionCode | sha256 |
|---|---|---:|---:|---|
| arm64-v8a | `dist/bench-arm64-v8a.apk` | 19473455 | 2001 | `954adf7e5327bce9a39b5a3320024919514409328fc3f7f93c47091cfd033281` |
| armeabi-v7a | `dist/bench-armeabi-v7a.apk` | 16974725 | 1001 | `b10f346424d1d548b078391b0bd7fb1421e29e909bf3874cd4b1dc50d8d8b0df` |
| x86_64 | `dist/bench-x86_64.apk` | 20964918 | 4001 | `5ac8989c3588f3f6632989b2327b549d50c9dadcdfe8dc0733555aa2310ceb34` |

A phone uses the arm64-v8a package. An older 32-bit phone uses armeabi-v7a. The x86_64 package was installed on an API 35 emulator. The compatibility matrix records that run.
