# Product catalog

A Flutter example that loads two bundled product lists into an in-memory
`sqlite_plus` database and builds a keyword search index when you ask it to.

Each file has 10,000 names, one per line. Line 1 is the same product in both
languages:

- `assets/products/arabic_products_10k.txt`
- `assets/products/english_products_10k.txt`

The lists are assets. The first launch reads both files, builds the keyword
index, and saves the database image in the app's private files directory. Later
launches open that file and go straight to search.

## Search

Type a query and press **Search**, or press an example (`biscuit` or
`بسكويت`). The language control limits hits with a fixed `language = ?`
predicate. The result line is the hit count and the time that search took.
Twenty hits are shown at a time. Previous and next move through those hits
without searching again.

The menu at the top holds the setup commands. They are not on the main screen.

- **Load products** reads both files again, rebuilds the index, and replaces
  the saved image. Names are inserted 1,000 at a time.
- **Rebuild index** builds the keyword index again from the products already
  loaded. Arabic stemming is on. English letters stay as written. There is no
  embedding model. The source table is read 1,000 rows at a time.
- **Sample resources** reads process RSS and the database image without
  changing the data.
- **Activity** shows the recorded times. It stays hidden until asked for.

Load, index, search, and the resource sample run on a background isolate. A
progress bar shows how many of the products in the current step are done. The
interface isolate does not build the database.

Load, index, and the resource sample each record time, the image size before
and after, RSS before and after, and the process peak RSS. Those lines stay in
Activity. Search does not add one: the screen keeps the search time and the
page controls. The resource sample is timed separately and is not included in
the operation time. A figure is one sample on that device.

Loading again replaces the database and clears the index.

## Run

```sh
cd examples/product_catalog
flutter pub get
flutter test
flutter run -d linux
```

The app uses the packages in this repository through path dependencies. Search
stays inside the pure-Dart engine.

## Android package

`dist/product-catalog-arm64-v8a.apk` is the release package built on 5 November
2026 at 16:04 Asia/Hebron (UTC+2) with
`flutter build apk --release --target-platform android-arm64`. It is 19751513
bytes, sha256
`ff6280e9f6e072cc37b01ef9df79384c344a5301019a9ed97463709a4c42c705`. The
application id is `dev.sqliteplus.product_catalog`, versionName `0.5.0`,
versionCode `5`, minSdk 24. Native code is `arm64-v8a` only. The release build
is signed with the Android debug certificate. It was not installed on a device
here. Version code 5 replaces the earlier packages. Search keeps the index
saved by an earlier version.
