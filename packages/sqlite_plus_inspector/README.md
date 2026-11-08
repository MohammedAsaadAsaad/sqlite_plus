# sqlite_plus_inspector

Optional SQL diagnostics for the Pure Dart engine and ORM: statement timing,
returned/affected row counts, failures, repeated query templates, named operation
scopes and explicit query planning. Reports stay in application memory until you
choose to export them. No UI, server, telemetry, database tables, polling loop,
engine execution hook or automatic index creation.

**Experimental, unpublished workspace package (`publish_to: none`).** Use the
matching local workspace packages, including the unpublished ORM dependencies.
This addition does not publish a new version of the engine or ORM.

## Inspect engine queries

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';

final engine = await openInMemory();
final inspector = SqlInspector(
  options: InspectorOptions(
    slowThreshold: const Duration(milliseconds: 50),
    repeatedReadThreshold: 10,
    maxRecords: 500,
    maxGroups: 100,
  ),
);
final db = inspector.database(engine, label: 'catalog');

await inspector.scope('load-products', () async {
  await db.query('SELECT id,name FROM products WHERE category_id=?', [categoryId]);
});
final report = inspector.snapshot();
for (final record in report.records.where((r) => r.slow)) {
  print('${record.duration}: ${record.sql}');
}
for (final scope in report.scopes) {
  print('${scope.name}: ${scope.queryCount} reads');
  print(scope.repeatedReads); // hints, not proof of N+1
}
final json = report.toJsonString(); // plain JSON, no SQL result values
```

`db.query` returns the original `QueryResult`; `db.execute` returns the original
`MutationResult`. `db.page(...)` uses the integrated core paginator through the
same observed query path. Raw transaction commands remain explicit. Calls made
directly on `engine` are not intercepted.

`inspector.readOnly(reader)` wraps a `SqliteDatabase`. `InspectedConnection` also
accepts explicit query/execute/close/state callbacks for custom connections.
Closing the wrapper invokes its supplied close callback. Closing the inspector
stops recording but does not close any database or cancel application queries.

[Runnable engine assertions](example/main.dart).

## ORM integration

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_orm.dart';

final inspector = SqlInspector();
final connection = inspector.ormConnection(
  MutableDatabaseConnection(engine),
  label: 'orm',
);
final context = DbContext(connection, model);

await inspector.scope('load-orders', () async {
  await context.set(orderType).query.toList();
  // Other typed reads, relation loads and saves belong to the same scope.
});
```

Typed queries, pagination, save/migration SQL and Reactive reevaluations passing
through this connection are observed. Ownership claims, engine/scalar capability,
transaction-driver choice and exclusive scopes are forwarded. Results and
tracked objects keep their normal ORM semantics; the inspector does not refresh,
clone or modify them. Query failures retain their original error/stack.

For Changes/Sync-backed contexts, construct in this order:

```dart
final connection = inspector.ormConnection(
  MutableDatabaseConnection(engine),
  changes: changes,
);
final context = DbContext(connection, model);
```

This wraps Changes **inside** inspection, so ORM-issued captured statements are
observable. Do not instead pass `changes:` to the outer `DbContext`: that places
its writer outside the observing adapter and captured writes bypass measurement.
Existing Changes/Sync setup and recursive-trigger requirements still apply.
Internal Changes metadata, triggers, transaction-driver SQL, Sync or Search work
that uses the original engine directly is not intercepted. A surrounding scope
can still measure its operation wall time, but cannot invent per-SQL records.
This is a connection wrapper, not an engine-wide profiler.

[Runnable ORM assertions](example/orm.dart).

## File owner and browser

Import `sqlite_plus_inspector_io.dart` only on native platforms:

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_io.dart';

