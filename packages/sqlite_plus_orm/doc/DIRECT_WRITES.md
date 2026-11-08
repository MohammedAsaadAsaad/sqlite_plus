# Direct UPDATE and UPSERT (unreleased workspace)

These operations execute immediately through an owning DbContext. They do not
queue entity edits for saveChanges, attach input objects or begin a caller-visible
transaction that must be committed later. Existing saveChanges/read APIs keep
their behavior. No extra package or persistent ORM write table is required.

## Start from a complete model

The column names in the snippets below are mapping variables, not built-in ORM
fields. For example, a Product instance stores `product.stock` as an int, while
`stockColumn = Column<Product, int>(...)` describes how that property maps to a
SQL column. `property` names it, `codec` converts storage values, `read` reads
objects and `write` refreshes mutable objects after database writes.

The [self-contained, numbered example](../example/direct_writes_from_scratch.dart)
includes imports, Product, every Column, EntityType, schema creation, insertion,
querying, atomic stock subtraction and selective price upsert. Run from the root:

```sh
dart run packages/sqlite_plus_orm/example/direct_writes_from_scratch.dart
```

Expected stock progression is 10 → 7 → 7, and price is 500 → 650 in minor currency
units. `skuColumn` is the mapped primary key and the explicit upsert conflict
target. No generated model file or hidden mapping import is required. In the
older split-file example, `amount` is the descriptor for the `price` property;
its Dart variable name does not change the stored column name.

## Where do the column variables come from?

There are two ways to provide the same ORM metadata. Choose one per model:

| Item | Handwritten walkthrough | sqlite_plus_generator |
| --- | --- | --- |
| SKU descriptor | `skuColumn`, declared with `final ... = Column(...)` | `ProductColumns.sku` |
| Price descriptor | `priceColumn`, declared in the example | `ProductColumns.price` |
| Stock descriptor | `stockColumn`, declared in the example | `ProductColumns.stock` |
| Table mapping | `productType`, declared with `EntityType(...)` | `ProductMapping.instance` |
| A row's stock value | `product.stock` (an int) | `product.stock` (an int) |

The walkthrough deliberately writes the metadata by hand to expose every step.
`skuColumn` is an arbitrary Dart variable name, not a built-in field and not a
name automatically emitted by the generator. The older split-file example
imports its handwritten descriptors from `lib/direct_write_model.dart`.

For the generator alternative, create `lib/product.dart` with this model
**instead of** the walkthrough's handwritten Product/mapping declarations:

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

part 'product.orm.g.dart';

@DbEntity(table: 'products')
class Product {
  Product(this.sku, {required this.price, required this.stock});

  @DbKey()
  final String sku;
  int price;
  int stock;
}
```

Add `sqlite_plus_generator` to the application's `dev_dependencies`, run
`dart pub get`, then run from that application directory:

```sh
dart run sqlite_plus_generator --input lib/product.dart
```

The generator writes `lib/product.orm.g.dart`, including `ProductColumns` and
`ProductMapping`. Import `lib/product.dart` in the consuming code (for example,
`import 'lib/product.dart';` from an application-root script); the `part`
directive makes the generated declarations available through that library.
Do not import the `.orm.g.dart` part directly or edit it by hand.

Register the generated mapping and refer to the generated columns explicitly:

```dart
final context = DbContext(connection, DbModel([ProductMapping.instance]));
await context.migrations.ensureCreated();
final products = context.set(ProductMapping.instance);

await products.query
    .where(ProductColumns.sku.eq('BISCUIT-001') &
        ProductColumns.stock.gte(3))
    .update({ProductColumns.stock: ProductColumns.stock.subtract(3)});
```

Here `connection` is the `MutableDatabaseConnection(db)` created in the complete
walkthrough. The UPDATE API is identical for handwritten and generated metadata.
The repository already includes a real generated example:
[`Book` source](../example/lib/reading_log.dart) and its
[`BookColumns` / `BookMapping` output](../example/lib/reading_log.orm.g.dart).

## Constant and arithmetic UPDATE

```dart
final result = await products.query
    .where(stock.gte(quantity) & id.eq(productId))
    .update(
      {stock: stock.subtract(quantity)},
      returning: [id, stock],
    );
