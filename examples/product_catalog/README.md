# Product catalog

A Flutter example that loads two bundled product lists into an in-memory
`sqlite_plus` database and builds a keyword search index when you ask it to.

Each file has 10,000 names, one per line. Line 1 is the same product in both
languages:

- `assets/products/arabic_products_10k.txt`
- `assets/products/english_products_10k.txt`

The lists are assets. The first launch reads both files, builds the keyword
index, and saves the database image in the app's private files directory. Later
launches open that file and go straight to search. Saved catalogs from before
this fuzzy-search example rebuild their derived index once and save it again;
product rows are retained. The app records its search revision in `user_version`.

## Search

Search first requires every normalized keyword. Only when there are no matches
within the selected language does `FuzzySearchConfig` try nearby words (one
insertion, deletion or substitution, minimum four code points). For example,
`biscut` can find `biscuit`, and `حلييب` can find `حليب`. Exact hits covering every query word
suppress fuzzy expansion; pagination does not change that decision.

Rebuilding creates the ordinary search index. Fuzzy candidate discovery currently
scans its derived text; this example does not create a dedicated fuzzy index.
Repeated typo learning is enabled at five successful submissions. The sixth
submission of the same typo/token combination can reuse saved alternatives.
Page navigation does not train. Learning changes are saved with the catalog;
index rebuilds clear them. Exact results still take precedence.

Historical timings below measure exact keyword searches, not fuzzy fallback.

Type a query and press **Search**, or press an example (`biscuit` or
`بسكويت`). The language control limits hits with a fixed `language = ?`
predicate. The result line is how many names this page loaded, out of the full hit
count, and the time that page took. Twenty names are loaded at a time.
Previous and next run that search again for the other slice and replace the
time.

On one arm64 phone, release 0.5.2, `بسكويت` read `20 of 493 matches · 47.236 ms` on page 1 of 25. The score
on those titles was 3.965. The same query on Linux x64, AOT, and not a phone,
took 26.967 ms, then 20.819 ms, and 25.663 ms at offset 320.

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

## Precision ordering

The example enables SearchRankingPolicy: exact normalized names first, then the
query phrase, adjacent words in another order, scattered words, and corrected
matches. It reuses normalized indexed names. Hit counts and exact-first fuzzy
fallback are unchanged; no index rebuild is needed. Displayed scores remain BM25
base scores, while precision takes priority in sorting. Historical timings above
predate this policy. See the package benchmark report for measured overhead.

## Android package

`dist/product-catalog-0.5.6-arm64-v8a.apk` is the release package built with
Flutter 3.47.9 / Dart 3.13.7 on Linux using
`flutter build apk --release --target-platform android-arm64`.

- Application id: `dev.sqliteplus.product_catalog`
- Version: `0.5.6+11`; minSdk 24, targetSdk 36; ARM64 only.
- Size: 20,013,657 bytes.
- SHA-256: `1cc4536df3cdf30699e2e64ec8ba852a6c431644c0e0d7a83086e4dc5d5b1517`.
- Debug-certificate signing, APK v2 signature verified with apksigner.

Flutter analysis and all 17 example tests passed, including exact-first/fuzzy
fallback, language filtering, saved-index rebuild and widget pagination after a
typo query. The APK was not installed on a physical device here. Opening a saved
catalog from an earlier app revision rebuilds the index once and saves it;
product records are preserved. Historical timings above do not measure this APK.

Multiword queries keep every word: `جودة بسكوت` falls back to
`(جودة OR nearby) AND (بسكوت OR بسكويت OR nearby)` and excludes quality-only
products. This query-only fix does not require another index rebuild.
