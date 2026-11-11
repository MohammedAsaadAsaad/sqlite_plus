# sqlite_plus_jobs

Opt-in embedded jobs for the pure Dart sqlite_plus engine. Persist tasks, claim
with leases, retry failures and recover expired attempts. No server, core hooks,
ORM dependency, automatic polling or OS background service. Experimental,
unpublished workspace package (`publish_to: none`).

## Start with an application record and its job

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_jobs/sqlite_plus_jobs.dart';

final db = await openInMemory(); // Demo only; memory does not survive process exit.
await db.execute(
  'CREATE TABLE uploads(id INTEGER PRIMARY KEY,path TEXT NOT NULL,state TEXT NOT NULL)');
final jobs = await SqlitePlusJobs.open(database: db);

final added = await jobs.transaction((tx) async {
  await tx.execute("INSERT INTO uploads VALUES(1,?,'pending')", ['photo.jpg']);
  return tx.enqueue(
    'upload',
    payload: {'uploadId': 1, 'path': 'photo.jpg'},
    deduplicationKey: 'upload:1',
    maxAttempts: 5,
    retryDelay: Duration(seconds: 30),
  );
});

final worker = JobWorker(jobs, {
  'upload': (lease) async {
    final payload = lease.job.payload as Map;
    // await upload(payload['path'], idempotencyKey: 'upload:${payload['uploadId']}');
    // Network work runs outside the database transaction.
    await jobs.transaction((tx) => tx.execute(
      "UPDATE uploads SET state='uploaded' WHERE id=?", [payload['uploadId']]));
  },
});
final outcome = await worker.runOne();
final snapshot = await jobs.get(added.id);
// When done with ALL users of this application-owned connection:
await db.close();
```

The `uploads` table, columns and job type are application declarations in this
example. The package creates its own `_spj_` tables/indexes only on explicit open.
The complete [assertion example](example/main.dart) runs on Dart VM and compiled
JS/Node. Payload is JSON, frozen when enqueue is called; each `job.payload`
access decodes a fresh value. IDs are BigInt, scoped to the database.

## Ownership and durability

**Loan the connection exclusively during package calls.** Multiple jobs handles
sharing the SAME `MutableSqliteDatabase` object serialize through one queue.
Independent connections, isolates and processes are not coordinated. The package
does not acquire an ORM/Changes/Sync connection lease and does not intercept raw
engine calls. Route application DML through `jobs.transaction` when it can race
with queue calls; do not interleave raw SQL, ORM transactions or other package
operations. Caller-owned transactions and reentrant jobs calls are rejected.
`JobsTransaction` expires at callback return. Scoped operations are serialized,
drained before commit, and any failed scoped operation causes rollback even if
its Future was caught or not awaited. Always await application operations.

Each mutation uses an engine transaction. Data survives only as durably as its
storage backend. `openInMemory` and `openFileImage` are not durable queue stores.
For a journal-backed `MutableSqliteDatabase`, use the engine's normal storage
provisioning and recovery contract, for example with already-provisioned files:

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

// These files must ALREADY exist, with durable directory entries. Their creation
// and directory durability are the application's responsibility. Exclude other
// owners/processes/isolates for the database and its journal.
final data = await DurableFileStorageBackend.openExclusive(
  databasePath, directoryEntryIsDurable: true);
final journal = await DurableFileStorageBackend.openExisting(
  journalPath, directoryEntryIsDurable: true);
final db = await MutableSqliteDatabase.fromJournalPager(
  await RollbackJournalPager.open(data, journal));
final jobs = await SqlitePlusJobs.open(database: db);
```

Close/dispose backends on failed setup in application code. No file provisioning,
connection ownership service or durability strengthening is provided here.
On commit/rollback uncertainty, jobs use of that connection is poisoned. Close
and reopen a fresh recovered connection; do not blindly replay external effects.

## Claim, renew, complete and retry

```dart
final lease = await jobs.claim(
  queue: 'default',
  types: ['upload'],
  leaseDuration: Duration(seconds: 30),
);
if (lease != null) {
  final alive = await jobs.renew(lease, leaseDuration: Duration(seconds: 30));
  if (alive) {
    // Perform bounded work, then:
    await jobs.complete(lease); // false if expired/replaced/cancelled/completed.
    // On failure instead:
    // await jobs.fail(lease, error: 'Temporary network failure',
    //   retryAfter: Duration(minutes: 1));
  }
}
```

Selection uses priority DESC, then creation time/id ASC. Ready time is inclusive;
lease expiry is strict: at `lease_until == now` the lease is expired. Each claim
increments attempts, including crash recovery. A random token fences stale
workers; renew cannot resurrect an expired lease. The lease/job object is a
snapshot and its leaseUntil does not change after renewal.

`fail` schedules the configured fixed retry delay (or explicit retryAfter);
when attempts reach maxAttempts it marks failed. Claim marks expired final
attempts failed. There is no automatic global cleanup thread: another claim in
the queue triggers expiry recovery. No guarantee of successful execution or
unlimited retries; bounded attempt budgets can be exhausted by crashes.

