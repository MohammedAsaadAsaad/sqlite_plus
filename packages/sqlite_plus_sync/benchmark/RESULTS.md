# Sync AOT measurements — 2026-11-07

Linux x64, Dart 3.13.7 AOT, in-memory. No tests/builds ran concurrently with the
measured process runs. Host load and GC remain uncontrolled. These are working
revision measurements, not published-package, device, physical-storage or real
network results.

## Enabled cost and image size

100 existing source rows, 100 individual local UPDATE statements in one Changes
transaction. Three samples per mode in alternating order inside one AOT process.
Control enables Changes only. Sync mode creates Sync metadata and explicitly
bootstraps the existing rows before measuring later local writes. The transport
is the development in-memory reference server; it is not a network benchmark.
Every mutation/result count and final source checksum is checked.

All time values are medians in milliseconds. Activation includes bootstrap in
Sync mode, so that phase does more work than the Changes-only control.

| Metric | Changes only | Changes + Sync |
|---|---:|---:|
| Setup / bootstrap | 6.599 | 138.064 |
| Capture 100 local UPDATEs | 276.667 | 292.635 |
| runOnce (100 mutations + own echo pull) | 0.000 | 178.515 |
| Source image bytes | 8,192 | 8,192 |
| Ready image bytes | 36,864 | 90,112 |
| Image after local writes bytes | 45,056 | 98,304 |
| Image after runOnce bytes | 45,056 | 98,304 |

The control performs no synchronization, so its zero runOnce time is not a
throughput comparison. Logs are retained until explicit Changes pruning.
Outbox deletion can leave reusable pages; physical file shrinking is not promised.
Per-writer revision maps grow with all known synchronized keys. These samples do
not establish large-log memory/throughput bounds or sustained performance.

## Diagnostic bottleneck and correction

The first activated sample exposed repeated full image reconstruction once
sqlite_schema exceeded one page. Row appends could not resolve index roots through
that schema shape. The engine now walks multi-page/overflow catalog records,
retains the conservative single-leaf truncation restriction, and resolves table
roots against the actual image with an image-scoped cache. Sync also loads row
revisions once per writer scope instead of rereading after each metadata update.

The initial activated sample is retained separately. It is an earlier revision,
not an interleaved old/new performance experiment; the large difference identifies
the bottleneck but is not a device speedup guarantee.

| Phase (100 rows / 100 updates) | Initial diagnostic ms | Final ms |
|---|---:|---:|
| Local capture | 5,141.176 | 292.635 |
| runOnce | 4,803.303 | 178.515 |

## Disabled gate

The baseline executable predates Sync and the new Changes scope APIs. The after
executable keeps a runtime-reachable Sync activation/resolution demo but never
activates it in this workload. Both execute the exact same pre-existing mixed
workload source: insert, point/range reads, batched/autocommit updates, search
index build, warmed keyword searches and export. Five alternating fresh-process
pairs per size, not both binaries built from an already changed runtime.

| Rows | Workload | Before ms | Disabled ms | Median delta |
|---:|---|---:|---:|---:|
| 1000 | insert | 28.479 | 27.092 | -4.87% |
| 1000 | point_500 | 2.474 | 2.376 | -3.96% |
| 1000 | range_50 | 20.284 | 20.413 | +0.64% |
| 1000 | update_batch_200 | 806.889 | 807.870 | +0.12% |
| 1000 | update_auto_20 | 80.752 | 80.569 | -0.23% |
| 1000 | search_index | 144.936 | 142.457 | -1.71% |
| 1000 | search_20 | 40.560 | 41.109 | +1.35% |
| 1000 | export | 0.009 | 0.009 | +0.00% |
| 10000 | insert | 588.297 | 568.718 | -3.33% |
| 10000 | point_500 | 2.961 | 2.931 | -1.01% |
| 10000 | range_50 | 21.737 | 21.594 | -0.66% |
| 10000 | update_batch_200 | 7,748.954 | 7,764.806 | +0.20% |
| 10000 | update_auto_20 | 794.041 | 777.358 | -2.10% |
| 10000 | search_index | 3,313.129 | 3,286.811 | -0.79% |
| 10000 | search_20 | 181.360 | 185.671 | +2.38% |
| 10000 | export | 0.221 | 0.248 | +12.22% |

