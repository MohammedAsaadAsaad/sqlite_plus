"""Render the measured optimization report; never synthesizes benchmark data."""
import json
from pathlib import Path

root = Path('benchmark_results/changes_optimization')
summary = json.loads((root / 'summary.json').read_text())
binaries = json.loads((root / 'binaries.json').read_text())
lines = ['''# Trigger snapshot optimization — 2026-11-07

These are the current workspace measurements. [Initial results](RESULTS.md) are
retained separately. This change needs the unreleased workspace engine revision;
it is not a performance claim for published sqlite_plus 0.1.9.

## What changed

Before each small trigger read, the engine rebuilt a temporary image containing
all application tables and indexes. A tracked row could repeat this for the guard,
changed-column condition and batch-id subquery. Simple trigger reads now copy only
the ordinary unindexed rowid tables they depend on; source-free conditions need
no table rows. The same reader, SQL binding, functions and trigger contexts run.
Views, indexes, WITHOUT ROWID, virtual/schema tables, CTEs, joins and compounds
conservatively retain the full snapshot path. No persistent index/table, log
format, trigger definition, transaction boundary or public API changed.

## Enabled capture

Linux x64, Dart 3.13.7 AOT, in-memory. Five fresh-process old/new pairs at each
size, alternating revision order. Each process runs one untracked control and one
tracked case. Both explicitly enable recursive triggers. Each workload uses
individual UPDATE statements inside one transaction, then reads and checks all
event keys/columns, acknowledges and prunes. Timings below include the write
transaction only. All values are medians in milliseconds.

**The 10k-row case uses 10 updates; the 1k-row case uses 100.** Do not compare
those raw totals as equal workloads. No tests/builds ran concurrently with these
samples; host load and GC remain uncontrolled.

| Source rows | Updates | Old untracked ms | Old tracked ms | New untracked ms | New tracked ms | Tracked speedup |
|---:|---:|---:|---:|---:|---:|---:|''']
for count, r in summary.items():
    m = r['enabled']['update_us']
    vals = [m[label][str(mode)]['median']/1000 for label, mode in [('old',False),('old',True),('new',False),('new',True)]]
    lines.append(f"| {count} | {r['updates']} | " + ' | '.join(f'{v:,.3f}' for v in vals) + f' | {vals[1]/vals[3]:.1f}x |')
lines += ['''
The control measures general write cost in the same build; the old/new tracked
comparison measures this optimization. Ratios here are workload-specific, not a
phone or sustained-throughput guarantee. Min/max samples are preserved in the
raw summary. High-write-volume adoption still needs persisted/device and larger
retained-log measurements. Single-row transactions and multiple tracked tables
are not benchmarked here.

## Disabled gate

The same existing mixed workload runs with Changes linked and never activated:
inserts, 500 point reads, 50 range reads, 200 updates in one transaction, 20
autocommit updates, search-index creation, 20 warmed searches and export. Five
fresh-process pairs per size. Search uses its own existing log.

| Rows | Workload | Before ms | After ms | Delta |
|---:|---|---:|---:|---:|''']
slowdowns = []
for count, r in summary.items():
    for metric, m in r['disabled'].items():
        a, b = m['old']['median'], m['new']['median']
        lines.append(f'| {count} | {metric} | {a/1000:,.3f} | {b/1000:,.3f} | {(b/a-1)*100:+.2f}% |')
        if metric != 'export' and b > a and m['new']['min'] > m['old']['max']:
            slowdowns.append(f'{count}/{metric}')
if slowdowns:
    lines.append('\nTiming increases outside min/max overlap: ' + ', '.join(slowdowns) + '. Further investigation is required before closing this timing gate.')
else:
    lines.append('\nNo timing increase outside min/max sample overlap was observed. Faster results\nare not attributed to the package; AOT layout and host variation affect timings.\nMicrosecond export totals are below useful comparative precision.')
lines += ['\nEvery disabled image SHA-256 matches across all ten processes at each size:\n']
for count, r in summary.items():
    assert r['disabled_images_equal']
    lines.append(f"- {count} rows: {r['image_bytes']:,} bytes, identical before/after.")
