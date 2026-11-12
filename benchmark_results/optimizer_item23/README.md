# Item 23 — physical indexed inner joins

Review: [PR #85](https://github.com/MohammedAsaadAsaad/sqlite_plus/pull/85) (not merged).

Baseline: `322c2b0dd5c867301858e67b42eba726e3dcbe4d`, the user-approved merge
of PR #84. All previous correctness repairs are now on main. GitHub Actions
was queued at that merge; no hosted CI success is claimed. This checkpoint
implements item 23 in the tested scope below; it does not close other items'
performance gates or publish a package.

## Behavior and scope

An eligible two-table INNER JOIN now reads its secondary B-tree for each distinct
outer key and fetches only matching rowids. Duplicate outer keys replay results;
NULL keys do not match. This replaces the previous full inner-table load followed
by an in-memory grouping mislabeled as a physical index search. Outer-table rows
and matching inner records are still materialized; this is not fully streaming
or a universal constant-memory join. Successful probes are cached per execution;
missing-key cache entries are bounded to 1,024.

Eligibility is deliberately narrow: two distinct, unqualified main-schema ordinary
rowid tables, a single-column explicit secondary index, qualified column equality
in the ON AND spine, equal affinities/collations, and BINARY/NOCASE/RTRIM. ASC and
DESC, duplicate/NULL/numeric/text/blob keys, bound parameters, residual predicates,
GROUP BY/HAVING, ordering and LIMIT/OFFSET are covered. INDEXED BY is respected.
Statistics never filter records. A STAT1 average equal-key fanout of at least a
quarter of the index cardinality retains the previous scan/temporary lookup,
unless an explicit INDEXED BY forces the eligible index.

Composite/expression/partial/implicit indexes, WITHOUT ROWID, self joins, more
than two sources, CTEs/derived/nested queries, generated columns, custom functions,
custom collations and other join kinds retain existing execution. Prepared joins
remain unsupported by the existing public preparation contract. Broader physical
join coverage is a future extension, not an implemented claim.

EXPLAIN reports `USING INDEX` for this physical path and `USING TEMPORARY LOOKUP`
for the memory lookup; a fallback scan is labeled SCAN. The 1,024 distinct-key
limit on temporary grouping no longer blocks a selective physical seek merely
because the inner index contains more than 1,024 entries.

## Verification

| Suite | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| core | 10811 | 0 | 1 |
| orm | 259 | 0 | 0 |
| inspector | 55 | 0 | 0 |

There are **34 new tests**, including **425 native result-set comparisons**
(420 across mutable/read-only execution, three encodings and five type/collation
families in both index directions; five fallback comparisons). The reference
CLI is pinned to SQLite 3.53.1 and the source ID documented in the compatibility
matrix. Tests verify result values/order/types, parameters, callback fallback,
fresh writes, collation mismatch, density threshold/forced hints, and the physical
page-read reduction. The existing 1,024/1,025-entry regression now verifies real
seeks beyond the temporary lookup cap. Existing whole-tree regressions pass.

The one skip is the pre-existing SQLCipher external-CLI interoperability test:
`sqlcipher` is unavailable. It is not counted as passed. Core/ORM/Inspector and
new-tool fatal-info analysis and formatting passed. A dedicated indexed-join
assertion program passed on Dart VM and JavaScript/Node; CI now invokes it too.
Compressed JSON event logs, exact counts, raw SHA-256 and final source hashes
are preserved here. The previous correctness evidence is retained separately.

## AOT / IO / memory evidence

Dart 3.13.7, Linux x64, memory-backed images; **60 fresh processes**, five
alternating before/after pairs for six cases. Tests and compilers were stopped
before measurements. Query timings include planning/evaluation; `explain_us`
times the public explain separately, not isolated internal planning. Output
hashes/counts/columns, callback counts/traces and image sizes match in every case.
RSS is whole-process peak. Full ranges/plans are in aot_report.json; raw samples
are in aot_samples.jsonl.

| Case | After/before median time | Page reads | Peak RSS MiB |
| --- | ---: | --- | --- |
| sparse | 0.003 | 280 → 11 | 50.7 → 13.4 |
| small | 0.241 | 4 → 8 | 12.8 → 12.0 |
| dense_fallback | 0.603 | 84 → 84 | 47.7 → 48.1 |
| scan_control | 1.058 | 280 → 280 | 50.7 → 50.6 |
| empty | 0.003 | 280 → 11 | 50.7 → 13.4 |
| callback_control | 0.960 | 280 → 280 | 50.9 → 50.8 |

The scan control's median query time increased about 5.8%, with overlapping
ranges and an 11.7-second baseline outlier; this is not evidence of zero overhead.
Public explain medians also increased, for example 313 → 556 us in the small
case and 216 → 627 us in the dense fallback. These are reported planning costs;
no claim of an isolated internal planning-time measurement is made.

Small-table physical seeks read extra index/rowid pages; the recorded CPU/memory
benefit does not imply an IO reduction for every size. Dense/explicit-scan/custom
callback controls retain the previous strategy. Unknown or stale statistics can
still choose a slower plan. These measurements support the tested selective-join
scope and expose control costs, not a universal speedup or zero-overhead claim.

An initial candidate without the density guard read 6,012 pages versus 84 for
the dense case. That finding led to the STAT1 fallback. Initial single-pair raw
results, compressed source patch, probe snapshot and binary fingerprints are preserved;
those exploratory timings are not the final acceptance evidence.

## Reproduction

From repository root, with Dart 3.13.7 and dependencies installed:

```sh
bash tool/build_sqlite_reference.sh
dart test packages/sqlite_plus/test/optimizer_indexed_join_test.dart
dart analyze --fatal-infos packages/sqlite_plus packages/sqlite_plus_orm packages/sqlite_plus_inspector
dart tool/optimizer_benchmark/indexed_join_assertions.dart
dart compile js tool/optimizer_benchmark/indexed_join_assertions.dart -o /tmp/item23.js
node -e 'globalThis.self=globalThis;require(process.argv[1])' /tmp/item23.js
python3 benchmark_results/optimizer_item23/build.py
```

build.py reconstructs the immutable baseline libraries using git archive, builds
both AOT binaries with the same current probe, generates deterministic images,
and prints the run_aot.py command. Wait for other tests/compilers to finish before
running it. Run the full core/ORM/Inspector suites from each package with
`dart test --timeout 10m --concurrency=2 --reporter json`; localhost socket access
is required. Production remains pure Dart. No merge of this new item is implied.
