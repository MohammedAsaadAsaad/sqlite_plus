# Optimizer correctness repairs — 2026-11-12

Baseline: `91a85454354e4610919688de82221086edd86b35`.
Review: https://github.com/MohammedAsaadAsaad/sqlite_plus/pull/84

The reviewed correctness defects in **12 roadmap IDs** are repaired:
11, 13, 14, 21, 22, 29, 31, 32, 33, 34, 35, 37.
This is a correctness closeout for those defects, not acceptance of the entire
42-item optimizer roadmap. Production execution remains pure Dart.

## Final verification

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| core | 10777 | 0 | 1 |
| orm | 259 | 0 | 0 |
| inspector | 55 | 0 | 0 |
| Independent semantic-reference checks | 374 | 0 | 0 |

Core, ORM, and Inspector static analysis passed with `--fatal-infos`.
The raw/prepared/ORM/cache optimizer assertions passed on Dart VM and JavaScript.
The one core skip is the pre-existing SQLCipher external-CLI interoperability
test: `sqlcipher` is not installed. It is recorded in the compressed JSON event
log and is not counted as passed.

The independent matrix covers three database encodings, mutable/read-only APIs,
results, types, wildcard column order, aggregates, binding, callbacks, and
shadowed rowid names. See `independent/README.md` for reproducible commands.
Native comparisons use the exact pinned source ID in `reference_identity.txt`.
The reference build enables the manifest's functional options. Compiler metadata
is GCC rather than the manifest's clang; it is recorded honestly, not spoofed.
One pinned SQLite indexed RHS-COLLATE OR discrepancy uses its NOT INDEXED result
as the semantic oracle; both native results are in `native_or_collation.json`.

## Repairs

| IDs | Corrected behavior |
| --- | --- |
| 11, 31 | Covering/extreme paths respect all required columns, shadowed rowid aliases, and custom functions. |
| 13, 14, 34 | Index eligibility and contradiction proofs respect affinity and collation; uncertain cases retain full evaluation. |
| 21 | Scalar AND/OR retains required evaluation; WHERE/HAVING/CASE/FILTER/DML predicates use SQLite's context-dependent short circuit rules and NULL truth. |
| 22 | Wildcard join output and ORDER BY ordinals preserve written source order. |
| 29, 35 | Flattening and projection pruning preserve LIMIT/ORDER windows, repeated CTE semantics, renamed fields, and nested correlations. |
| 32 | Running aggregates retain HAVING keys and correct all-NULL min/max representative rows. |
| 33 | CAST/COLLATE affinity survives folding; compound ORDER BY retains structural expression identity. |
| 37 | Reused scalar subqueries distinguish semantic shape, parameters, limits, offsets, identifiers, and side effects. |

The existing advanced trigger regression now rejects both the capacity violation
and negative input through the CTE guard, verifies the rejected write leaves the
image unchanged, and still accepts valid input. These checks ran in the final
core suite, in addition to new per-item native regressions.

The first full repaired-tree run exposed three compound ORDER BY failures and
one owner socket address-in-use failure (`first_full_run.json`). The compound
follow-up passed 1,883 focused/semantics tests, and the entire core suite was
then rerun successfully. The socket test also passed in that final full run.
Historical failing review artifacts were retained.

## Scoped AOT controls

50 fresh processes: five alternating pairs for each case, before/after binaries,
10,000-row seeded image, no concurrent tests or compilers during measurement.
Result hashes/counts, storage read counts/bytes, callback traces/counts, visits,
and image size matched in every sample. Raw timings, planning (`explain_us`),
and whole-process peak RSS are in `aot_samples.jsonl`.

| Case | Repaired/baseline median time | Baseline range (us) | Repaired range (us) |
| --- | ---: | --- | --- |
| small_k | 1.063 | [340247, 371152] | [300579, 468037] |
| large_k | 1.075 | [289651, 504151] | [315040, 569445] |
| unlimited | 0.959 | [328766, 426054] | [324834, 460716] |
| point | 1.196 | [266, 579] | [293, 549] |
| callbacks | 0.793 | [226442, 370685] | [221624, 434689] |

These controls do not establish every optimization's cost acceptance. Conservative
fallbacks can lose speed on affected queries; correctness takes precedence.
There is no universal speedup or zero-overhead claim. Item 23 remains partial:
its equality join groups a materialized inner input in memory; the SEARCH label
is not evidence of physical B-tree inner seeks. That implementation and its
performance gate remain open.

## Reproduction and evidence

From `packages/sqlite_plus`, with the pinned native CLI available:

```sh
dart format lib test
dart analyze --fatal-infos
dart test --timeout 10m --concurrency=2 --reporter json
```

Run package tests and analysis separately for `sqlite_plus_orm` and
`sqlite_plus_inspector`; local owner/Inspector socket tests require localhost
access. Run `tool/optimizer_benchmark/assertions.dart` on VM, and compile it with
`dart compile js` for Node (set `globalThis.self = globalThis`).

Build `tool/optimizer_benchmark/main.dart` with `dart compile exe` on baseline
`91a8545` and the repaired branch, then run `aot_controls.py BASELINE_EXE
REPAIRED_EXE IMAGE`. The unchanged driver can generate IMAGE with
`REPAIRED_EXE seed IMAGE 10000 random`. Use Dart 3.13.7/Linux x64 to reproduce
this recorded environment. The baseline binary SHA matches the frozen review
binary for `91a8545`; binary and image hashes are in `aot_controls.json`.

`*_summary.json` records exact counts and raw log SHA-256; `*.jsonl.gz` preserves
full test event logs. `source_manifest.json` identifies the final changed runtime
files. Per-item checkpoint logs remain available alongside the final evidence.
No merge or package publication was performed.
