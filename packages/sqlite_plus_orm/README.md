# sqlite_plus_orm

A Pure Dart, metadata-driven ORM over the public sqlite_plus API. Runtime code
has no analyzer, reflection, native database or `dart:io` dependency. Metadata
can be written manually or emitted by sqlite_plus_generator.

## Generated mappings

An ordinary class with an `id` or `<ClassName>Id` field uses conventions. Table
and column names default to the Dart class and property names. The source needs
the runtime import and generated part declaration:

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';
part 'models.orm.g.dart';

class Customer {
  Customer({this.id, required this.name});
  final BigInt? id;
  final String name;
}
```

The generator emits `CustomerColumns`, `CustomerMapping` and `generatedModel`.
Nullable int/BigInt conventional keys are generated when null. Zero is an
explicit key. Assigned and composite keys require nonnull values at runtime.

```dart
final engine = await MutableSqliteDatabase.create();
final context = DbContext(MutableDatabaseConnection(engine), generatedModel);
await context.migrations.ensureCreated();
final customers = context.set(CustomerMapping.instance);
final pending = customers.add(Customer(name: 'Ada'));
await context.saveChanges();
final id = pending.entity.id!;
final rows = await customers.query
    .where(CustomerColumns.name.eq('Ada'))
    .orderBy([CustomerColumns.id.asc()]).take(20).toList();
final sameRows = await customers.query
    .filter((row) => row.name.equalTo('Ada') & (row.revision > 0))
    .orderByFields((row) => [row.name.ascending])
    .take(20)
    .toList();
await context.close();
await engine.close();
```

Import `MutableSqliteDatabase` from sqlite_plus in the application. For immutable
models the returned entry owns the reconstructed entity; the original object's
final key stays unchanged. `customers.replace(previous, replacement)` records
immutable updates and rejects primary-key changes.

## Values, queries and tracking

Built-in codecs cover signed-64-bit BigInt, portable 53-bit int, finite double,
String, bool (INTEGER 0/1), copied Uint8List and canonical UTC DateTime. Nullable
codecs preserve null. Custom codecs and manual metadata are supported; failures
identify the mapped property and retain their cause without printing values.

Typed predicates use bound values and quoted metadata identifiers. They compose
with `&`, `|` and `not()`; comparisons, null tests, IN, ordering, skip/take,
firstOrNull/single/count/any and asNoTracking are available. Pagination uses
portable nonnegative int bounds. Columns must belong to the exact mapping.
No arbitrary Dart closure is translated into SQL.

Tracking uses a context identity map and copied encoded snapshots, including
in-place blob edits. Repeated tracking queries retain existing objects and local
changes. A save freezes values before awaiting, owns its transaction, refreshes
stored rows and publishes generated keys/snapshots after commit. Later field
edits remain dirty. A concurrent save or synchronous tracking-membership change
during a save rejects; asynchronous queries serialize. External transactions
cannot be adopted. Indeterminate commits and failed rollback poison the context.
Manual mapping setters/reconstruction must succeed when applying committed store
values; a failure there also makes the context unusable.

`@DbVersion()` enables an integer revision predicate and increment for updates
and deletes. Stale or missing rows abort the complete save. Without a revision
column updates use the primary key. SQL defaults describe the schema; explicit
mapped null values remain SQL NULL, rather than requesting a default.

## Relationships

ForeignKey metadata describes ordered scalar fields, target keys, actions and
deferral. The generator infers unambiguous `<parentName>Id` references or accepts
`@DbReference(...)`. Composite relationships use manual metadata.

```dart
final parent = customers.add(Customer(name: 'Ada'));
final child = purchases.add(Purchase(total: 12.5));
child.reference(PurchaseRelationships.customer).set(parent);
await context.saveChanges();
final loaded = await child.reference(PurchaseRelationships.customer).load();
final orders = await parent.collection(PurchaseRelationships.customer).load();
```

Loads are explicit and preserve identity. `loadReferences`/`loadCollections`
batch entries with bounded parameter lists. Linked inserts/deletes follow
dependencies; unsupported immediate/generated cycles reject before SQL.
Required/optional/composite keys, deferred cycles and tracked CASCADE/SET NULL
refreshes have regression tests. Obtaining a relationship handle performs no I/O.

## Safe migrations

`context.migrations.plan()` returns an immutable live-schema baseline, target
and reviewable operations. New tables, ordinary nullable columns without
defaults/constraints, and nonunique indexes can apply through `applySafe`.
Matching legacy tables can be adopted without rewriting their data. Unmanaged
objects are preserved. Type/key/FK/nullability/default/unique changes, guessed
renames, drops and rebuilds require review; unsupported transformations need
explicit application SQL/mappings.

```dart
final plan = await context.migrations.plan();
await context.migrations.applySafe(plan);
```

When the updated model requires a separately reviewed rename, supply the exact
replacement operations before applying its plan:

```dart
final proposed = await context.migrations.plan();
final reviewed = proposed.withOperations([
  MigrationOperation.sql('ALTER TABLE people RENAME COLUMN old TO current',
      reason: 'Reviewed property rename; preserve existing values'),
]);
await context.migrations.apply(reviewed,
    approval: MigrationApproval.forPlan(reviewed));
```

Approval binds the exact plan. Schema/model changes make a plan stale. Application
rereads the baseline inside its transaction, validates the resulting schema/FKs
and updates protected ownership/version metadata atomically. No reusable
`allowDestructive` switch or inferred destructive migration exists.

## Verification and limits

Run `dart format .`, `dart analyze --fatal-infos` and `dart test`. Repository
development tools `verify_orm.py`, `verify_orm_queries.py` and
`verify_orm_migrations.py` pin native SQLite for cross-open, query and migration
comparisons; native SQLite is never a runtime dependency.

The JavaScript smoke compiles and runs the engine/ORM in memory with full BigInt
keys and relationships. It does not establish browser storage durability.
`BrowserDatabaseConnection` opens an `OpenedStorage`, and `close` writes the
exported image through the public storage API. The verified path is an
in-process `MemoryBrowserByteStore`: save two notes, filter with
`where(MappedField.equalTo(...))`, close, reopen, and filter again.
`durabilityPromised` stays false. Power loss is not claimed. The Chrome page
on Linux is `tool/chrome_orm_linux_x64.log`: placement `browser`, two saved
notes, and `reopenBody=kept`. That log is not a macOS, Windows, Android, or
iOS result. `MutableDatabaseConnection` remains the file and memory connection.
Adapters must honor OrmConnection ownership and transaction semantics. Engine
capabilities and exclusions remain in the repository compatibility matrix.
