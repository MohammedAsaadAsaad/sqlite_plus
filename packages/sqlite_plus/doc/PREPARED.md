# Reusable prepared statements

```dart
final statement = await db.prepare(
  'SELECT id,price FROM products WHERE price>=? ORDER BY id LIMIT ?',
);
try {
  final first = await statement.query([10, 20]);
  final second = await statement.query([25, 20]);
} finally {
  await statement.close();
}

final update = await db.prepare('UPDATE products SET price=? WHERE id=?');
try {
  final result = await update.execute([30, 1]);
} finally {
  await update.close();
}
```

`db` is a `MutableSqliteDatabase`. Preparation validates syntax/metadata without
executing the statement, running user callbacks or modifying stored rows. Use
`query` for SELECT and `execute` for INSERT/REPLACE/UPDATE/DELETE. Supply exactly
`parameterCount` bindings, including unused slots in numbered parameters. Named
parameters reuse slots with existing engine rules. Each invocation copies BLOB
bindings before asynchronous work begins.

## What is retained

Handles retain tokens and safe immutable expression syntax. Eligible ordinary
SELECTs retain their parsed statement. Positional DML reuses safe expression
subtrees; its statement control/constraint/trigger execution still runs. Named
DML retains tokens but reparses expressions. Function/subquery/window expression
objects are never shared. This is syntax reuse, not SQLite's bytecode VM.

Rows, bound values and physical access plans are not cached. Planning uses fresh
bindings and catalog/data. Existing indexes and hot-operation optimizations can
make ordinary execution as fast or faster for simple workloads. Preparation
primarily targets repeated parse-heavy shapes; see the actual
[measurements](../../../benchmark_results/prepared/README.md).

Schema/search-scope changes and rollback invalidate syntax, rebuilt on next use.
Handles store no physical page roots. Data writes do not invalidate reusable
syntax. Diagnostic counters (`preparationCount`, `selectParseCount`,
`expressionParseCount`, `expressionReuseCount`) let tests confirm saved work.

## Supported boundary and lifecycle

SELECT preparation supports simple ordinary single-source SELECTs with pure
expressions, filtering/order/limit. Joins, table aliases, compound queries,
CTEs, aggregates/functions, subqueries, qualified column expressions,
TRUE/FALSE fallback-name expressions, views, generated and virtual sources
are unsupported. DML uses ordinary unqualified targets and the existing
compile-only validation subset; cross-schema statements and INDEXED BY targets
are unsupported. Routing to one schema, including temp, follows current catalog
rules. Unsupported preparation throws `UnsupportedError`; ordinary query and
execute remain available with their existing SQL coverage.

One operation may be in flight per handle. Concurrent use or closing while busy
fails with `StateError`. Close is idempotent, releases retained syntax, and does
not close the database. Handles are connection-bound; a closed database cannot
execute them. There is no global registry or automatic engine cache. Retained
SQL is limited to 65,536 code units and expression memoization to 2,048 entries
per handle. No file-format or schema change is introduced.

For typed parameters, updates, tracking and the optional bounded ORM cache see
[ORM preparation](../../sqlite_plus_orm/doc/PREPARED.md).
