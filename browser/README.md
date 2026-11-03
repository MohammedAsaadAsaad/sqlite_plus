# sqlite_plus browser

A database browser on the sqlite_plus engine. It opens a file, shows the schema, pages through rows, edits a cell, and runs one SQL statement. The structure tree has three columns: Name, Type, and Schema. Tables, indices, views, and triggers are folders. A table expands to its columns, and each column's schema text includes the type, primary key, NOT NULL, default, and foreign key. The data grid has a filter row for the current page and a pager with first, previous, next, last, and go to. The SQL editor opens a popup of the tokens that can follow what is already written, and keeps a short log of statements that ran. A read that has no outer `LIMIT` is shown 50 rows at a time, and the next page reads the following rows. A statement that already has `LIMIT` keeps that bound and still pages the grid. The same screen is the phone layout and the desktop layout: a wide window keeps the schema beside the rows, and a narrow window puts the schema in a drawer and Rows / SQL in a bar.

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

On Linux x64, Flutter 3.47.9 and Dart 3.13.7, `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 13 tests: eight session tests, one completion test, and four widget tests. The create-statement dialog formats each column on its own line and shows it in a JetBrains Mono code view. The sample grid shows Kept Garden at 320 pages. The structure tree shows `Tables (1)`, `Indices (0)`, `id` as PK, `title` as TEXT, and the column text `"title" TEXT NOT NULL`. A later cell edit stores 321. Typing `SEL` opens the popup and inserts `SELECT`. After `SELECT title` the popup offers `FROM` and `AS`. A full page of 50 rows leaves the exact count for `countRows`, and the next page is the remaining rows. `flutter build linux` was not run on that machine because `gtk+-3.0` and Ninja were not installed.

An arm64 release package is built with:

```sh
flutter build apk --release --target-platform android-arm64
```

The build on 3 November 2026 at 23:19 Asia/Hebron wrote `build/app/outputs/flutter-apk/app-release.apk`, 19731940 bytes, sha256 `abd541ece5a5cd76b05cdef152f59c14202e8539f08ea922d1dbfaa66471011d`. `aapt dump badging` reports `native-code: arm64-v8a`, versionName `1.0.0`, versionCode `6`, and package `dev.sqliteplus.sqlite_plus_browser`. The downloadable copy is [`dist/sqlite-plus-browser-arm64-v8a.apk`](dist/sqlite-plus-browser-arm64-v8a.apk). Other `*.apk` files stay ignored. The release build uses the Android debug keystore. That package was not installed on a device. iOS, macOS, and Windows were not launched.