Delivery follows at-least-once processing semantics. A worker can perform an
external effect and crash before acknowledgement, causing another attempt.
Use stable external idempotency keys. Cancel or loss of lease cannot revoke an
already-running network request. Wall-clock jumps can delay or expire work;
provide `clock` for tests, and use consistent UTC clocks in production. Do not
run copied/restored images simultaneously as a distributed queue.

## Atomically persist a database result and acknowledge

For database effects, manually claim and use scoped completion:

```dart
final lease = await jobs.claim(types: ['compute']);
if (lease != null) {
  // Calculate outside the transaction.
  await jobs.transaction((tx) async {
    await tx.execute('UPDATE reports SET ready=1 WHERE id=?', [reportId]);
    await tx.complete(lease);
  });
}
```

`tx.complete` throws `JobLeaseLostException` if the lease is no longer valid,
rolling back application updates too. Use this manual path independently of
`JobWorker`, which acknowledges after its handler returns. Ordinary `complete`
returns a boolean instead. External effects cannot join this database transaction.

## Worker and administration

`JobWorker.runOne()` executes one registered type, outside a DB transaction, and
returns idle/completed/retried/failed/lostLease. Unregistered types stay queued.
Handler errors become bounded stored messages, not stored stack traces. Control
SQL errors propagate. The application controls scheduling, concurrency and
shutdown; no polling, auto-heartbeat, timeout or background wakeup is installed.
Long-running handlers must renew manually, and stop cooperatively on lease loss.

- `get(id)`, `list(queue:, state:, afterId:, limit:)`: snapshots, ID-keyset paging.
- `cancel(id)`: queued/running -> cancelled; rejects later acknowledgement.
- `retry(id)`: failed/cancelled -> queued with a fresh attempt budget.
- `prune(finishedBefore:, queue:, limit:)`: explicit terminal deletion, strict
  cutoff, releases dedup keys. Does not VACUUM or guarantee physical file shrink.

Deduplication is `(queue, deduplicationKey)` across queued/running/terminal rows.
The first payload wins; a repeated key returns the original ID with created=false
without changing type/payload/schedule. Omit the key to allow independent jobs.
Retention therefore affects deduplication semantics. Pruning/retry are explicit.

## Schema, bounds and integration

Reserved ordinary tables: `_spj_meta`, `_spj_jobs`, plus three automatic indexes
owned by `_spj_jobs`. These index deduplication, immutable priority/creation/ID,
and queue/type/ID. The latter composite UNIQUE keys include the already-unique
ID, so they add indexing without restricting which jobs can coexist. IDs come
from a transactional monotonic metadata counter, saved once per transaction;
pruning does not reuse them. Pruning leaves gaps; IDs should not be assumed contiguous. Batch enqueue snapshots
existing dedup keys once per transaction, using exact BINARY string equality. This
adds temporary memory proportional to retained keyed jobs. Names/keys must be
valid Unicode; unpaired surrogate strings are rejected.
Open verifies the exact known DDL, automatic indexes, monotonic counter and format 1, rejecting partial/altered/unknown
reserved objects without repair. Do not directly modify reserved data/schema,
register them for sync, or merge/copy live queue state between devices. No schema
upgrades, automatic Changes/Reactive integration or ORM transaction adapter are
claimed. This package uses only public engine SQL and adds no engine hooks.

Payload: 64KiB UTF-8 encoded JSON including quotes. Queue/type: 1..128 bytes;
dedup key: 1..256 bytes; error: 1..4096 bytes. Priority ±1,000,000; attempts 1..100;
listing/pruning 1..1000; type filters 1..32. Lease 1ms..365days, retry 0..365days,
millisecond precision; timestamps from Unix epoch through DateTime's upper bound.
The package adds no separate history/queue-size cap; engine/backend limits still apply. Cache/heap/file costs depend on
data and engine transactions. Payload and errors are ordinary plaintext database
content unless the chosen storage protects them; avoid embedding credentials.

## Verification and performance

[Plan/status](../../docs/plans/JOBS.md) · [AOT measurements and limits](../../benchmark_results/jobs/README.md).

The [processing performance follow-up](../../benchmark_results/jobs_performance/README.md)
reduces the original 1000-row/10-job in-memory workload from about 4.02s to 34ms;
a full 1000-job drain takes about 3.14s. File-backed processing improves from 5.17s
to 1.75s for ten jobs on this host's temporary filesystem. These timings do not
establish physical-device throughput or general production readiness.

Claim reads scheduling metadata only and chooses priority/creation/ID order
inside the same exclusive transaction. Metadata is discarded after the call;
there is no separate persistent scheduler cache. Selection still scales with
retained queue rows. Pruning history also releases dedup keys, so choose retention
according to the application's idempotency window.

Tests cover dedup, same-connection contention, FIFO/priority/delay, stale tokens,
retry bounds, cancellation/pruning, atomic application enqueue/result+ack,
scoped lifetime, reopen, reserved-schema corruption, journal fault recovery,
pinned native SQLite transitions and cross-open integrity in three encodings.

No production-publication readiness, independent-process coordination, actual
browser/device performance, OS background execution, or million-row scalability
claim. Production runtime remains pure Dart; native SQLite is a development oracle.

The measured workspace behavior requires the accompanying unreleased core fixes.
Release those fixes and raise the core dependency floor before publishing Jobs
independently; older published core builds are not covered by these results.