No timing increase outside min/max sample overlap was observed. Faster samples
are not attributed to Sync: executable layout, host load and GC vary. Export
totals close to a few microseconds have limited comparative precision.

Every image hash matches before/disabled across ten processes per size:

- 1000 rows: 172,032 bytes, SHA-256 identical.
- 10000 rows: 1,155,072 bytes, SHA-256 identical.

No Sync tables, triggers, network calls or background processing are activated in
this workload. Equal images do not establish identical heap or universal zero
CPU overhead.

| Rows | End RSS median before/disabled bytes | Peak RSS median before/disabled bytes |
|---:|---:|---:|
| 1000 | 49,831,936 / 51,269,632 | 54,554,624 / 54,525,952 |
| 10000 | 62,939,136 / 62,902,272 | 214,437,888 / 215,818,240 |

The deliberately linked Linux executable grows by 169,224 bytes. This is
compiled code size, not database or Android APK growth. RSS is sampled without
forced GC; peak RSS includes all phases. Strict memory equivalence is unproved.

## Verification

- Full engine: 10,634 pass; one optional SQLCipher CLI check skipped because its
  executable is absent. Four new catalog tests include 512-byte UTF-8/UTF-16
  schemas, overflow, corruption rejection, rollback/VACUUM and pinned native roots.
- Sync: 60 tests, including 24 recovery scenarios/380 injected storage-operation
  faults, two native SQL/image checks and existing search autoUpdate coexistence.
- Changes: 38 tests, including its 80 injected storage-operation fault points.
- Search: 86; existing Flutter catalog: 17. VM and compiled Node shared assertions
  pass for Sync and Changes. No full production/server/device compatibility claim.
- Core/Changes/Sync analysis is clean. A Linux CI job and pinned-reference build
  helper are added; remote CI and the new download/build helper were not executed.
- Current apps remain unchanged. No server deployment, package publication,
  physical-device timing, real browser persistence or new WAL-specific Sync claim.

Exactly two of the 97 captured engine/search runtime files changed for this
milestone: catalog-root discovery/page patching and the image mutation root cache.
Changes APIs are additive and its stored log format remains unchanged. The Sync
metadata layout uses ordinary tables/indexes with conservative anchors. Raw source,
package and binary hashes plus the isolated engine patch are retained below.

## Reproduce

Use Dart 3.13.7 and this working revision. The original baseline binary was
captured before Sync implementation; its size/hash and pre-change runtime hashes
are recorded in manifest.json. Reconstruct that engine revision in an isolated
checkout by reversing both `engine_optimization.patch` and `changes_api.patch`,
then build the existing `tool/changes_benchmark/after.dart` entry point as the
baseline. Baseline core and all six Changes library source hashes are recorded;
the reconstructed Changes files were checked against the pre-Sync hashes. Do not compare
against two binaries both built with the already optimized engine.

With the recorded baseline at /tmp/changes-opt-new-disabled:

```sh
dart compile exe tool/sync_benchmark/after.dart -o /tmp/sync-disabled
dart compile exe packages/sqlite_plus_sync/benchmark/enabled.dart -o /tmp/sync-enabled
python3 tool/sync_benchmark/compare.py
python3 tool/sync_benchmark/report.py
```

The comparison validates source hashes, unchanged mixed-workload source, both
image hashes and retained runtime sources. Full process results and ranges:
[benchmark_results/sync](../../../benchmark_results/sync). Initial activated
measurements and their source/binary hashes are in its initial directory.
