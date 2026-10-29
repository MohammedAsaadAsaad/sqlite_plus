# sqlite_plus_orm

Typed queries, change tracking, relationships, and reviewed migrations for `sqlite_plus`. The application names columns and objects. The runtime writes the SQL. Runtime code has no analyzer, reflection, native database, or `dart:io` dependency.

Version `0.0.3`.

The pictures below are the engine, not this ORM. One arm64 phone, Bench versionCode 2009, the file round, 1000 rows, Asia/Hebron 14:00 on 2026-10-29. The same SQL, checksums matched. Bar length is measured time, and each row has its own scale. The size is taken before close, so the sqlite_plus file still includes the redo.

![Engine file-round statement time for 1000 rows.](doc/bench-time.png)

![Engine file size before close for the same statements.](doc/bench-size.png)

## Install

```yaml
dependencies:
  sqlite_plus_orm: ^0.0.3
```

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final connection = await MutableDatabaseConnection.openMemory();
final context = DbContext(connection, DbModel([bookType]));
await context.migrations.ensureCreated();
```

| Piece | Type | Role |
|---|---|---|
| Model | `EntityType`, `Column`, `DbModel` | Table, property, codec, read, and optional write |
| Unit of work | `DbContext`, `context.set` | Identity map and one transaction per `saveChanges` |
| Revision | `version: true` or `@DbVersion()` | Integer column incremented on update |
| Filter | `TypedQuery` | Bound comparisons, `skip`, `take`, `count`, `single` |
| JSON | `MappedField.at` | `json_extract` with a bound path |
| Search | `TypedQuery.search` | `table MATCH ?`, ordered by rank |
| Spatial | `Bounds.intersects` | Four R-tree comparisons |
| Links | `reference`, `collection` | Explicit load. The handle itself does no I/O |
| Schema | `migrations.plan`, `applySafe`, `apply` | Reviewable diff. Renames stay reviewed |

A plain save keeps the loaded rows until the image is exported or queried. Many deleted rows of one table with no trigger and no rewriting foreign key leave in one `DELETE`. A single-column key uses `IN`. A group that already covers every stored row deletes the table without a key list.

`sqlite_plus_generator` writes this metadata from ordinary classes. The reading log below is the same runtime with a hand-written mapping.

## Reading log

`example/lib/reading_log.dart` saves two books, renames one, and reads the JSON shelf. The application source has no SQL text.

| Step | Result |
|---|---|
| `saveChanges` after two `add` calls | `2` |
| `saveChanges` after `title = 'Kept Garden Revised'` | `1`, revision `1` |
| `saveChanges` with no edits | `0` |
| Title `Kept Garden Revised` and shelf `north` | one row |
| Shelf `south` | `Other Atlas`, revision `0` |
| Second `migrations.plan()` | empty |

```dart
final bookId = Column<Book, BigInt>(
    property: 'id', codec: Codecs.bigInt, read: (book) => book.id, keyOrder: 0);
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

final books = context.set(bookType);
final book = Book(BigInt.one, 'Kept Garden', '{"shelf":"north"}', 0);
books.add(book);
books.add(Book(BigInt.two, 'Other Atlas', '{"shelf":"south"}', 0));
await context.saveChanges();

book.title = 'Kept Garden Revised';
await context.saveChanges();

final kept = books.query.where(bookTitle.eq('Kept Garden Revised') &
    MappedField(bookNote).at(r'$.shelf').equalTo('north'));
