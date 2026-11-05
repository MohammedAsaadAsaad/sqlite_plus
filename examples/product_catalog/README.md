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

1. Choose Arabic, English, or both, then press **Load products**. That reads
   the files and inserts one row per name.
2. Press **Build search index**. The index is keyword-only. Arabic stemming is
   on. English letters stay as written. There is no embedding model.
3. Type a query and press **Search**, or press an example (`biscuit` or
   `بسكويت`). The language control limits hits with a fixed `language = ?`
   predicate.
4. **Sample resources** reads process RSS and the database image without
   changing the data.

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
2026 at 14:36 Asia/Hebron (UTC+2) with
`flutter build apk --release --target-platform android-arm64`. It is 19423641
bytes, sha256
`4c70b2d03af38bd42a76b2173de40654724bfda6542a3158123acd7b4ceaf382`. The
application id is `dev.sqliteplus.product_catalog`, versionName `0.1.0`,
versionCode `1`, minSdk 24. Native code is `arm64-v8a` only. The release build
is signed with the Android debug certificate. It was not installed on a device
here.
