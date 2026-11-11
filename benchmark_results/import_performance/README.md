# Core UPSERT/import performance (2026-11-08)

The same frozen 1000-row import apply workload improved from **13,971.559ms to
119.110ms (117.3×)**, with identical logical rows AND exported SQLite image SHA256.
Preparation remained about 52ms. Total prepare+apply median: **14,024.795ms →
171.626ms (81.7×)**. These are three fresh processes per variant, alternating order,
Linux x64 AOT/Dart 3.13.7, default UTF-8, in-memory database. Seeding is excluded;
apply includes its transaction. No concurrent tests/compilers ran during sampling.
Shared-host samples describe these workloads, not universal latency guarantees.

## Root cause and implementation

A successful prepare did not retain its prepared flag during UPSERT updates.
That forced whole-database constraint validation for every conflict row. The old
JIT profile contains `_validate` in 10,950/11,678 sampled stacks (~94%). The core
now preserves preparation and reuses same-row validation when unique keys remain
SQL-equivalent. New statement-local ordered conflict trees use the actual SQL
comparator (NULL/composite/BLOB/NOCASE/RTRIM/NUL), with lazy rowid/slot caches and
CHECK context creation only when checks exist. Constraints remain enforced.

Fast insert/conflict lookup is restricted to ordinary rowid/full-column-index
shapes without generated columns, triggers or enforced FK metadata anywhere in
the database. ORM enables foreign_keys; that alone no longer prevents the fast
path when no foreign keys exist. Complex indexes, key changes and actual foreign
keys retain conservative validation paths. No schema migration, persistent
shadow table, index or production native dependency was added.

## Measurements

`runs.json` contains 54 fresh-process samples. `summary.json` includes medians,
ranges and RSS. `ordinary_update_followup.json` adds 24 separate update samples.
The original historical workflow measurements remain in ../workflows.

| Workload | Rows | Samples/variant | Before apply ms | After apply ms |
| --- | ---: | ---: | ---: | ---: |
| Existing primary-key import | 1000 | 3 | 13971.559 | 119.110 |
| SKU NOCASE, all inserts | 100 | 1 probe | 214.761 | 14.071 |
| SKU NOCASE, all updates | 100 | 1 probe | 587.548 | 34.059 |
| SKU NOCASE, half existing | 100 | 1 probe | 239.012 | 20.031 |
| SKU NOCASE, all inserts | 1000 | 3 candidate | unmeasured | 347.903 |
| SKU NOCASE, all updates | 1000 | 3 candidate | unmeasured | 433.603 |
| SKU NOCASE, half existing | 1000 | 3 candidate | unmeasured | 364.794 |
| Existing primary-key import | 10000 | 3 candidate | unmeasured | 3896.570 |

SKU 1000 preparation medians: insert286.235ms/update287.662ms/mixed275.719ms.
These schemas include generated integer IDs, NOT NULL fields and a price CHECK.
SKU 100 before/after probes match logical and physical image hashes; one probe
cannot establish stable speedup. No measured SKU 1000 before/after ratio is claimed.

10,000-row preparation median is 2114.892ms and total prepare+apply median
6004.646ms. Growth is not linear: 10× rows takes substantially more than 10× time.
Input duplicate checking, transaction/image work and buffering remain costs;
this does not establish streaming or million-row suitability.

### Ordinary operations

Same driver compiled against old/new core; five fresh processes per variant,
rotating order. Read performs 10,000 point queries over 1000 rows; write performs
1000 bound statements in one transaction, including commit. All final rows and
exported image hashes match between variants.

| Mode | Before median ms (range) | After median ms (range) | Change |
| --- | ---: | ---: | ---: |
| Read | 37.059 (34.967–40.916) | 36.758 (34.742–45.593) | -0.81% |
| Insert | 1.726 (1.567–2.689) | 1.633 (1.472–1.725) | -5.39% |
| Update | 3.307 (3.265–4.899) | 3.569 (3.428–3.912) | +7.92% |

The update signal prompted 12 additional fresh processes/variant, alternating
order: before **3.475ms** (3.276–4.070), after **3.858ms** (3.224–5.723), **+11.02%**,
or 0.383ms/1000 writes. Ranges overlap but that does not establish zero overhead.
This small absolute regression remains an explicit performance limitation; no
strict zero-regression gate is claimed. Earlier exploratory stage3 runs are kept
separately, not substituted for final samples.

### Size and memory

The main 1000-row exported file remains **28,672 bytes**, with identical physical
SHA256. SKU files are 12,288 bytes at 100 rows and 57,344 bytes at 1000 rows. Main 10k is 217,088
bytes. No disk-index growth is introduced. Cache memory is proportional to rows
and keys when used; ordinary operations do not build UPSERT conflict trees/slots.
Main 1000 process RSS: before 62.61–62.90MB, after 66.62–72.04MB (decimal MB).
RSS is a process reading, not attributable allocated bytes or a hard memory cap.
Main 10k peak RSS is 255.07–272.94MB and must be considered before
using larger buffered imports. AOT binary sizes and hashes are in manifest.json;
these include development benchmark code and are not library download-size claims.

## Correctness and reproduction

Final full core: **10,673 pass, one optional external SQLCipher CLI skip**.
ORM/Branch/Inspector/Changes/Reactive/Sync: **459 pass**. Search 86 and generator 78
also passed earlier in this follow-up, before the final no-FK eligibility widening.
Native differential checks cover three text encodings, collation/NUL/composite
keys, rollback after late conflicts, FK violations, triggers, partial/expression
index fallback, generated IDs, counters, RETURNING and cross-open integrity.
VM and compiled JS/Node import-preview and diagnostics examples pass.
Affected 329 Dart files need no formatting; fatal-info analysis is clean. A whole
workspace format dry run flags seven existing Flutter-example formatting
mismatches and unavailable flutter_lints; those examples were not rewritten.

A schema setup harness originally preserved leading spaces before CREATE INDEX;
that native schema-parsing issue also reproduces on the old core. The harness
trims split setup SQL. This change does not fix general leading-trivia schema
normalization. No actual browser/device, remote CI, Windows/macOS or file-backed
performance acceptance is claimed.

See [tooling/reproduction instructions](../../tool/import_performance/README.md).
`before_manifest.json` pins the old core/base commit and preserved workflow binary;
`manifest.json` fingerprints final core/unchanged ORM/drivers and all compared
binaries. New ordinary/SKU baselines override only sqlite_plus to that old core.
`profile_before.json` and `profile_after.json` are diagnostic JIT whole-workflow
profiles, not AOT timing comparisons; the driver retains the top 60 global functions.