final stored = await kept.orderBy([bookTitle.asc()]).single();
```

`stored.revision` is `1`. From a checkout, after `dart pub get` at the repository root:

```sh
cd example
dart run bin/main.dart
```

```text
Kept Garden Revised on north, revision 1; Other Atlas stays at revision 0; 1 match; idle save 0
```

A generated filter is the same query with generated names:

```dart
final rows = await purchases.query
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .toList();
```

## Predicates

| On `Column` | On `MappedField` | SQL |
|---|---|---|
| `eq` / `notEq` | `equalTo` / `notEqualTo` | `=` / `<>` |
| `lt` `lte` `gt` `gte` | `<` `<=` `>` `>=` | the same operator |
| `isNull` / `isNotNull` | `isNull` / `isNotNull` | `IS NULL` / `IS NOT NULL` |
| `inValues` | `oneOf` | `IN` |
| `asc` / `desc` | `ascending` / `descending` | `ORDER BY`, optional `NULLS FIRST` or `NULLS LAST` |
| | `at(path)` | `json_extract` with the path bound |

Combine predicates with `&`, `|`, and `not()`. `where`, `orderBy`, `skip`, `take`, `firstOrNull`, `single`, `count`, `any`, and `asNoTracking` stay on `TypedQuery`. `count` returns `BigInt`.

| Query call | Behavior |
|---|---|
| `single` | One row |
| `firstOrNull` | The first row, or null |
| `any` | Whether a row exists |
| `asNoTracking` | Read without putting the row in the identity map |
| `skip` / `take` | Portable nonnegative bounds |

A closure builds a predicate from these operators, and those operators become the SQL. Columns belong to the exact mapping.

## Codecs

| Dart type | Stored as |
|---|---|
| `BigInt` | Signed 64-bit integer |
| `int` | Portable 53-bit integer |
| `double` | Finite double |
| `String` | Text |
| `bool` | Integer `0` or `1` |
| `Uint8List` | A copied blob |
| `DateTime` | Canonical UTC |
| Nullable of any of those | SQL `NULL` preserved |

Custom codecs and manual metadata are supported. A failure names the mapped property and keeps its cause.

## Tracking

| Rule | Behavior |
|---|---|
| Identity | One object per key inside the context |
| Snapshot | Encoded values are copied, including in-place blob edits |
| Save | Values freeze before the first await. One transaction. Generated keys publish after commit |
| Later edits | A field changed after the snapshot stays dirty |
| Idle save | `saveChanges` returns `0` |
| Revision | One non-nullable `int` or `BigInt` that is not the key. Insert keeps the supplied value. Update increments it |
| Stale revision | The whole save aborts |
| Concurrency | A second save, or a membership change during a save, rejects. Queries serialize |
| Poison | An indeterminate commit or a failed rollback makes the context unusable |

The version column needs a write setter when the same object should receive the stored revision. SQL defaults describe the schema. An explicit mapped null is SQL `NULL`.

## Relationships

The generator infers an unambiguous `<parentName>Id`, or it reads `@DbReference(...)`. Composite relationships use manual metadata.

```dart
final parent = customers.add(Customer(name: 'Ada'));
final child = purchases.add(Purchase(total: 12.5));
child.reference(PurchaseRelationships.customer).set(parent);
await context.saveChanges();
final loaded = await child.reference(PurchaseRelationships.customer).load();
final orders = await parent.collection(PurchaseRelationships.customer).load();
```

| Call | Result |
|---|---|
| `reference(...).set` | Points the child at the parent before save |
| `reference(...).load` | The same parent instance the context already tracks |
| `collection(...).load` | The children, preserving identity |
| `loadReferences` / `loadCollections` | The same loads, batched |

Linked inserts and deletes follow dependencies. Required, optional, and composite keys, deferred cycles, and tracked `CASCADE` and `SET NULL` refreshes are covered by the package tests.

## Migrations

| Call | When |
|---|---|
| `ensureCreated` | Empty database. The examples use this |
| `plan` | Diff the live schema against the model |
| `applySafe` | New tables, ordinary nullable columns, nonunique indexes |
| `apply` + `MigrationApproval.forPlan` | A reviewed statement, such as a rename |

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

| Rule | Behavior |
|---|---|
| Approval | Binds that exact plan |
| Stale plan | A schema or model change requires a new plan |
| Apply | Rereads the baseline inside the transaction and validates foreign keys |
| Legacy table | A matching table can be adopted |
| Unmanaged objects | Stay in the database |
| Second plan | Empty when the stored SQL still matches, including FTS5 and R-tree |

## Connections

| Connection | Opens |
|---|---|
| `MutableDatabaseConnection.openMemory` | The in-memory engine. The reading log uses this |
| `MutableDatabaseConnection(database)` | An existing `MutableSqliteDatabase` |
| `BrowserDatabaseConnection.open` | An `OpenedStorage`. `close` writes the exported image |

Development tools `verify_orm.py`, `verify_orm_queries.py`, and `verify_orm_migrations.py` pin native SQLite for cross-open, query, and migration comparisons. Native SQLite stays in those tools. The runtime is the Pure Dart engine.

The JavaScript smoke runs the engine and ORM in memory with `BigInt` keys and relationships. The current browser round trip uses an in-process `MemoryBrowserByteStore`: save two notes, filter, close, reopen, and filter again. The Chrome session on Linux is `tool/chrome_orm_linux_x64.log`: placement `browser`, two saved notes, and `reopenBody=kept`.

## Android

The same runtime ran inside a debug APK on Android 15, API 35, `x86_64`. Two books were inserted, one title change bumped the revision to `1`, and the idle save returned `0`. The line is `packages/sqlite_plus/tool/android_probe_api35_x86_64.log`. An iOS simulator run is planned.

| Step | Result on device |
|---|---|
| `saveChanges` after two adds | `2` |
| `saveChanges` after the rename | `1`, revision `1` |
| Idle `saveChanges` | `0` |
| Stored title | `Kept Garden Revised` |

## Planned

| Area | Next |
|---|---|
| Engine follow-up | `json_pretty`, correlated `json_each`, EXPLAIN bytecode, STAT4, `auto_vacuum`, a durable two-database commit, more journal modes |
| FTS and collations | Extended FTS, ICU and locale collations |
| Storage | A durable browser store |
| Platforms | iOS |
| Scale | Benchmarks at 100000 and 1000000 rows |
