# sqlite_plus_orm

Typed queries, change tracking, relationships, and reviewed migrations for `sqlite_plus`. The application names columns and objects. The runtime writes the SQL. Runtime code has no analyzer, reflection, native database, or `dart:io` dependency.

Version `0.0.1-dev.1` is the current pre-release. Publication on pub.dev is planned and waits for an explicit request. Until then:

```yaml
dependencies:
  sqlite_plus_orm:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus_orm
      ref: main
```

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final connection = await MutableDatabaseConnection.openMemory();
final context = DbContext(connection, DbModel([bookType]));
await context.migrations.ensureCreated();
```

`sqlite_plus_generator` writes the `EntityType`, the columns, and the `filter` extensions from ordinary Dart classes. This page shows the same runtime with a hand-written mapping, then the relationship and migration calls the generator emits.

## What a context gives you

**A model.** `EntityType` names the table. `Column` names the property, the SQL name, the codec, the read closure, and the optional write closure. `DbModel` is the set of types the context accepts.

**Tracked graphs.** `context.set(type)` is the identity map for that type. `add` marks an insert. Assigning a mapped field marks an update. `saveChanges` freezes the values, owns one transaction, writes the rows, and writes generated keys back onto the objects. A second save with no edits returns `0`.

**Revisions.** `@DbVersion()` on one non-nullable `int` or `BigInt` that is not the key makes that column the revision. An update increments it. A save whose stored revision does not match the object aborts the whole save.

**Predicates that bind their values.** `Column.eq`, `notEq`, `lt`, `lte`, `gt`, `gte`, `isNull`, `isNotNull`, and `inValues`. `MappedField` exposes the same tests as `equalTo`, comparison operators, `oneOf`, and `ascending` / `descending`. Combine predicates with `&`, `|`, and `not()`. `orderBy`, `skip`, `take`, `firstOrNull`, `single`, `count`, `any`, and `asNoTracking` stay on `TypedQuery`. `COUNT` comes back as `BigInt`.

**JSON paths.** `MappedField.at(path)` and the generated `path` helper emit `json_extract`. The path and the compared value are both bound.

**Full text and rectangles.** `TypedQuery.search(text)` binds `table MATCH ?` and orders by rank. `Bounds.intersects(Rect)` emits the four R-tree comparisons. The generator exposes those as `search` and `bounds`.

**Relationships.** A `ForeignKey` names the child columns, the parent key, the delete action, and the deferral. `reference(...).set` and `reference(...).load` are explicit. `collection(...).load` reads the children. `loadReferences` and `loadCollections` batch those reads. Obtaining the handle does no I/O.

**Migrations you can read.** `migrations.plan()` diffs the live schema against the model. `applySafe` creates tables, adds ordinary nullable columns, and adds nonunique indexes. A rename, a drop, a type change, or a rebuild is a reviewed `MigrationOperation.sql` plus `MigrationApproval.forPlan`.

## Reading log

`example/` is a separate Dart project. `example/lib/reading_log.dart` maps `Book` by hand. Two books are inserted. Renaming one increments its revision and leaves the other at revision `0`. The kept book is read by title and by the JSON shelf. The application source has no SQL text.

```dart
final class Book {
  Book(this.id, this.title, this.note, this.revision);

  final BigInt id;
  String title;
  final String note;
  int revision;
}

final bookId = Column<Book, BigInt>(
    property: 'id',
    codec: Codecs.bigInt,
    read: (book) => book.id,
    keyOrder: 0);
final bookTitle = Column<Book, String>(
    property: 'title',
    codec: Codecs.text,
    read: (book) => book.title,
    write: (book, value) => book.title = value);
final bookNote = Column<Book, String>(
    property: 'note', codec: Codecs.text, read: (book) => book.note);
final bookRevision = Column<Book, int>(
    property: 'revision',
    codec: Codecs.integer,
    read: (book) => book.revision,
    write: (book, value) => book.revision = value,
    version: true);
final bookType = EntityType<Book>(
    tableName: 'books',
    columns: [bookId, bookTitle, bookNote, bookRevision],
    create: (row) => Book(row.read(bookId), row.read(bookTitle),
        row.read(bookNote), row.read(bookRevision)),
    applyStoreValues: (book, row) => Book(row.read(bookId),
        row.read(bookTitle), row.read(bookNote), row.read(bookRevision)));

final connection = await MutableDatabaseConnection.openMemory();
final context = DbContext(connection, DbModel([bookType]));
await context.migrations.ensureCreated();

final books = context.set(bookType);
final book = Book(BigInt.one, 'Kept Garden', '{"shelf":"north"}', 0);
final other = Book(BigInt.two, 'Other Atlas', '{"shelf":"south"}', 0);
books.add(book);
books.add(other);
await context.saveChanges(); // 2

book.title = 'Kept Garden Revised';
await context.saveChanges(); // 1
final idle = await context.saveChanges(); // 0

final kept = books.query.where(bookTitle.eq('Kept Garden Revised') &
    MappedField(bookNote).at(r'$.shelf').equalTo('north'));
final stored = await kept.orderBy([bookTitle.asc()]).single();
final keptCount = await kept.count();
final south = await books.query
    .where(MappedField(bookNote).at(r'$.shelf').equalTo('south'))
    .single();