final owner = await openDatabase('catalog.db');
final db = inspector.file(owner); // query/execute accept raw SQL
// Or use this owner exclusively for an inspected ORM context:
final context = DbContext(inspector.ormFile(owner), model);
```

`file(owner)` closes the owner when its wrapper closes. `client(client)` closes
only that logical client. `ormFile(owner)` closes the owner with its context and
rejects a second inspected ORM claim on that same owner. Do not share a claimed
owner with unrelated raw writers. `DbSet.openDbFile` creates/claims its own
connection internally; use the explicit owner/context construction above when
inspection is needed. Wrapping an already-owned context is not supported.

A `BrowserDatabaseConnection` can be passed to `ormConnection` in the same way
as a mutable connection. The collector is browser-safe; actual browser storage
capabilities remain the adapter's contract. Tests use a simulated byte store.

## What the report means

- `records`: bounded completion-order statement history, connection identity,
  scope ID, operation (`query` or `execute` API), duration, slow/success flags,
  row/affected counts when known and error **type**, not its potentially sensitive
  message. A SQL statement that later rolls back can still have succeeded here;
  this is timing information, not a commit/audit feed.
- `groups`: LRU-bounded aggregates keyed by connection, operation and normalized
  template fingerprint. Comments are removed, SQL string/number/BLOB literals
  and parameter tokens become `?`, ASCII identifier case is normalized and
  non-ASCII identifier distinctions are preserved. Display text is truncated;
  its fingerprint uses the complete analyzed template. This grouping is a
  diagnostic heuristic, not a prepared-statement cache or semantic SQL equivalence.
- `scopes`: bounded completed named operations with inclusive nested counts,
  wall time and sum of observed statement durations. Concurrent scopes stay
  isolated using Dart zones. Sum of statement time can exceed wall time when
  queries overlap; it is not an ORM CPU/overhead measurement.
- `repeatedReads`: analyzed query templates occurring at least
  `repeatedReadThreshold` times in that scope. Polling, retries and legitimate
  loops can produce the same pattern. No proof of different bind values or an
  actual N+1 relationship is claimed. No automatic fixes are made.

Await all child work that belongs to an operation. Work finishing after a scope
ends is not added retroactively; queries from a different callback/zone (such as
background reevaluations) may appear only in global history. Failed scopes are
retained with `success: false`, even when the failure was not a SQL error.

Times wrap the awaited delegate call and include its queue wait, transport and
engine work. Tokenization, parameter preview construction and bookkeeping are
outside the per-statement timer, but inside caller-observed overhead and scope
wall time. Async operations are not reduced to CPU time. JS clock precision and
host load can affect short-query readings.

## Privacy and budgets

Default `captureParameters: false` retains type/size summaries only. It never
stores result rows, SQL error messages or stack traces. Literal tokens and SQL
comments are omitted from display/fingerprints. Quoted identifiers, scope names
and connection labels remain visible; double-quoted-string fallback cannot be
distinguished from an identifier by this lexical formatter. Do not put secrets
in those names. SQL display templates are not executable copies of the original
query and are not a substitute for authorization filters.

With `captureParameters: true`, supported scalar previews are retained up to
`maxParameters` (32) and `maxValueChars` (128 input characters). BLOBs retain
length only even then; unsupported objects are not stringified. JSON escaping
can expand preview bytes. The collector never prints or transmits reports itself.

Defaults are 500 records, 100 groups per collector/active scope, 50 completed
scopes, 100 active scopes, depth 16, 100 in-flight measurements, 4096 SQL display
characters and 65536 input characters for analysis. Group/record/scope limits
may be zero to disable that history while keeping totals. Overlong/malformed SQL
is unanalysed and cannot trigger repeated-read hints; database execution is still
delegated. Data under the display cutoff does not control fingerprint identity.

Evictions/skips are reported as `droppedRecords`, `droppedGroups`, `droppedScopes`
and `skippedMeasurements`. At the in-flight/depth/active-scope budget the action
still runs, with reduced observation. Group-drop counts include evictions or
unretained observations, not a count of globally distinct queries. Aggregates
for a retained group can outlive individual records. Reports are not complete
execution histories; check these counters before interpreting counts.

The budgets bound retained metadata and concurrent measurement frames, not
engine rows/sorts, raw SQL/argument memory already owned by callers, UTF-8 bytes,
caller-held snapshots or explicit plan snapshots. `clear()` starts a new history
epoch and discards old in-flight records without cancelling those queries.
Identity/sequence IDs stay monotonic; existing active work still consumes its
in-flight budget until it finishes. `enabled = false` bypasses observation;
`close()` makes that permanent and preserves the last report until `clear()`.

## Explicit plans

```dart
final plan = await db.explain(
  'SELECT id,name FROM products WHERE category_id=?',
  [categoryId],
);
print(plan.toJson()); // engine access path, index, covering information
```

Never automatic on slow queries. The original SELECT is not executed again.
For mutable engines this explicitly exports a main-image snapshot and opens a
read-only planner with the same function registry; it can be expensive for a
large database. Read-only adapters use their existing planner. These are the
engine's supported planning metadata, not full VM bytecode or automatic index
recommendations. Unsupported SQL shapes fail normally; only SELECT/WITH input
is accepted and planning does not write source data.

ORM `.explain` serializes with its Changes delegate when configured, but call it
while the context is idle: it is not a new context-queue operation. IO/RPC file
adapters cannot expose the main-image planner and report UnsupportedError.
No automatic argument literalization or execution of DML as a diagnostic.
Plan work is not included as a recorded application statement.

## Performance and verification

Applications that do not wrap a connection have no new engine/ORM hook. A disabled
wrapper returns the original delegate future without tokenizing or timing it;
it still has wrapper/closure/branch costs. Enabled inspection deliberately adds
CPU and retained metadata. See [AOT evidence](../../benchmark_results/inspector/README.md)
for direct/disabled/enabled measurements; no universal zero-overhead claim.

From the workspace root:

```sh
dart pub get
dart analyze --fatal-infos packages/sqlite_plus_inspector
dart test packages/sqlite_plus_inspector/test
dart run packages/sqlite_plus_inspector/example/main.dart
dart run packages/sqlite_plus_inspector/example/orm.dart
```

Native plan comparison needs the pinned development SQLite CLI on Linux
(`bash tool/build_sqlite_reference.sh`). It is never a production dependency.
No real browser/device, DevTools extension, graphical inspector, network dashboard,
automatic engine-wide tracing, release publication or production certification
is provided by this milestone.
