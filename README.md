# sqlite_plus

A Pure Dart SQLite engine, ORM, and mapping generator. The production runtime has no FFI, native SQLite, or WASM.

| Package | What it shows |
|---|---|
| [`sqlite_plus`](packages/sqlite_plus) | Bound JSON, a rolled-back insert, FTS5 highlight, an Arabic token, R-tree, `user_version`, and a reopened image |
| [`sqlite_plus_orm`](packages/sqlite_plus_orm) | Two tracked books, a revision bump, an idle save, and a JSON shelf path |
| [`sqlite_plus_generator`](packages/sqlite_plus_generator) | Generated `filter` that drops a cheap purchase, JSON `path`, FTS `search`, and R-tree `bounds` |

Version `0.0.1-dev.1` is a pre-release. The packages are prepared for pub.dev and are **not published**. Publication waits for an explicit request. Until then, the package READMEs show a git dependency.

## One generated query

This is the call in `packages/sqlite_plus_generator/example/lib/library_app.dart`:

```dart
final rows = await purchases.query
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .toList();
```

The same program stores three purchases and keeps the two above 20, ordered by total. It also stores a second JSON note, a second article, and a second place, then reads only the kept note, the FTS match, and the intersecting place. The application imports `sqlite_plus_orm` only.

Each package has an example project under `example/` with its own `pubspec.yaml`, `lib/`, `bin/main.dart`, and `test/`. The examples are workspace members and are not published. From a checkout:

```sh
dart pub get
(cd packages/sqlite_plus/example && dart run bin/main.dart)
(cd packages/sqlite_plus_orm/example && dart run bin/main.dart)
(cd packages/sqlite_plus_generator/example && dart run bin/main.dart)
```

## Honest boundary

The verified subset is `COMPATIBILITY_MATRIX.md`. This repository is not a complete SQLite. DQS stays off. `json_pretty` is absent. EXPLAIN bytecode throws. Power loss is not claimed. Android and iOS were not run. A Windows pass for the current head is not recorded. The Linux AOT file `benchmark_results/scenarios_10k_linux_x64.json` measures 10000 rows. 100000 and 1000000 rows were not run. M9 stays open.

## Develop

The workspace lockfile is at the repository root. Packages require Dart >=3.6.0. CI uses Dart 3.13.7.

```sh
dart pub get --enforce-lockfile
dart format .
python3 tool/generate_fixtures.py --verify
for package in sqlite_plus sqlite_plus_orm sqlite_plus_generator; do
  (cd packages/$package && dart analyze --fatal-infos && dart test) || exit
  (cd packages/$package/example && dart analyze --fatal-infos && dart test && dart run bin/main.dart) || exit
done
```

The Linux GitHub job runs every `tool/generate_*.py --verify` script. A checksum mismatch fails that job. Those scripts do not execute SQLite in `--verify` mode. The macOS and Windows jobs run format, fatal-info analysis, package tests, and the example project check.

`docs/REFERENCE.md` is the format and SQL reference. `docs/ENGINE_SUPPORT.md` is the support contract. `CHANGELOG.md` separates the verified subset from the open limits.
