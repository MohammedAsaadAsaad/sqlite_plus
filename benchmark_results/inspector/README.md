# Inspector AOT evidence

Linux x64, Dart 3.13.7, 2026-11-07. In-memory single-connection workload.
No engine/ORM execution source changed; SHA-256 comparison against the baseline
Git head is in manifest.json. This is an optional wrapper, not a new hook on
every engine operation. No claims about APK size or real device/browser timings.

## Workload

One AOT binary with runtime modes `direct`, `disabled`, `enabled` keeps the same
linked feature code for comparison. Every process constructs an inspector and
wrapper; `direct` calls the engine directly, `disabled` calls the disabled wrapper,
and `enabled` records metadata. Thus direct is a call-path baseline, not a binary
with the inspector absent. The optional ORM/IO entry points are not used here.

Each fresh process populates 1000 or 10000 rows before the measured interval,
performs 200 primary-key point reads, 20 ranges of 20 rows and 50 point updates.
Every read shape and the final sum are asserted. Setup, final checksum/export
and JSON reporting are excluded from measured wall time. Query formatting and
recording are included. All variants must produce identical final database images.
Five fresh processes per mode/size; mode order rotates per iteration. No samples
are removed. Measurements were collected after tests/JS compilation finished.

| Rows | Direct median | Disabled median | Enabled median | Enabled vs direct | Image bytes |
|---:|---:|---:|---:|---:|---:|
| 1000 | 7.881 ms | 7.143 ms | 8.134 ms | +3.2% | 20480 |
| 10000 | 10.176 ms | 9.294 ms | 10.792 ms | +6.1% | 110592 |

Enabled-vs-disabled median increments were 0.991 ms at 1000 rows and 1.498 ms
at 10000, spread over 270 observed statements. This comparison is also subject
to process/allocator/host variance. Disabled medians happen to be lower than
direct here; that is not evidence of a disabled-wrapper speed optimization or
a strict zero-regression guarantee. The wrapper still has method/closure/branch
costs. Sample ranges and all raw values are available in runs.json.

Enabled records were exactly 270, grouped into 3 templates. Direct/disabled
recorded zero statements. Final image sizes/hashes match at each scale; no
inspector table/index/log is stored in the database. Read/write results and
checksums match; no statement is replayed by the collector.

RSS and peak RSS include population, engine caches, both wrapper construction
and GC/allocator timing, so they are not isolated profiler allocation overhead.
The retained record/group/scoping limits bound metadata counts, not engine
materialization, transient tokenization bytes or caller-held report snapshots.
Small timing differences and RSS differences should not be generalized to
other devices. No large strings/BLOBs, large concurrency, ORM/file/plan cost,
100k/1m rows, real browser persistence or physical power-loss workload was timed.

## Reproduction

From the matching workspace with dependencies resolved:

```sh
dart compile exe tool/inspector_benchmark/main.dart -o /tmp/inspector-benchmark
/tmp/inspector-benchmark direct 1000
/tmp/inspector-benchmark disabled 1000
/tmp/inspector-benchmark enabled 1000
```

Repeat five times per mode and with 10000 rows, rotating mode order. The output
is standalone JSON with timings, checksums, observation counts and memory.
Use runs.json and manifest.json for the recorded raw data, environment and
binary/source fingerprints. The executable stays local and is not committed.
