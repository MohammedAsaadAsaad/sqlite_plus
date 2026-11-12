# Independent correctness comparisons

These development-only probes compare mutable/read-only execution with pinned
SQLite 3.53.1, source ID
`2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9`.
The callback reference also requires Python sqlite3 built from that source.
Production execution remains pure Dart.

Recorded results: matrix 318/318, supplemental 28/28, callbacks 4/4,
shadow-rowid extremes 24/24: **374/374**.

Run from the repository root after `dart pub get` and building the reference
CLI with `tool/build_sqlite_reference.sh`:

```sh
dart benchmark_results/optimizer_correctness/independent/matrix.dart rerun
dart benchmark_results/optimizer_correctness/independent/supplemental.dart rerun
dart benchmark_results/optimizer_correctness/independent/callbacks.dart rerun
dart benchmark_results/optimizer_correctness/independent/extremes.dart
```

Matrix/supplemental/callback output files use the supplied label. Recorded
files here use concise names. Extreme output is `repaired_extreme_results.json`.

One deliberate reference choice is visible in matrix.dart: the pinned SQLite
indexed RHS-COLLATE OR path drops a matching row, while its NOT INDEXED path
returns the correct comparison result. That query uses the native scan as its
semantic oracle. Both native outputs are preserved in
`../native_or_collation.json` and documented in COMPATIBILITY_MATRIX.md.
Historical failing review artifacts were not rewritten by these reruns.
