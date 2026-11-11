# sqlite_plus_jobs — durable embedded jobs (2026-11-08)

Approved scope: implement the recommended jobs package, independently of ORM.
Pure Dart, public sqlite_plus API only. Existing uncommitted work is preserved.
No core hooks, automatic runtime polling, schema migration or publication.

| Step | Status | Acceptance |
| --- | --- | --- |
| 1. Contract/design | Complete | Explicit connection ownership, lease fencing, at-least-once, clock/durability limits |
| 2. Storage/enqueue/dedup | Complete | Transactional install, format verification, bounded JSON, queue-scoped dedup |
| 3. Claim/recovery/retry | Complete | Priority/delay, bounded attempts, renew/complete/fail token+expiry checks, cancel/retry/prune |
| 4. Worker/example | Complete | Explicit runOne with registered types; handler outside transactions, manual renewal; atomic app write+enqueue and result+ack example |
| 5. Verification | Complete | Competing handles, reopen/lease expiry, rollback, stale workers, constraints, schema corruption, fault injection, pinned native SQL |
| 6. Evidence/docs/CI | Complete locally | Reproducible AOT samples, file/RSS size, VM/JS example, format/analyze, integration regression, README/status |

## Contract

- Own reserved `_spj_` ordinary tables and indexes; all operations opt-in. Opening
  validates exact schema/version; unknown/partial schemas fail without repair.
- Multiple handles on the SAME MutableSqliteDatabase share a serial queue.
  The caller loans the connection exclusively during calls. Raw ORM/Changes/Sync
  calls MUST NOT interleave. No independent-connection/process/isolate guarantee.
- Each state change is one engine transaction. Application DML and enqueue can
  share jobs.transaction; no caller-owned transactions/reentrant jobs calls.
- queued -> running -> succeeded/queued/failed, with cancelled terminal state.
  Attempts count claims, including expired/crashed attempts. Expired final attempts
  become failed during claim. Terminal rows and dedup keys remain until prune.
- SQL conditional writes fence a random lease token plus running state and strict
  lease_until > now. At equality the lease is expired. Renew cannot resurrect.
- Payload <=64KiB UTF-8 JSON, names<=128 bytes, dedup<=256 bytes, error<=4096 bytes,
  attempts1..100, bounded durations and paginated listing/pruning. No hard DB/heap cap.
- Injected UTC wall clock for deterministic tests. Clock jumps can delay work or
  expire leases; tokens do not guarantee exactly-once external effects. Handlers
  need external idempotency. Do not replay the same DB on independent devices as
  a distributed queue. Native/browser durability follows the selected backend.
- Worker runOne is explicit, runs registered handlers outside DB transactions,
  no OS background service/timer or automatic heartbeat. App controls scheduling.
- Commit/rollback uncertainty poisons jobs use of that connection; reopen a fresh
  recovered connection. Never silently replay an uncertain external operation.

## Deferred

Cross-process owner/RPC adapters, ORM/Changes transaction-driver integrations,
automatic daemon scheduling, cron/DAGs, distributed exactly-once, streaming payloads,
result storage, schema upgrades, automatic retention/vacuum, benchmark claims at
100k/1m or on actual devices/browser storage. No unused-feature engine changes.


## Delivery evidence and open gates

- Implemented opt-in package, workspace membership, full README/changelog/license,
  assertion example and dedicated CI definition. No core runtime modifications.
- Final jobs suite: 52 cases, including 28 recovery combinations and scoped business
  enqueue/result+ack atomicity. Existing ORM/Changes/Sync/Reactive/Branch/Inspector
  regression: 459 existing cases pass (combined run 510 included 51 then-current jobs
  cases). Final batch-key and counter/Unicode boundaries are covered separately.
- Pinned SQLite 3.53.1, three text encodings; file reopen; VM+compiled JS/Node example.
- Fatal-info analysis/format checks for package and benchmark pass. CI definitions
  are present as local changes only; remote execution/publication was not run.
- Nine fresh AOT samples: 100/1000 batch and 100 individual. Detailed timings, size,
  memory, source fingerprints and style-only post-timing delta: benchmark_results/jobs.

| Remaining gate | Status |
| --- | --- |
| Measured processing bottleneck | Addressed: ~4.02s -> 34ms for ten jobs at depth 1000 in memory; full 1000 drain ~3.14s. General depth/file production acceptance remains open |
| Independent connection/process/isolate coordination | Deferred; same-object connection only |
| ORM/Changes transaction-driver adapters and OS scheduling | Deferred; explicitly unsupported in this milestone |
| Actual browsers/devices, Windows/macOS and file throughput | Unverified |
| Publication/push/main merge | Not performed |

Initial schema was revised during unreleased development. Existing unknown/earlier
schemas are rejected, never silently migrated. IDs are allocated with a persistent
counter; three implicit immutable indexes avoid per-state index key updates.
Batch dedup caches exact valid-Unicode BINARY keys within one transaction; memory
is proportional to retained keyed jobs, released at transaction end.


The subsequent [performance follow-up](JOBS_PERFORMANCE.md) modifies generic core
write/read-cache paths and Jobs scheduling SQL without changing this schema/API.
See [final measured evidence](../../benchmark_results/jobs_performance/README.md);
first-milestone measurements above remain historical.