```

`stored.title` is `Kept Garden Revised`, `stored.revision` is `1`, and `keptCount` is `BigInt.one`. `south.title` is `Other Atlas` and `south.revision` is `0`. A second `migrations.plan()` is empty.

From a checkout, after `dart pub get` at the repository root:

```sh
cd example
dart run bin/main.dart
```

The program prints:

```text
Kept Garden Revised on north, revision 1; Other Atlas stays at revision 0; 1 match; idle save 0
```

Generated applications use the same context. A generated filter stays in Dart:

```dart
final rows = await purchases.query
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .toList();
```

That call is `where` and `orderBy` under the generated names. The [generator example](../sqlite_plus_generator/example) stores three purchases and keeps the two above 20, ordered by total.

## Relationships

Foreign-key metadata describes ordered scalar fields, target keys, actions, and deferral. The generator infers an unambiguous `<parentName>Id` reference, or it reads `@DbReference(...)`. Composite relationships use manual metadata.

```dart
final parent = customers.add(Customer(name: 'Ada'));
final child = purchases.add(Purchase(total: 12.5));
child.reference(PurchaseRelationships.customer).set(parent);
await context.saveChanges();

final loaded = await child.reference(PurchaseRelationships.customer).load();
final orders = await parent.collection(PurchaseRelationships.customer).load();
```

`loaded` is the same `parent` instance the context already tracks. `orders` contains `child`. Loads preserve identity. `loadReferences` and `loadCollections` batch entries with bounded parameter lists. Linked inserts and deletes follow dependencies. Required, optional, and composite keys, deferred cycles, and tracked `CASCADE` and `SET NULL` refreshes are covered by the package tests.

## Safe migrations

`context.migrations.plan()` returns an immutable live-schema baseline, the target, and reviewable operations. New tables, ordinary nullable columns without defaults or constraints, and nonunique indexes apply through `applySafe`. Matching legacy tables can be adopted. Unmanaged objects stay in the database.

```dart
final plan = await context.migrations.plan();
await context.migrations.applySafe(plan);
```

When the updated model requires a separately reviewed rename, supply the exact replacement operations before applying its plan:

```dart
final proposed = await context.migrations.plan();
final reviewed = proposed.withOperations([
  MigrationOperation.sql(
    'ALTER TABLE people RENAME COLUMN old TO current',
    reason: 'Reviewed property rename; preserve existing values',
  ),
]);
await context.migrations.apply(
  reviewed,
  approval: MigrationApproval.forPlan(reviewed),
);
```

Approval binds that plan. A schema or model change makes a plan stale. Application rereads the baseline inside its transaction, validates the resulting schema and foreign keys, and updates the protected ownership and version metadata atomically.

`ensureCreated` is the call the examples use on an empty memory database. A second plan is empty when the stored SQL still matches the model, including FTS5 and R-tree tables.

## Values, queries, and tracking

Built-in codecs cover signed 64-bit `BigInt`, portable 53-bit `int`, finite `double`, `String`, `bool` stored as integer `0` or `1`, a copied `Uint8List`, and a canonical UTC `DateTime`. Nullable codecs preserve null. Custom codecs and manual metadata are supported. Failures identify the mapped property and retain their cause.

Typed predicates use bound values and quoted metadata identifiers. Columns belong to the exact mapping. Pagination uses portable nonnegative `int` bounds. A Dart closure builds a predicate from the operators above, and those operators become the SQL.

Tracking uses a context identity map and copied encoded snapshots, including in-place blob edits. Repeated tracking queries retain existing objects and local changes. A save freezes values before awaiting, owns its transaction, refreshes stored rows, and publishes generated keys and snapshots after commit. Later field edits remain dirty. A concurrent save, or a synchronous tracking-membership change during a save, rejects. Asynchronous queries serialize. External transactions cannot be adopted. An indeterminate commit or a failed rollback makes the context unusable. Manual mapping setters and reconstruction must succeed when applying committed store values.

The version column is one non-nullable `int` or `BigInt` that is not the key. The context increments it on a modified save. The first insert keeps the supplied value, including `0`. An update of another field makes that `0` into `1`. The column needs a write setter when the same object should receive the stored revision. Stale or missing rows abort the complete save. Without a revision column, updates use the primary key. SQL defaults describe the schema. An explicit mapped null is SQL `NULL`.

## Verification

Run `dart format .`, `dart analyze --fatal-infos`, and `dart test`. Repository development tools `verify_orm.py`, `verify_orm_queries.py`, and `verify_orm_migrations.py` pin native SQLite for cross-open, query, and migration comparisons. Native SQLite stays in those development tools. The runtime is the Pure Dart engine.

The JavaScript smoke compiles and runs the engine and ORM in memory with full `BigInt` keys and relationships. `BrowserDatabaseConnection` opens an `OpenedStorage`, and `close` writes the exported image through the public storage API. The current round trip uses an in-process `MemoryBrowserByteStore`: save two notes, filter with `where(MappedField.equalTo(...))`, close, reopen, and filter again. The Chrome session on Linux is `tool/chrome_orm_linux_x64.log`: placement `browser`, two saved notes, and `reopenBody=kept`.

`MutableDatabaseConnection` is the file and memory connection. Adapters honor `OrmConnection` ownership and transaction semantics.

## Planned

The ORM follows the engine plan: `json_pretty`, correlated `json_each`, EXPLAIN bytecode, STAT4, `auto_vacuum`, a durable two-database commit, more journal modes, the extended FTS surface, ICU and locale collations, and benchmarks at 100000 and 1000000 rows. A durable browser store, Android, and iOS are planned.
