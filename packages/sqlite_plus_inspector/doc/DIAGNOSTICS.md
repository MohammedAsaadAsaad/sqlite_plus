# Explicit index advice and diagnostic replay (unreleased workspace)

These features extend Inspector without automatic engine hooks, index creation on
main or raw capture in ordinary records. They are explicit operations independent
of the collector enabled flag; disabling passive measurement does not cancel an
explicit advice/recording request. No new package is needed.

## Index advice

```dart
import 'package:sqlite_plus_inspector/sqlite_plus_inspector.dart';

final inspector = SqlInspector();
final report = await inspector.adviseIndex(
  database,
  'SELECT id,price FROM products WHERE supplier=? ORDER BY price',
  parameters: [supplierId],
);
final advice = report.advice;
if (advice != null) {
  print(advice.createSql);
  print(advice.before.indexName);
  print(advice.after.indexName);
  print(advice.selectedByPlanner);
  print(advice.beforeTimes);
  print(advice.afterTimes);
  print(advice.addedBytes);
}
```

Here database is the application's same-isolate MutableSqliteDatabase, not an
ORM domain variable or an RPC file owner. supplierId is an application value.
The [runnable example](../example/diagnostics.dart) creates its complete schema
and data before calling the advisor; no undeclared domain fields are required.

The advisor parses a narrow public-tokenizer grammar: single ordinary main table,
simple column projections or *, AND comparisons against literal/bound values,
and column ORDER BY. It proposes equality columns, the first range column, then
remaining order columns. It measures one candidate, not all possible indexes.
Joins, CTEs, OR, expressions/functions, limits/offsets and non-BINARY candidate
collations return an unsupported reason instead of a guessed recommendation.
Malformed SQL/query errors may still throw. Qualified main table/aliases are
supported within that grammar; unusual SQL outside it remains unsupported.

It reads actual metadata, skips equivalent ordinary index prefixes and PK point
access, and quotes identifiers in candidate CREATE INDEX. Partial/expression
indexes are not treated as proven redundant alternatives. A name collision skips
advice. No query or index experiment runs on the original database.

All experiments use a disposable exported main-image copy: plan before/after,
several query timings, candidate build duration and file-size change. Result
multisets/column labels must agree. Ordering of ties is not treated as data change.
SQL parameter values are not retained in the advice object. There is no automatic
application, ANALYZE, production SQL replay or workload-wide recommendation.

Timing samples run before then after construction; caches and a shared host can
bias them. selectedByPlanner is evidence about the access path, not proof of a
speedup. Build cost and added bytes are measured; writeCostMeasured is false.
Ongoing INSERT/UPDATE overhead, other queries and real storage must be evaluated
before applying an index yourself.

IndexAdviceOptions defaults: 3 samples (1..7), 32 MiB source/candidate image,
10,000 table rows, 16,384 SQL characters (up to 65,536), 1,000 parameters and
at most 8 candidate columns. Inputs/results are buffered; these are not hard heap
or query-runtime limits. Finish caller transactions and exclusively loan the
source during snapshotting. TEMP/ATTACH/custom registries are not cloned.

## Recording is a separate, explicit opt-in

```dart
import 'package:sqlite_plus_inspector/sqlite_plus_inspector_replay.dart';

final recorder = await SqlReplayRecorder.start(database, inspector: inspector);
await recorder.execute('BEGIN');
await recorder.execute('UPDATE products SET price=? WHERE id=?', [550, productId]);
await recorder.execute('COMMIT');
final artifact = recorder.finish();
final bytes = artifact.toBytes();

final report = await SqlReplayArtifact.fromBytes(bytes).replay();
print(report.matches);
print(report.firstMismatch);
print(report.finalStateMatches);
print(report.physicalImageMatches);
```

This library is not exported by the default entry point. Ordinary Inspector logs
remain redacted and cannot be replayed. The explicit recorder retains raw SQL,
bindings, initial AND expected-final database images; artifacts are sensitive
plaintext. No result values, error messages/stacks, automatic file write or
network upload is added. Checksums detect accidental corruption, not authenticity.

Only serial calls through the recorder are captured. Loan the engine exclusively;
external calls/custom registries are not captured. Source operations still run on
the application connection because that is the deliberate recording session.
Replay itself ALWAYS constructs a new in-memory engine; no existing target can
be passed. Artifacts have bounded versioned metadata and typed bindings, including
64-bit integers/BLOB copies. Imported SQL/limits/checksum are validated.

Supported capture: SELECT/WITH, INSERT/UPDATE/DELETE, and explicit transactions/
savepoints. Host/schema SQL (ATTACH/DETACH/PRAGMA/VACUUM/DDL etc.) and oversized
capture make isComplete false while source operations still delegate with their
original result/error. finish rejects incomplete sessions. Default capture limits:
8 MiB per image, 32 MiB artifact, 1000 statements (up to 10,000), 65,536 SQL chars,
1000 parameters. Final-state proof defaults to 10,000 total table rows and can be
raised with maxStateRows. Completion does not promise deterministic SQL or that
all replay resource budgets will pass.

start captures foreign_keys, recursive_triggers and doubleQuotedStrings settings.
Other connection state (including prior changes/last_insert_rowid counters), TEMP,
ATTACH, host functions/registries, external effects and nondeterministic time/random
functions are not promised reproducible. Raw database/schema changes during
capture violate ownership; changed final logical state can reveal such bypasses.

Replay compares each query/returning result and affected count, or exception type,
then logical final state: exact schema SQL, rows, accessible hidden rowids and
persistent application_id/user_version/encoding. Ordinary tables are required
for the final-state proof; virtual/generated tables are unsupported there.
Generated state/proof errors are explicit; there is no automatic host callback.
Queries' recorded row order is preserved in proof; nondeterministic unordered
result order may conservatively report divergence.

Page packing and header counters are not logical data. physicalImageMatches is
reported separately: normal replay from an image can pack pages differently while
all SQL outcomes and logical data agree. A 1000-row regression test covers this.
The final images are retained to validate logical state independently of physical
layout, which increases artifact size. On first outcome divergence replay stops
and reports its zero-based step index; missing final-state match also makes
matches false. Failed source SQL is rethrown unchanged during recording.

## Running and release status

```sh
dart run packages/sqlite_plus_inspector/example/diagnostics.dart
```

The sample exercises index advice and replay with assertions on VM/compiled JS.
AOT phase evidence and ordinary-write comparison:
[workflows benchmark](../../../benchmark_results/workflows/README.md).
These additions are workspace development APIs, not a public-version claim.
