# sqlite_plus_jobs — AOT evidence and limits

Historical first-milestone measurements. The [processing follow-up](../jobs_performance/README.md)
supersedes the processing bottleneck below for its measured workloads; original
data and fingerprints are preserved. File/depth/platform limits remain explicit.

Linux x64, Dart 3.13.7, native AOT, in-memory UTF-8, fixed synthetic timestamps and
small JSON payloads. Nine fresh processes: three each for 100 batch, 100 individual,
and 1000 batch. Mode order rotates at 100; larger samples follow them. No tests,
compilation or profiling ran concurrently with the timed processes. Empty engine
creation is excluded; each phase includes its own job transactions/commits.

| Queue rows | Enqueue mode | Samples | Enqueue median ms | 100 duplicate requests ms | Claim+complete pairs | Pairs median ms |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 100 | Atomic batch | 3 | 68.685 | 114.872 | 100 | 4365.792 |
| 100 | Individual transactions | 3 | 253.658 | 114.898 | 100 | 4226.151 |
| 1000 | Atomic batch | 3 | 674.666 | 112.683 | 10 | 3937.680 |

Full ranges and RSS are in summary.json; raw samples in runs.json. Every sample
validates all final states/counts, attempts, dedup results and claim payload FIFO
order. Logical SHA matches across 100-row shapes. Physical hashes differ between
batch/individual shapes because transaction history differs; within each final
shape the exported images agree across these samples.

**Open performance gate:** ten claim+complete pairs with 1000 queued rows cost
about 3.94s, versus about 4.3s for 100 pairs with 100 rows. Processing cost grows with
retained queue depth; do not extrapolate a high-throughput or full 1000-job drain
claim. This milestone is suitable for functional evaluation, not acceptance of
large/latency-sensitive production queues. Retained terminal history also affects
cost. Query/catalog/index planning and image work remain material engine costs;
actual application indexes/triggers/storage can further change latency.

## Size and memory

- Empty engine image: 4096 bytes. Explicit jobs installation: 24576 bytes, an
  additional 20480 bytes. This initialization never runs unless jobs.open is used.
- 100 synthetic jobs: 32768 bytes;1000 jobs: 180224 bytes after processing the stated
  pairs. Three implicit indexes are included. No automatic vacuum/pruning.
- 100-row process RSS about 43–44MB;1000-row RSS 46.73–47.30MB, peak 53.86–53.99MB.
  Process readings are not attributable allocations or hard heap limits.
- Batch dedup temporarily loads retained non-NULL queue/key/ID tuples once per
  transaction. Memory grows with retained keyed rows. No hard queue-size cap.
- Production core source is unchanged from the preceding import performance
  milestone (fingerprinted in manifest.json). The package has no core hooks or
  ordinary-use SQL. No measured zero-overhead/unused-feature binary-size claim.

## Development probes and optimization

initial_probe.json and counter_probe.json retain exploratory earlier layouts,
with their source/binary fingerprints in matching manifests. They are not part
of the final medians or a controlled before/after gate. Earlier layouts combined
AUTOINCREMENT/mutable explicit indexes or one-row UPSERT lookup trees, causing
repeated image/index work. The final design uses transactional monotonic IDs,
immutable implicit indexes and transaction-local BINARY dedup keys, with plain
constraint-checked inserts. Full DDL/row constraints and lease fences remain.

profile_before/after.json are diagnostic JIT whole 20-job profiles; the latter is
an intermediate profile before the final batch-key cache. Top 60 global functions
were retained, then filtered to SQL code. These do not measure AOT phase timings
or prove final phase attribution. Intermediate source snapshots/binaries are not
retained for a historical source rebuild; final sources/binary are fingerprinted.

## Reproduce and verify

See [tool instructions](../../tool/jobs_benchmark/README.md). The runner overwrites
runs.json; archive previous evidence before rerunning. summary.json uses ordinary
medians/min/max, without discarding samples. manifest.json fingerprints measured production sources, driver/runner/profile
and the AOT binary. Two if branches subsequently gained braces for lint only;
post_measurement_lint.patch and the final source hash record that style delta.
Reverse that patch to reconstruct the timed queue source. Functional checks and
fatal-info analysis use the final source.

Final functional tests cover schema/counter validation, queue-scoped dedup,
BINARY/Unicode/NUL keys, concurrent handles on one connection, strict lease expiry,
retry/cancel/prune, atomic application enqueue and result+ack, stale capabilities,
bounded payload/errors, uncertain-commit poisoning, power-loss recovery at every
observed write/truncate/sync point under DELETE/PERSIST and two persistence models,
actual file close/reopen, plus pinned SQLite 3.53.1 differential states/counters
and exported-file integrity under UTF-8/UTF-16LE/UTF-16BE.

No actual browser storage/device, independent connection/process/isolate ownership,
Windows/macOS, remote CI, file-backed throughput, 100k/1m or OS background scheduling
acceptance. Native SQLite is test-only. Publication remains disabled.
