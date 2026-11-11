# Import/UPSERT performance follow-up (2026-11-08)

Goal: improve the measured ~13s/1000-row apply phase without weakening row
constraints, uniqueness/collations, transaction rollback, counters or triggers.
Preserve the existing local preview/import/diagnostics work and its historical
measurements. No publication, push or main merge is implied.

## Evidence and changes

- Baseline fingerprints/binary: benchmark_results/import_performance/before_manifest.json.
- VM CPU profile: 10,950 of 11,678 sampled stacks (~94%) include _validate.
  It was reached through accept for every UPSERT update because prepare() did
  not preserve the prepared flag. Profile is diagnostic JIT data, not AOT timing.
- [x] Preserve successful preparation so eligible same-row updates avoid global
  revalidation. Key changes/complex indexes retain full validation.
- [x] Statement-local SplayTree conflict lookups use the actual SQL comparator;
  NULL/composite/BLOB/NOCASE/RTRIM semantics are not approximated by text hashing.
- [x] Conservative cache eligibility: ordinary rowid tables/full column indexes,
  no generated columns, enforced FK metadata or triggers. FK-enabled databases
  with no actual FK definitions remain eligible. Complex cases retain old lookup.
- [x] Eligible new rows validate constraints/unique keys before updating caches;
  same-key replacements update lookup values, slow mutations invalidate trees.
- [x] Lazy rowid/slot lookups avoid repeated linear searches; slots are verified
  and invalidated with resident state on rollback/structural changes.
- [x] Prepare CHECK contexts only when actual CHECK expressions exist; constraints
  are still evaluated on each candidate. Reuse expression lists, never values.

Initial AOT probes dropped the same workload from ~13s to 0.13–0.15s apply and
preserved its logical AND physical image hash. These are initial single samples,
not final medians or a universal throughput guarantee.

## Verification/delivery gates

- [x] Existing core suite passed before the last CHECK-context simplification:
  10,667 pass / one optional SQLCipher CLI skip.
- [x] New unit/native scenarios: repeated/mixed targets, rollback, changed unique
  keys, NULLs, NUL/collations, composite/BLOB, partial/expression fallback, triggers,
  AUTOINCREMENT, changes()/returning and cross-open integrity in three encodings.
- [x] Final full core and affected package regressions.
- [x] VM/JS assertion examples and final format/analysis.
- [x] Final reproducible AOT comparison, scale and SKU insert/update/mixed shapes;
      compare ordinary read/insert/update performance and record memory/footprint.
- [x] Update performance documentation, compatibility/log and CI definitions.

A test harness initially retained leading spaces when splitting CREATE INDEX SQL;
its exported index schema also fails native parsing with the fingerprinted old
core. Trim split setup statements consistently; this milestone does not claim to
fix general schema-text leading-trivia normalization. Fallback expression-index
logical results and normalized-DDL files are still checked against native SQLite.

Final evidence: benchmark_results/import_performance/README.md. Main apply median
13.972s -> 0.119s; total 0.172s. Full core 10673/addons 459 passed. Additional
ordinary-update follow-up retains a small absolute overhead (+0.383ms/1000);
strict zero-regression is not claimed. 10k nonlinear growth and memory limits
are documented. CI definitions updated; remote execution remains unverified.
