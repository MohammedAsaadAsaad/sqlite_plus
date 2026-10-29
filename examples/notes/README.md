# Margin

A Flutter notes application on the sqlite_plus ORM. The screen is a dark desk of paper cards, in English and left to right. IBM Plex Sans Arabic is included under the SIL Open Font License; see `assets/fonts/OFL.txt`.

The application is `publish_to: none`. It is not a workspace member, because the workspace is resolved with the Dart SDK and this project needs the Flutter SDK. `dependency_overrides` points `sqlite_plus` at the package in this repository so the ORM and the application share one engine.

## What it stores

`Note` is an ordinary class. `note.dart` maps it with `Column`, `EntityType`, and codecs for text, a boolean pin, a UTC timestamp, and an integer paper tint. `NoteStore` opens a `MutableDatabaseConnection`, calls `ensureCreated`, and tracks rows with `DbSet`.

The file on disk is `margin.db`, a snapshot from `exportImage`. Each save writes a temporary file and renames it into place. That snapshot is separate from `DatabaseOwner`.

Search filters the notes already loaded. Pinning sorts a note ahead of the others.

The tools screen inserts a chosen number of random notes through `DbSet.add` and `saveChanges`. One switch keeps every note in a single `saveChanges` transaction. That save writes the added notes with multi-row `INSERT` statements. The other calls `saveChanges` once per note and reopens the context on the same database. Those saves keep the loaded rows until `exportImage` runs once at the end. The work runs in a separate isolate. The screen reports wall time, process CPU time from `/proc/self/stat`, and process RSS before, at the peak sample, and after. Delete-all removes every tracked note in one `saveChanges`, which sends one `DELETE`. The tools screen also opens Metrics, a page that samples process RSS and CPU twice a second. That button stays available while an insert, delete, or VACUUM is running. Another page shows the file path, image size, page and freelist counts, schema names, and rows. `VACUUM` runs through the ORM connection with the image stats before and after.

## Run the tests

```sh
cd examples/notes
flutter pub get
flutter test
```

## Android

```sh
flutter build apk --split-per-abi --release
```

Each release APK holds one ABI. Flutter signs them with the debug keystore, so a device can install the matching file when that source is allowed. The application id is `dev.sqliteplus.margin_notes`. The APK files are build output and are not stored in git. This table records the versionCode 2004 packages.

| ABI | File | Bytes | versionCode | sha256 |
|---|---|---:|---:|---|
| arm64-v8a | `dist/margin-notes-arm64-v8a.apk` | 19997995 | 2004 | `ba72c0265fcbcf827b5469f79afc73bb3c3c9e088898eaeca42cdcd0d18d6620` |
| armeabi-v7a | `dist/margin-notes-armeabi-v7a.apk` | 17613957 | 1004 | `bc1934543c1bb01fb6bd06cfd09a42dba0f8133c7cd0a1533b4aee9364ae013c` |
| x86_64 | `dist/margin-notes-x86_64.apk` | 21554994 | 4004 | `c304e3766d0a93a31781612eb1f3a1bda98b44d8e6f8b08d247120807433ba00` |

A phone uses the arm64-v8a package. An older 32-bit phone uses armeabi-v7a. An earlier x86_64 package was installed on an API 35 emulator over the package before it, and the saved note was still on the desk. These three packages are the current engine and were not installed here. Margin still stores `margin.db` as an `exportImage` snapshot. The launcher name is Margin. Version name 1.0.0. The split versionCode is the pubspec build number plus 1000 times the ABI index, so arm64-v8a is 2004.
