# sqlite_plus_reactive

Observe current SQL results as Dart streams, with shared query execution,
post-commit invalidation and row diffs. Pure Dart; no Flutter dependency, polling
loop, native SQLite or engine patch.

**Development implementation, experimental and unpublished (`publish_to: none`).**
Use the matching local workspace packages. ORM now depends on the local Reactive
and Changes packages; the changed ORM dependency set is not ready to publish to
pub.dev independently of them.

## ORM integration

Import `sqlite_plus_orm`; its normal typed query builder exposes:

```dart
final query = products.query
    .where(price.lt(20))
    .orderBy([price.asc(), id.asc()])
    .take(20);
final subscription = query.watch().listen((snapshot) {
  print(snapshot.items);
  print(snapshot.changes); // added, removed, updated, moved
});
final count = query.watchCount(); // Stream<BigInt>, honors query limit/offset
final first = query.watchFirst(); // Stream<Product?>
final any = query.watchAny();     // Stream<bool>

await context.saveChanges();
await context.flushReactive(); // optional deterministic catch-up for tests
await subscription.cancel();
```

The generated mappings work without regeneration. Queries must belong to a
`DbContext`/`DbSet`; an unowned standalone `TypedQuery` cannot watch. Filters,
ordering, parameters and pagination use the same SQL as normal reads. No separate
reactive query language. [Complete ORM example](../sqlite_plus_orm/example/reactive.dart).

Without Changes, only this context's successful ORM saves and migrations
invalidate results. This works with memory, ordinary file-owner connections and
the browser adapter. A watch does not create Changes tables or triggers.

Watch entities are independent read snapshots created by the mapping factory;
they are **not tracked**. Editing a snapshot does not save it. Unsaved tracked
entities are not overwritten by query refreshes, including remote refreshes.
Factories must create a fresh entity on each call. Reusing an already tracked
object is rejected.

## Observing Changes and Sync

Use the same underlying engine and Changes feed for ORM and Sync:

```dart
await db.execute('PRAGMA recursive_triggers=ON');
final changes = await SqlitePlusChanges.open(database: db);
final context = DbContext(
  MutableDatabaseConnection(db),
  model,
  changes: changes,
  reactiveDebounce: const Duration(milliseconds: 8),
  reactiveMaxRows: 10000,
);
await context.migrations.ensureCreated();
await context.enableReactive(); // optional eager setup; first watch also sets up
```

The adapter serializes reads/schema operations with Changes, and runs a whole
ORM save in one Changes transaction. Source changes and captured events commit
together; rollback emits no invalidation. Sync inbound writes on that feed become
ordinary watch invalidations. Network activity remains explicitly owned by Sync.

First watch (or `enableReactive`) tracks all ordinary mapped tables with their
mapped keys/columns. Existing source tracking must cover those keys/columns;
incompatible or subsequently removed capture fails explicitly. Tracking requires
existing source tables and the Changes prerequisites. It adds Changes' normal
metadata, triggers and per-write log overhead. It never backfills source rows.
Schema changes on tracked sources need explicit untrack/migrate/retrack; no
automatic destructive migration. See [Changes](../sqlite_plus_changes/README.md).

The Changes adapter requires a connection exposing the identical engine object.
The isolate/RPC connection returned by `DbSet.openDbFile` supports ordinary ORM
watches, but cannot bind a Changes handle from another engine object. For shared
Changes/Sync observation use a compatible direct engine connection.

## SQL without ORM

```dart
final reactive = ReactiveDatabase(changes);
final subscription = reactive.watch(
  'SELECT id,name,price FROM products WHERE price<? ORDER BY price,id',
  parameters: [20],
  dependencies: {'products': {'id', 'name', 'price'}},
  keyColumns: ['id'],
).listen((snapshot) => print(snapshot.items));
// Write through changes.transaction(...).
await reactive.flush();
await subscription.cancel();
await reactive.close();
```

Dependencies include projected, filtered, ordered and joined source columns.
A null column set means every column and requires complete source capture.
Insert/delete always invalidates a matching table. Incorrectly omitting a
SQL dependency can produce stale results: arbitrary SQL is not parsed to infer
all dependencies. Raw watch validates that declared ordinary sources stay tracked.
`'*'` is conservative invalidation on every observed event, not capture of
otherwise unobservable writes. Stable, unique, non-null keys must be projected;
composite keys and signed 64-bit keys are supported. [Runnable assertions](example/main.dart).

For custom sources, use `ReactiveRegistry` with an invalidation source or call
`invalidate`. Equivalent SQL/typed parameters/dependencies/key columns/shareScope
share one evaluation while subscribed. Use distinct shareScope identities when
identical SQL can refer to different databases/evaluators. Each subscriber gets
separate decoded objects and BLOB copies.

## Scheduling, costs and lifecycle

- Initial evaluation starts on listen. Identical results are suppressed; optional
  `query.refresh(force: true)` emits even when unchanged.
- Invalidations coalesce during evaluation and optional debounce. A relevant
  invalidation re-executes SQL; this is not incremental JOIN/aggregate maintenance.
  ORM count ignores changes to irrelevant fields; list watches project all mapped
  fields. Trigger/foreign-key effects and virtual sources may invalidate broadly.
- Row diffs identify changed rows and old/new positions. A row can be both updated
  and moved. Initial rows are additions. Revision numbers belong to the shared
  in-memory task; they are not durable transaction IDs or concurrency tokens.
- This is a **latest-state stream**, not an audit feed or every-commit delivery.
  Paused subscribers coalesce later snapshots to the latest state. Use durable
  Changes consumers when every transaction must be processed.
- Watchers use bounded stateless log reads and create no durable consumer, so they
  do not prevent pruning. Pruned/rotated/oversized log windows trigger a full
  current-result reload. No extra persistent reactive index or result cache.
- Default `maxRows`/`reactiveMaxRows` is 10000 per shared query. Over-limit results
  produce a recoverable stream error. This bounds retained rows, not query work,
  BLOB bytes, subscriber count or SQL's temporary result materialization. Prefer
  ordered pagination for large results. Each subscriber retains its last raw
  snapshot for diffs; memory grows with active queries/subscribers and row width.
- Errors arrive on the stream; a later invalidation/refresh can recover. Registered
  ORM scalars must be deterministic; SQL depending on wall clocks or external
  state needs explicit refresh and accurate dependencies.
- Cancel subscriptions and close the owner. Last cancellation discards cached
  results and detaches the source; context close closes its watches and discards
  in-flight reads. A paused stream must still be cancelled by its owner.

Raw writes outside the context/Changes API, other processes/connections, arbitrary
external changes to virtual tables and actual browser events are not automatically
observed. Virtual ORM queries use conservative invalidation for visible ORM saves
and Changes events. No promise of cross-process notifications, browser durability,
real device performance, hard byte caps or Flutter widget integration.

## Verification

Run from the repository root:

```sh
dart pub get
dart test packages/sqlite_plus_reactive/test
dart run packages/sqlite_plus_reactive/example/main.dart
dart run packages/sqlite_plus_orm/example/reactive.dart
```

Native differential tests need the pinned development CLI (`bash
tool/build_sqlite_reference.sh`). Production code never executes that CLI.
See [performance evidence](../../benchmark_results/reactive/README.md) and the
repository compatibility matrix for the tested scope.
