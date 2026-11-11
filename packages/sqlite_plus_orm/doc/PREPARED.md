# Prepared queries and updates

Preparation retains reusable SQL syntax between calls. It saves tokenization and
eligible expression parsing; it does not cache rows, parameter values or a
physical plan. Access planning still considers current bindings and indexes.
Use it for repeated command shapes; already optimized simple engine operations
may benefit little or run faster through their existing path.

## Complete example

See [example/prepared.dart](../example/prepared.dart), from table creation and
insertion to typed reads and updates. `id`, `name`, `price` and `mapping` are
explicitly declared `Column` and `EntityType` descriptors in that file. Generated
models supply descriptors with the same role; none are invented SQL identifiers.

With `products = context.set(mapping)` and those descriptors:

```dart
final minimum = QueryParameter<int>('minimum');
final read = await products.query
    .where(price.gteParameter(minimum))
    .asNoTracking()
    .prepare();
try {
  final expensive = await read.toList(parameters: {minimum: 20});
  final affordable = await read.toList(parameters: {minimum: 5});
} finally {
  await read.close();
}

final key = QueryParameter<BigInt>('id');
final amount = QueryParameter<int>('price');
final update = await products.query
    .where(id.eqParameter(key))
    .prepareUpdate({price: amount}, returning: [id, price]);
try {
  final result = await update.execute(
    parameters: {key: BigInt.one, amount: 25},
  );
} finally {
  await update.close();
}
```

Reuse the **parameter object** as the binding-map key. Names are diagnostic;
two objects with the same name are different parameters. All declared bindings
are required, extra keys are rejected, and Dart types and column codecs validate
values. BLOB values and captured constants are copied. `eqParameter` generates
`=`: passing NULL does not match NULL. Use `isParameter` for null-safe `IS`.
Comparison helpers include `notEqParameter`, `gtParameter`, `gteParameter`,
`ltParameter`, `lteParameter` and `isNotParameter`.

Prepared queries retain tracking/no-tracking semantics. Tracked objects keep
normal identity-map behavior; use `asNoTracking()` for fresh untracked objects.
Updates retain transactions, dirty-state rejection, managed version increments,
trigger/FK effects, refresh and Reactive notifications. Key/generated/version
assignment restrictions remain. Prepared updates do not support ordering,
pagination or ranked/spatial query ordering.

## Optional cache for existing reads

```dart
final context = DbContext(connection, model, preparedQueryCacheSize: 16);
// Same SQL shape; different values. Eligible syntax is reused automatically.
await context.set(mapping).query.where(price.gte(10)).toList();
await context.set(mapping).query.where(price.gte(20)).toList();
await context.clearPreparedQueries();
```

Default capacity is **0**, so existing reads retain their execution path.
Capacity is 0..128; eviction closes resources. Cache keys are generated SQL,
not bound values. This cache stores command syntax, never query results.
`preparedQueryCacheEntries` exposes the current size. Explicit handles and
cached commands are disposed when the owning context closes.

## Adapters and supported syntax

`usesEnginePreparation` states whether the engine actually reuses syntax.
Direct mutable/browser adapters opt in. Custom/RPC/file-owner/Inspector adapters
retain their original query/execute pipeline through a fallback unless they
explicitly implement the capability. Exposing `engineDatabase` alone does not
opt in. Custom subclasses may override `prepareCommand`.

Changes-backed writes deliberately use that adapter's existing captured execute
path (`usesEnginePreparation == false`); reads can reuse engine syntax inside
its exclusive scope. Unsupported SELECT shapes (functions, joins, aggregates,
CTEs, qualified columns, TRUE/FALSE fallback names, derived/view/generated/virtual sources) transparently fall back through
the adapter. Schema changes can invalidate prepared syntax; the automatic cache
falls back if a formerly supported shape becomes unsupported. Explicit engine
handles report unsupported preparation instead.

No database-file change, migration, permanent index or persistent cache is added.
See [core preparation](../../sqlite_plus/doc/PREPARED.md) and
[measured results](../../../benchmark_results/prepared/README.md).
