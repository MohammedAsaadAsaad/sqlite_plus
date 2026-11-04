# Testing

From the repository root:

```sh
dart pub get --enforce-lockfile
cd packages/sqlite_plus_geo
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
cd example
dart analyze --fatal-infos
dart test
dart run bin/main.dart
```

On 4 November 2026, Dart 3.13.7, Linux x64, `dart test` in the package passed 42 tests and the example passed 1. The example program printed `Clinic | North | 2 | 2.0 | true`.

The tests cover construction, WKT/WKB/GeoJSON, DE-9IM predicates, overlay of adjacent and overlapping squares, bowtie repair, buffer envelope, geodesy, Web Mercator, UTM, SQL functions, index rollback and reopen, nearest-neighbor order, GeoJSON and CSV import, an isolate hull, the ORM codec, and convex-polygon area identities with seed `20261104`.

`dart run benchmark/bench.dart --size 1000` writes `benchmark/results/linux_x64_1000.json`. Larger sizes are listed in that file as not run.

CI runs the same format, analyze, test, and example steps for `sqlite_plus_geo`. It does not install GEOS, GDAL, PROJ, or SpatiaLite.