if (result.affectedRows == 0) {
  // No matching row: missing product or insufficient stock.
}
```

The condition and modification run in one SQL UPDATE, so there is no application
read/modify/write gap. All right-hand sides use the original row's values, as in
SQLite. Constants use the destination column codec. Numeric columns expose
`.add(value)` and `.subtract(value)` with bound operands. Cross-column numeric
assignments are supported; arbitrary computed/scalar/JSON assignments are not
part of this first milestone. Strings remain bound data, not SQL expressions.

```dart
await products.query.where(stock.eq(0)).update({available: false});
await products.query.update({price: price.add(1)}); // All rows deliberately.
```

No WHERE means all rows. Ordering, skip/take windows, FTS rank/vector distance,
virtual-table mappings and unowned standalone TypedQuery writes are rejected.
Use explicit key predicates for application-controlled update batches. Mapped
primary keys/generated fields cannot be assigned directly. Read-only entity
properties can still be changed in SQL; tracked immutable entities are replaced
using the existing store-value publication behavior.

## Managed revisions and optimistic checks

A mapping's managed version column increments automatically once per directly
updated row. Explicit version assignments are rejected. Include the expected
version in the filter when stale writes must affect zero rows:

```dart
final result = await products.query
    .where(id.eq(productId) & revision.eq(expectedRevision))
    .update({price: newPrice}, returning: [revision]);
