# Prepared atomic imports (unreleased workspace)

Import preparation validates already mapped entities, explains rejected/dropped
input rows, snapshots encoded values and applies through the same atomic
upsertMany path. There is no CSV/XLSX parser, implicit deletion or new package.
The API is included in sqlite_plus_orm.dart for generated and handwritten models.

## Complete example and source of column names

Run the [complete model-to-import-to-preview example](../../sqlite_plus_branch/example/import_preview.dart):

```sh
dart run packages/sqlite_plus_branch/example/import_preview.dart
```

It declares Product, skuColumn/nameColumn/priceColumn and productType explicitly.
With sqlite_plus_generator, annotated Product instead supplies
ProductColumns.sku/name/price and ProductMapping.instance. Neither naming style
is a built-in domain field. The [mapping walkthrough](DIRECT_WRITES.md#where-do-the-column-variables-come-from)
explains generation and imports from the beginning.

For an existing mapped DbSet named products:

```dart
final plan = await products.prepareImport(
  incomingProducts,
  conflictOn: [ProductColumns.sku],
  update: [ProductColumns.name, ProductColumns.price],
  duplicates: OrmImportDuplicates.keepLast,
  emptyValues: OrmImportEmptyValues.keepExisting,
  validate: (product) => product.price < 0 ? 'Negative price' : null,
);

for (final issue in plan.issues) {
  print('${issue.inputIndex}: ${issue.code}: ${issue.message}');
}
if (plan.canApply) {
  final result = await plan.apply(batchSize: 200);
  print(result.affectedRows);
}
```

Application format parsing/mapping happens before this API. Validator returns
null for acceptance or a reason for rejection. Validator/codec exceptions become
invalidValue issues containing only their type, not exception messages/stacks.
An iterator/parser exception aborts preparation; no import source writes occurred.
Preparation may run read-only uniqueness metadata/CTE queries.

## Decisions and counts

- inputCount: all supplied input entities.
- readyCount: valid rows retained after the chosen duplicate policy.
- rejectedCount: distinct input indexes with an error.
- droppedCount: distinct indexes explicitly discarded by keepFirst/keepLast.
- issues: immutable diagnostics, ordered by zero-based inputIndex; error=false
  denotes an explicitly allowed duplicate drop, not silently skipped validation.

Default duplicate policy rejects all members of a repeated-key group and makes
canApply false. keepFirst/keepLast choose by original input order. SQLite groups
using the actual full unique-index collations, including NOCASE/RTRIM and BLOB
keys. No Dart String equality approximation or case-folding dictionary is used.
NULL conflict keys reject the row. Unknown/missing/ambiguous unique targets fail
preparation; partial/expression unique targets remain unsupported.

Counts describe inputs, not promised inserted/updated database counts. No source
row existence estimate is presented as a durable approval. All errors must be
resolved by correcting and preparing input again; apply does not silently accept
only valid rows. Use Branch preview to inspect actual final stored differences.

## Empty values and atomicity

Default overwrite writes incoming update fields, including SQL NULL and empty
text when permitted by the codec/schema. keepExisting preserves a stored field
on conflict only when its incoming SQL value is NULL or exactly zero-length TEXT.
Whitespace, zero, false and empty BLOBs are not empty text. Inserts always use
incoming values; there is no existing value to preserve. Required codec/DB
constraints can still reject inserts.

Only update columns participate; unlisted existing fields remain stored. Primary,
conflict, generated and managed-version columns cannot be update fields. Managed
versions increment as with upsertMany, even if incoming empty fields preserve
stored values. SQL constraints/triggers run normally under existing ORM behavior.

apply is single-use after success and rejects overlap. It snapshots values at
prepareImport call time, before async SQL; editing original objects later does
not change the plan and inputs are not attached/mutated. Apply revalidates actual
unique metadata/collations; a changed conflict collation requires re-preparation.
It resolves current destination values in the transaction, without caching an
old row to implement keepExisting.

All chunks commit or roll back together. A DB error leaves the plan retryable on
a healthy context; uncertainty follows the existing ORM poison/recovery contract.
Clean tracking refreshes; dirty tracking rejects writes. Changes, Reactive and
Inspector follow the existing upsertMany path (covered by integration tests).
Preparation is not an application-wide lock; it is not a stale-safe row approval.

Bounds match direct upserts: 10,000 inputs, 20,000 conflict-key binds, batchSize
1..1000 (default 200), per-statement bind/SQL limits. Both input and SQL preparation
are buffered; no streaming, resumption, per-chunk commit or idempotency key is
claimed. Input limits are not a hard process-memory cap.

## Review actual changes before acceptance

Use `branches.preview((draft) async { ... })`, open a short-lived DbContext on
MutableDatabaseConnection(draft), prepare/apply there and close the context before
the callback returns. Review preview.changes and preview.conflicts, then explicitly
merge or close. The callback is never rerun at merge; the source and reviewed
working image must still match. See [Branch documentation](../../sqlite_plus_branch/README.md#operation-preview).
Branch's ordinary-table/no-trigger limitations still apply; Changes-captured main
databases are therefore not Branch preview targets in the current milestone.

These APIs are unreleased. Workspace checks do not establish compatibility with
older published ORM versions or independently publishable dependency constraints.

## Core performance follow-up

The core now avoids repeated whole-database validation for eligible UPSERTs.
There is no new import option or schema migration. See the [before/after AOT
measurements](../../../benchmark_results/import_performance/README.md) for the
1000-row comparison, 10,000-row probe, ordinary operations, and SKU workloads.
Complex indexes, key changes, triggers and foreign keys can retain slower paths;
benchmark your actual schema and storage. Existing buffering and input limits
still apply.