confirmation = root / 'disabled_confirmation_summary.json'
if confirmation.exists():
    repeat = json.loads(confirmation.read_text())
    lines += ['''
### Additional disabled confirmation

Positive 1k medians in the first five pairs prompted ten additional alternating
fresh-process pairs with identical binaries/workload and no concurrent tests.
Both data sets are retained; this is not a replacement for inconvenient samples.
Every repeated image hash also agrees. The repeat medians are:

| Workload (1k rows) | Before ms | After ms | Delta |
|---|---:|---:|---:|''']
    for metric, values in repeat.items():
        if metric.endswith('seconds'):
            continue
        a, b = values['old']['median'], values['new']['median']
        lines.append(f'| {metric} | {a/1000:,.3f} | {b/1000:,.3f} | {(b/a-1)*100:+.2f}% |')
    cpu = repeat['cpu_seconds']
    wall = repeat['wall_seconds']
    lines.append(f"\nWhole-process CPU seconds (median before/after): {cpu['old']['median']:.3f} / {cpu['new']['median']:.3f}; "
                 f"wall seconds: {wall['old']['median']:.3f} / {wall['new']['median']:.3f}. "
                 'These include setup and all phases, unlike the per-phase wall timings. '
                 'A strict zero-cost claim is not established by these host-dependent measurements.')
lines += ['''
## Size and memory

The enabled before/after image sizes agree for every corresponding sample.
No additional persistent structure was introduced by this optimization.

| Rows | Source bytes | Ready bytes | After writes bytes | After prune bytes |
|---:|---:|---:|---:|---:|''']
for count, r in summary.items():
    vals = [r['enabled'][metric]['new']['True']['median'] for metric in ['source_bytes','ready_bytes','logged_bytes','after_prune_bytes']]
    lines.append(f'| {count} | ' + ' | '.join(f'{v:,}' for v in vals) + ' |')
lines += ['''
These are in-memory image sizes. Physical file shrinking and APK size are not
measured. RSS below is from disabled mixed-workload processes; GC is not forced.
Peak RSS includes all phases. Neither equal nor lower heap use is established.

| Rows | End RSS median before/after bytes | Peak RSS median before/after bytes |
|---:|---:|---:|''']
for count, r in summary.items():
    values = [r['memory'][metric][label]['median'] for metric, label in [('rss','old'),('rss','new'),('peak_rss','old'),('peak_rss','new')]]
    lines.append(f'| {count} | {values[0]:,} / {values[1]:,} | {values[2]:,} / {values[3]:,} |')
delta = binaries['new_disabled']['bytes'] - binaries['old_disabled']['bytes']
lines += [f'\nThe linked Linux disabled executable changes by {delta:+,} bytes. This is\ncompiled code size, separate from database size.', '''
## Verification and limits

- Engine: 10,630 tests pass; one SQLCipher CLI test skipped because that tool is
  absent. Twelve trigger snapshot tests compare with pinned official SQLite
  3.53.1 and check exported image integrity/reopen, including nested writes,
  generated/Unicode values, 512-byte UTF-8/UTF-16 pages and conservative fallbacks.
- Changes: 35 tests pass, including 80 injected storage-operation fault points
  across capture/ack/prune/track. Existing search: 86 pass; Flutter catalog: 17.
- VM and compiled JavaScript/Node shared assertions pass. Analysis is clean.
- The initial sandboxed engine/app runs could not bind local sockets; complete
  engine and app reruns with local networking pass. Remote CI was not run.
- No app activation, file migration, new package release, physical-device timing,
  real browser persistence or new WAL-specific Changes recovery claim.

Only image_mutations.dart changed among the 97 previously recorded engine/search
runtime files. The existing search edits and metadata workarounds are preserved.
This optimizes a general trigger read path; it does not install Changes hooks in
ordinary writes. The scoped producer API and all existing limitations remain.

## Reproduce

Use Dart 3.13.7 from repository root at this workspace revision. Reconstruct the
old engine file into a separate output (without changing the working source):

```sh
patch --reverse --output=/tmp/changes-baseline.dart \\
  packages/sqlite_plus/lib/src/sql/image_mutations.dart \\
  < benchmark_results/changes_optimization/engine_optimization.patch
python3 tool/changes_benchmark/build_optimization.py /tmp/changes-baseline.dart
python3 tool/changes_benchmark/optimize.py \\
  /tmp/changes-opt-old-enabled /tmp/changes-opt-new-enabled \\
  /tmp/changes-opt-old-disabled /tmp/changes-opt-new-disabled
python3 tool/changes_benchmark/report_optimization.py
```

The build helper temporarily substitutes the baseline source and restores the
current file in finally. Do not run other builds/tests during that step or during
measurement. Source hashes are checked before compiling and before/after runs.
All process results, ranges, hashes, sizes and the isolated source patch are in
[benchmark_results/changes_optimization](../../../benchmark_results/changes_optimization).
''']
Path('packages/sqlite_plus_changes/benchmark/OPTIMIZATION.md').write_text('\n'.join(lines))
print('report generated; timing increases outside overlap:', slowdowns)