```

Without that predicate this is a deliberate bulk update, not an implicit
per-entity optimistic check. Zero affected rows are returned normally. Codec
range errors (including arithmetic/version overflow) abort the transaction.

## UPSERT

```dart
final result = await products.upsert(
  incoming,
  conflictOn: [supplierId, supplierCode],
  update: [name, price],
);
```

New rows insert mapped input values, omitting a null generated primary key.
Conflicts use SQLite INSERT ... ON CONFLICT ... DO UPDATE, updating only the
listed fields plus an automatic managed-version increment. A conflict does not
replace the primary key or overwrite unlisted fields such as local stock.
Versioned inserts use the supplied initial version; conflicts increment the
stored version, not the incoming object's version. This is not an optimistic
compare-and-swap against the incoming version.

Conflict columns must match a real ordinary UNIQUE or PRIMARY KEY constraint.
Primary/compound keys and declared index collations are inspected through
read-only pragma table-valued SELECTs, including inside Changes transactions.
Partial/expression indexes and ambiguous differing collations are rejected.
A NULL conflict value is rejected: this API needs a stable identity, rather than
SQLite's multiple-NULL unique-key semantics. Conflict columns, keys, generated
fields and managed versions cannot appear in the conflict-update list. At least
one explicit update field is required; DO NOTHING is not provided by this API.

The input object is snapshotted at call time and is not automatically mutated or
tracked. Read actual generated/stored keys from the result. Input encoding follows
the normal codecs (for example, use double values for a REAL codec).

## Atomic batches

```dart
final result = await products.upsertMany(
  incomingProducts,
  conflictOn: [sku],
  update: [name, price],
  returning: [id, sku],
  batchSize: 200,
);
```

All chunks belong to one transaction. A failure in a later chunk rolls back
previous chunks and publishes no provisional tracked values. Before any source
INSERT, a bound VALUES/GROUP BY preflight rejects repeated conflict keys using
the actual unique-index collations (including NOCASE/RTRIM), across the entire
input, not merely inside each chunk. Column codecs keep the input storage types
consistent. The batch is not streamed: all input rows are encoded/copied now.

Default batchSize is 200, allowed 1–1000. Per call: at most 10000 inputs and
20000 conflict-validation parameters; each INSERT chunk is capped at 20000 binds
and 900000 SQL characters. Rows with/without a supplied generated key use separate
insert shapes. Limits fail explicitly; no automatic partial commit. Empty input
still validates its target metadata and transaction ownership, but changes no
source rows.

## Result values and triggers

`OrmWriteResult.affectedRows` counts direct SQLite source changes, excluding
additional trigger/FK changes; it does not distinguish inserted from updated.
BEFORE IGNORE triggers can result in fewer changes than input rows.

`rows` contains immutable maps of **SQL storage values** (INTEGER is BigInt),
with copied BLOBs on access. Use `RowReader(row).read(column)` to decode a selected
value with its codec. Results are snapshots, not tracked entities. UPDATE returns
no public rows unless returning is requested; UPSERT defaults to all mapped
columns. Pass `returning: []` to suppress public rows. Returned row order is not a
stable input-correlation contract; include key/conflict fields when correlating.

Internally, RETURNING collects assigned/version/requested fields for codec
validation, and keys when necessary. User triggers/FKs require rereading actual
stored target values after their effects; upsert batches do this after all chunks
so later triggers cannot leave earlier result rows stale. A target deleted or
rekeyed by a trigger is rejected if it cannot be found under its returned key.
This does not attempt to infer arbitrary trigger identity/provenance semantics.

## Tracking and concurrency policy

The default is intentionally conservative: **any pending added/modified/deleted
entity or relationship change anywhere in the context rejects the direct write
before source SQL**. Save those changes first, restore their clean values, or use
a separate context. This avoids guessing which tracked objects arbitrary triggers
and cascades might affect. There is no ignore-tracking escape hatch in this version.

Clean tracked objects across the model are reread inside the transaction, then
reconciled only after successful commit. Removed rows detach. Immutable objects
can be replaced, as with normal store-value publication; use entry.entity as the
canonical reference. Non-key edits made by application code after preflight while
SQL awaits are preserved as unsaved changes, against the newly stored snapshot.
Tracking membership, overlapping saveChanges and other direct writes are blocked
while a direct operation is pending. Primary-key edits are never accepted.

Refresh cost is proportional to the number/width of tracked rows. A fresh context
is preferable for large bulk operations that need no identity-map reconciliation.
No entity objects need to be materialized for untracked target rows, but internal
RETURNING values and engine sort/image buffers can still use memory proportional
to the operation. This is not a streaming or hard-memory-bounded UPDATE.

Unknown commit outcomes, rollback cleanup failures or store-value publication
failures poison the context; close/reopen and reconcile with the database before
retrying. The API never retries a mutation automatically. The operation cannot
join an externally opened transaction; its chunks own their complete transaction.

## Changes, Reactive and Inspector

A Changes-enabled connection uses its transaction driver, keeping source writes
and captured events atomic. The first direct operation initializes/verifies mapped
source capture, using the same requirements as enableReactive (including recursive
triggers). Capture/schema initialization can persist even if later source DML
fails; source rows/events from the failed write roll back. Existing source capture
must cover all mapped columns/keys. No engine observer or implicit migration is added.

After successful commit/publication, Reactive receives a conservative invalidation.
Even zero direct changes can invalidate because BEFORE IGNORE triggers may have
changed other rows. Unchanged results remain suppressed. Failed writes do not
publish a direct-write invalidation. Inspector observes the SQL when the context
uses its adapter; wrapper/internal-SQL visibility limits remain unchanged.

## Evidence and limits

[Runnable VM/Node assertions](../example/direct_writes.dart),
[AOT comparison](../../../benchmark_results/direct_writes/README.md), and native
SQLite 3.53.1 comparisons cover source values, versions, collations, triggers,
three database encodings and cross-open integrity. See compatibility/development
logs for test counts and platform scope. No package release, real device/browser
persistence, external transaction composition or universal performance claim.

Native testing exposed a core collation defect: SQLite NOCASE/RTRIM compare UTF-8
bytes even in UTF-16 databases. The comparator now follows that behavior, including
NOCASE's shared-NUL/full-length rule; BINARY retains database-encoding byte order.
Older indexes built with the incorrect ordering may need an explicit REINDEX
on a backed-up copy, especially with non-ASCII UTF-16 keys. No automatic reindex,
schema rewrite or migration is performed by this change.
