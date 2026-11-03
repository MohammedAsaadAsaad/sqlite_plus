# sqlite_plus browser

A database browser on the sqlite_plus engine. It opens a file, shows the schema, pages through rows, edits a cell, and runs one SQL statement. The schema rail lists tables, indexes, views, and triggers. A table shows each column's type, default, primary key, and NOT NULL mark, its foreign keys, its indexes, and the triggers that belong to it. The SQL editor opens a popup of the tokens that can follow what is already written. The same screen is the phone layout and the desktop layout: a wide window keeps the schema beside the rows, and a narrow window puts the schema in a drawer and Rows / SQL in a bar.

The engine is pure Dart. This program does not use FFI, native SQLite, or WASM.

```sh
cd browser
flutter run -d linux
flutter run -d windows
flutter run -d macos
flutter run -d android
flutter run -d ios
```

New starts an empty memory image. Open reads the file bytes and passes them to `MutableSqliteDatabase.fromImage`. Save writes `exportImage()` through the platform save dialog. A write marks the title unsaved until that save finishes.

The image has to be a complete rollback database. A WAL file is rejected by the engine with `Writer requires a complete rollback-format database image`. One statement runs at a time. A table with `WITHOUT ROWID` can be read here; cell edits use `rowid`, so that table is changed from the SQL page. Blob cells show their length and stay unchanged by the cell editor.

Add sample rows creates `books` and inserts Kept Garden (320 pages) and Other Atlas (40 pages).

On Linux x64, Flutter 3.47.9 and Dart 3.13.7, `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 10 tests: six session tests, one completion test, and three widget tests. The sample grid shows Kept Garden at 320 pages, the schema shows `id` as PK and `title` as TEXT, and a later cell edit stores 321. Typing `SEL` opens the popup and inserts `SELECT`. After `SELECT title` the popup offers `FROM` and `AS`. A full page of 50 rows leaves the exact count for `countRows`, and the next page is the remaining rows. `flutter build linux` was not run on that machine because `gtk+-3.0` and Ninja were not installed.

An arm64 release package is built with:

```sh
flutter build apk --release --target-platform android-arm64
```

The build on 3 November 2026 at 22:32 Asia/Hebron wrote `build/app/outputs/flutter-apk/app-release.apk`, 19537685 bytes, sha256 `a3045209cba915e409f480f41d2973b65822adce0fa2f69eda3bdd7be5b340d6`. `aapt dump badging` reports `native-code: arm64-v8a`, versionName `1.0.0`, versionCode `3`, and package `dev.sqliteplus.sqlite_plus_browser`. The downloadable copy is [`dist/sqlite-plus-browser-arm64-v8a.apk`](dist/sqlite-plus-browser-arm64-v8a.apk). Other `*.apk` files stay ignored. The release build uses the Android debug keystore. That package was not installed on a device. iOS, macOS, and Windows were not launched.
