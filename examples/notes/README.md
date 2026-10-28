# Margin

A Flutter notes application on the sqlite_plus ORM. The screen is a dark desk of paper cards, set in Arabic and laid out right to left. IBM Plex Sans Arabic is included under the SIL Open Font License; see `assets/fonts/OFL.txt`.

The application is `publish_to: none`. It is not a workspace member, because the workspace is resolved with the Dart SDK and this project needs the Flutter SDK. `dependency_overrides` points `sqlite_plus` at the package in this repository so the ORM and the application share one engine.

## What it stores

`Note` is an ordinary class. `note.dart` maps it with `Column`, `EntityType`, and codecs for text, a boolean pin, a UTC timestamp, and an integer paper tint. `NoteStore` opens a `MutableDatabaseConnection`, calls `ensureCreated`, and tracks rows with `DbSet`.

The file on disk is `margin.db`, a snapshot from `exportImage`. Each save writes a temporary file and renames it into place. That snapshot is separate from `DatabaseOwner`.

Search filters the notes already loaded. Pinning sorts a note ahead of the others.

## Run the tests

```sh
cd examples/notes
flutter pub get
flutter test
```

## Android

```sh
flutter build apk --release
```

The fat release APK is copied to `dist/margin-notes.apk`. Flutter signs it with the debug keystore, so a device can install it when that source is allowed. The application id is `dev.sqliteplus.margin_notes`.

That package was installed on an API 35 x86_64 emulator. A note saved from the editor was still on the desk after the process was stopped and started again. The compatibility matrix records that run.
