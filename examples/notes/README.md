# Margin

A Flutter notes application on the sqlite_plus ORM. The screen is a dark desk of paper cards, set in Arabic and laid out right to left. IBM Plex Sans Arabic is included under the SIL Open Font License; see `assets/fonts/OFL.txt`.

The application is `publish_to: none`. It is not a workspace member, because the workspace is resolved with the Dart SDK and this project needs the Flutter SDK. `dependency_overrides` points `sqlite_plus` at the package in this repository so the ORM and the application share one engine.

## What it stores

`Note` is an ordinary class. `note.dart` maps it with `Column`, `EntityType`, and codecs for text, a boolean pin, a UTC timestamp, and an integer paper tint. `NoteStore` opens a `MutableDatabaseConnection`, calls `ensureCreated`, and tracks rows with `DbSet`.

The file on disk is `margin.db`, a snapshot from `exportImage`. Each save writes a temporary file and renames it into place. That snapshot is separate from `DatabaseOwner`.

Search filters the notes already loaded. Pinning sorts a note ahead of the others.

The tools screen inserts a chosen number of random notes through `DbSet.add` and `saveChanges`. One switch keeps every note in a single `saveChanges` transaction. The other calls `saveChanges` once per note. The work runs in a separate isolate. The screen reports wall time, process CPU time from `/proc/self/stat`, and process RSS before, at the peak sample, and after. It can also delete every tracked note in one `saveChanges`, open a page with the file path, image size, page and freelist counts, schema names, and rows, and run `VACUUM` through the ORM connection with the image stats before and after.

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

Each release APK holds one ABI. Flutter signs them with the debug keystore, so a device can install the matching file when that source is allowed. The application id is `dev.sqliteplus.margin_notes`.

| ABI | File | Bytes | versionCode |
|---|---|---:|---:|
| arm64-v8a | `dist/margin-notes-arm64-v8a.apk` | 19932467 | 2001 |
| armeabi-v7a | `dist/margin-notes-armeabi-v7a.apk` | 17466509 | 1001 |
| x86_64 | `dist/margin-notes-x86_64.apk` | 21423930 | 4001 |

A phone uses the arm64-v8a package. An older 32-bit phone uses armeabi-v7a. The x86_64 package was installed on an API 35 emulator over the earlier package, and the saved note was still on the desk. The compatibility matrix records that run.
