# sqlite_plus browser

A database browser on the sqlite_plus engine. It opens a file, lists the schema, pages through rows, edits a cell, and runs one SQL statement. The same screen is the phone layout and the desktop layout: a wide window keeps the schema beside the rows, and a narrow window puts the schema in a drawer and Rows / SQL in a bar.

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

On Linux x64, Flutter 3.47.9 and Dart 3.13.7, `flutter analyze --fatal-infos` reported no issues and `flutter test` passed 6 tests: four session tests and two widget tests. The sample grid shows Kept Garden at 320 pages. A later cell edit stores 321. `flutter build linux` was not run on that machine because `gtk+-3.0` and Ninja were not installed. Android, iOS, macOS, and Windows were not launched.
