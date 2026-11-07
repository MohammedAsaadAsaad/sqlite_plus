"""Render actual AOT evidence; no extrapolated or fabricated measurements."""
import json
from pathlib import Path
import statistics

root=Path('benchmark_results/sync')
summary=json.loads((root/'disabled_summary.json').read_text())
manifest=json.loads((root/'manifest.json').read_text())
enabled=json.loads((root/'enabled_100.json').read_text())
initial=json.loads((root/'initial/enabled_100.json').read_text())
lines=['''# Sync AOT measurements — 2026-11-07

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
|---|---:|---:|''']
metrics=[('activation_bootstrap_us','Setup / bootstrap',1000),('capture_100_us','Capture 100 local UPDATEs',1000),('run_once_us','runOnce (100 mutations + own echo pull)',1000),('source_bytes','Source image bytes',1),('ready_bytes','Ready image bytes',1),('log_bytes','Image after local writes bytes',1),('after_sync_bytes','Image after runOnce bytes',1)]
for metric,label,divisor in metrics:
 vals=[statistics.median(r[metric] for r in enabled['samples'] if r['sync']==mode)/divisor for mode in [False,True]]
 lines.append(f'| {label} | '+ ' | '.join(f'{v:,.3f}' if divisor==1000 else f'{v:,.0f}' for v in vals)+' |')
lines+=['''
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
|---|---:|---:|''']
for metric,label in [('capture_100_us','Local capture'),('run_once_us','runOnce')]:
 a=statistics.median(r[metric] for r in initial['samples'] if r['sync'])/1000
 b=statistics.median(r[metric] for r in enabled['samples'] if r['sync'])/1000
 lines.append(f'| {label} | {a:,.3f} | {b:,.3f} |')
lines+=['''
## Disabled gate

The baseline executable predates Sync and the new Changes scope APIs. The after
executable keeps a runtime-reachable Sync activation/resolution demo but never
activates it in this workload. Both execute the exact same pre-existing mixed
workload source: insert, point/range reads, batched/autocommit updates, search
index build, warmed keyword searches and export. Five alternating fresh-process
pairs per size, not both binaries built from an already changed runtime.

| Rows | Workload | Before ms | Disabled ms | Median delta |
|---:|---|---:|---:|---:|''']
slow=[]
for count,r in summary.items():
 for metric,m in r['timings'].items():
  a,b=m['before'],m['disabled']
  lines.append(f"| {count} | {metric} | {a['median']/1000:,.3f} | {b['median']/1000:,.3f} | {(b['median']/a['median']-1)*100:+.2f}% |")
  if metric!='export' and b['median']>a['median'] and b['min']>a['max']:slow.append(f'{count}/{metric}')
if slow:lines.append('\nTiming increases outside min/max sample overlap: '+', '.join(slow)+'. Investigate before closing that timing gate.')
else:lines.append('\nNo timing increase outside min/max sample overlap was observed. Faster samples\nare not attributed to Sync: executable layout, host load and GC vary. Export\ntotals close to a few microseconds have limited comparative precision.')
lines+=['\nEvery image hash matches before/disabled across ten processes per size:\n']
for count,r in summary.items():
 assert r['all_images_equal']
 lines.append(f"- {count} rows: {r['image_bytes']:,} bytes, SHA-256 identical.")
lines+=['''
No Sync tables, triggers, network calls or background processing are activated in
this workload. Equal images do not establish identical heap or universal zero
CPU overhead.

| Rows | End RSS median before/disabled bytes | Peak RSS median before/disabled bytes |
|---:|---:|---:|''']
for count,r in summary.items():
 m=r['memory'];lines.append(f"| {count} | {m['rss']['before']['median']:,} / {m['rss']['disabled']['median']:,} | {m['peak_rss']['before']['median']:,} / {m['peak_rss']['disabled']['median']:,} |")
delta=manifest['binaries']['disabled']['bytes']-manifest['binaries']['before']['bytes']
lines.append(f'\nThe deliberately linked Linux executable grows by {delta:,} bytes. This is\ncompiled code size, not database or Android APK growth. RSS is sampled without\nforced GC; peak RSS includes all phases. Strict memory equivalence is unproved.')
lines+=['''
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
''']
Path('packages/sqlite_plus_sync/benchmark/RESULTS.md').write_text('\n'.join(lines))
print('report generated; timing increases outside overlap:',slow)
