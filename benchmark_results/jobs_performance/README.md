# Jobs processing performance follow-up

The original 1000-row/10-job in-memory workload improved from **4016.599ms to
34.278ms (117.2×)** in three fresh processes per variant. The standalone phase
driver gives 4026.429ms ->32.083ms under a normalized starting image. Logical
rows, attempts and FIFO outcomes match. These are descriptive Linux x64 AOT/Dart
3.13.7 samples on a shared host, not universal latency or release guarantees.

## Changes

- Jobs projects nine scheduling fields through a bound queue-equality read and
  chooses priority DESC/creation/id ASC inside the same exclusive transaction.
  It does not load payloads or retain a separate scheduler cache. SQL lease
  guards and normal row constraints still execute.
- Core safely narrows integer rowid equalities inside AND, then evaluates the
  original predicate on the candidate. Functions, subqueries in predicates,
  generated columns, coercions and shadowed rowid aliases retain fallbacks.
- Index-preservation checks skip shared unchanged records and resolve the union
  of referenced column offsets once per check. Stored values are still compared;
  uniqueness/trigger/FK validation is not removed.
- Fix an existing stale live equality-read cache after prepared ordinary INSERT.
  Clear that cache before subsequent reads; retain the existing append-order
  optimization. Regression checks append, rollback and failed multirow inserts.

No schema, file-format or public API change; no automatic index creation,
migration, native runtime dependency or package-specific engine hooks.

## Timings

76 final fresh-process samples in runs.json. Before/after process order rotates
within each comparison; all processes run sequentially without concurrent tests,
compilation or profiling. Initialization is excluded from processing timers.
The phase driver materializes the starting image for both variants, then measures
claim and complete separately. Every sample checks all final rows and attempts.
summary.json includes medians, ranges and RSS; no samples were discarded.

| Workload | Before median ms | After median ms | Samples/variant |
| --- | ---: | ---: | ---: |
| Original driver: 10 pairs, depth 1000, memory |4016.599 |34.278 |3 |
| Phase driver: 100 pairs, depth 100, memory |4330.897 |272.668 |3 |
| Phase driver: 10 pairs, depth 1000, memory |4026.429 |32.083 |3 |
| Phase driver: 10 pairs, depth 1000, file |5173.096 |1753.273 |3 |
| Full 1000-job drain, memory |unmeasured |3139.026 |3 candidate |
| Ten pairs, depth 10000, memory |unmeasured |179.613 |3 candidate |

At depth 1000 in memory, accumulated claim medians are 2885.707 ->18.368ms;
complete 1153.546 ->13.622ms. Phase medians need not sum to the total median.
File claim remains 1726.337ms versus complete 24.774ms: file processing still has
material image/storage costs. The file fixture uses rollback journals and
existing temporary files on **tmpfs**, with flushes/commits inside timers. It is
not a physical-device throughput or directory-durability/power-loss acceptance.

A full 1000-job drain was measured only after optimization; do not infer a formal
before/after ratio for that case. Seeding medians are 662.696ms at 1000 and 6748.639ms
at 10000. Processing still depends on retained queue depth and schema; the 10000
case processes ten jobs, not a full 10000-job drain. No million-row claim.

## Other engine workloads

Same ordinary driver compiled against copied old/new core packages, five fresh
processes per variant/mode. Read performs 10000 point queries over 1000 rows;
insert/update/guarded perform 1000 bound statements in one transaction, including
commit. Guarded is `UPDATE items SET n=n+1 WHERE id=? AND n=?`.

| Mode | Before ms (range) | After ms (range) | Median change |
| --- | ---: | ---: | ---: |
| Read |35.841 (34.868–40.761) |35.997 (35.622–36.293) |+0.44% |
| Insert |1.656 (1.586–1.787) |1.676 (1.562–2.104) |+1.21% |
| Update |3.466 (3.148–3.713) |3.631 (3.307–4.984) |+4.76% |
| Guarded update |13525.313 (13128.562–13660.733) |179.696 (170.924–196.372) |-98.67% |

Ordinary ranges overlap; small positive medians are reported, not hidden or
claimed as zero overhead. The earlier ORM import improvement remains: three
samples/variant give 1000-row apply 132.853 ->118.695ms, with identical logical
AND physical image hashes and unchanged 28672-byte file. This small import delta
is descriptive; the important result is no return to the old 13-second workload.

## Size, memory and correctness

Original workload file size stays 180224 bytes. Logical SHA agrees across all
matched old/new workloads. Physical hashes can differ in memory because image
publication histories differ; file-backed phase hashes agree in these samples.
Full 1000-job drain ends at 188416 bytes; depth 10000 at 1523712 bytes. No schema or
extra persistent index is introduced. Metadata projection adds temporary memory
proportional to retained rows in the selected queue; explicit retention still
releases dedup keys, so choose a retention policy intentionally.

Original workload RSS ranges: before 46.78–47.33MB, after 30.45–31.23MB (decimal MB).
At 10000 rows RSS is 81.09–81.51MB and peak 96.54–96.89MB. Process readings are not
attributable allocations or hard heap caps. Binary sizes/hashes are recorded in
manifest.json; benchmark binary size is not package-download size.

Final full core: 10681 pass/one optional SQLCipher CLI skip. Add-ons 514 pass
(including 55 Jobs cases); Search 86 pass. After removing only a redundant
append-order cache reset, final 77 targeted cases (Jobs/pagination/point guards)
pass. Expanded native comparisons also pass separately in all three encodings,
including SET/WHERE subqueries, alias/coercion/NULL/BLOB/int64 boundaries and
exported-image integrity. Callback, constraint/FK/trigger and rollback tests pass.
Existing Jobs storage fault injection and file reopen tests are retained.

Jobs and ORM direct-write assertion examples pass on VM and compiled JS/Node.
Affected format/fatal-info analysis pass. No actual browser/device, independent
process/isolate/connection ownership, remote CI, Windows/macOS, physical-device
storage or general production publication acceptance is claimed. Generator was
not rerun; its source did not change. Dedicated native CI cases were added.

## Reproduction and archived work

See [tool instructions](../../tool/jobs_performance/README.md). Baseline packages
are copied to a temporary directory and only this milestone's core/queue patches
are reversed. Reconstruction was checked against before_manifest.json SHA256.
All drivers and other packages are shared across variants. manifest.json pins
final runtime/driver sources and compiled binaries; core.patch and queue.patch
reconstruct the exact production baseline without altering the working tree.

profile_before.json is diagnostic JIT data from ten pairs at depth 1000, excluding
seeding, retaining the top 60 global functions before SQL filtering. It identifies
row context, image publication and index-key comparison work; it is not AOT timing.
stage1_runs.json and partial stage2_runs.json are archived exploratory variants,
not mixed into final medians. The original jobs milestone evidence is preserved
in ../jobs. The legacy frozen baseline binary has its own manifest; final
comparisons recompile the canonical pre-milestone sources.
