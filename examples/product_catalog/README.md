# Product catalog

A Flutter example that loads two bundled product lists into an in-memory
`sqlite_plus` database and builds a keyword search index when you ask it to.

Each file has 10,000 names, one per line. Line 1 is the same product in both
languages:

- `assets/products/arabic_products_10k.txt`
- `assets/products/english_products_10k.txt`

The lists are assets. Opening the app does not read them, create a database,
or build an index.

## Steps

1. Choose Arabic, English, or both, then press **Load**. That reads the files
   and inserts names 1,000 at a time. Each batch is its own commit.
2. Press **Index**. The index is keyword-only. Arabic stemming is on. English
   letters stay as written. There is no embedding model. The source table is
   read 1,000 rows at a time.
3. Type a query and press **Search**, or press an example (`biscuit` or
   `بسكويت`). The language control limits hits with a fixed `language = ?`
   predicate.
4. **Sample resources** reads process RSS and the database image without
   changing the data.

Load, index, search, and the resource sample run on a background isolate. A
progress bar shows how many of the products in the current step are done. The
interface isolate does not build the database.

Every step lists its own time, the image size before and after, RSS before and
after, and the process peak RSS. The resource sample is timed separately and
is not included in the operation time. A figure is one sample on that device.

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
2026 at 14:56 Asia/Hebron (UTC+2) with
`flutter build apk --release --target-platform android-arm64`. It is 19620241
bytes, sha256
`f03d26f3b6096cad307000e1fa3968a39f263b77f9ef2122271140b469c64abb`. The
application id is `dev.sqliteplus.product_catalog`, versionName `0.2.0`,
versionCode `2`, minSdk 24. Native code is `arm64-v8a` only. The release build
is signed with the Android debug certificate. It was not installed on a device
here. Version code 2 replaces the earlier version code 1 package.
