![sqlite_plus](doc/logo.png)

# sqlite_plus_orm

Dart objects on `sqlite_plus`. You change a field. `saveChanges` writes one transaction and bumps the revision. You change the class. The migrator creates the table, or asks you for the SQL when a change would drop data.

```yaml
dependencies:
  sqlite_plus_orm: ^0.1.4
```

## Save two books, rename one

The generator writes `BookMapping` from this class. `title` and `revision` are mutable, so the same object receives the stored revision.

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

part 'models.orm.g.dart';

@DbEntity(table: 'books')
class Book {
  Book({this.id, required this.title, this.revision = 0});

  final BigInt? id;
  String title;
  @DbVersion()
  int revision;
}
```

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

final connection = await MutableDatabaseConnection.openMemory();
final context = DbContext(connection, generatedModel);
await context.migrations.ensureCreated();

final books = context.set(BookMapping.instance);
final book = books.add(Book(title: 'Kept Garden'));
books.add(Book(title: 'Other Atlas'));
await context.saveChanges(); // 2

book.title = 'Kept Garden Revised';
await context.saveChanges(); // 1
await context.saveChanges(); // 0

final stored = await books.query
    .filter((row) => row.title.equalTo('Kept Garden Revised'))
    .single();
```

`stored.revision` is 1. An idle save writes nothing. The other book stays at revision 0.

## Create the table

`ensureCreated` is the first up. On an empty database it creates every mapped table.

```dart
await context.migrations.ensureCreated();
```

![Create, add, or review.](doc/migrations.png)

## Up: add a column

Add a nullable field and generate again.

```dart
@DbEntity(table: 'books')
class Book {
  Book({this.id, required this.title, this.subtitle, this.revision = 0});

  final BigInt? id;
  String title;
  String? subtitle;
  @DbVersion()
  int revision;
}
```

```dart
final plan = await context.migrations.plan();
await context.migrations.applySafe(plan);
```

Stored rows stay. `subtitle` is null. A second `plan()` is empty.

`applySafe` accepts a new table, a new nullable column, and a new non-unique index. A required column, a unique index, a type change, or a new foreign key is not applied this way.

## Up: rename the column

Renaming the Dart field and keeping `@DbColumn(name: 'title')` does not change the table. Changing the SQL name does. The migrator will not guess which old column matches the new one.

```dart
@DbEntity(table: 'books')
class Book {
  Book({this.id, required this.name, this.revision = 0});

  final BigInt? id;
  @DbColumn(name: 'name')
  String name;
  @DbVersion()
  int revision;
}
```

```dart
final reviewed = (await context.migrations.plan()).withOperations([
  MigrationOperation.sql(
    'ALTER TABLE books RENAME COLUMN title TO name',
    reason: 'Keep the stored titles',
  ),
]);
await context.migrations.apply(
  reviewed,
  approval: MigrationApproval.forPlan(reviewed),
);
```

`MigrationApproval.forPlan` binds that exact plan. A copied plan needs a new approval. If the statement fails, the transaction rolls back and the schema is unchanged.

## Down

Point the model at the previous column, then supply the reverse statement. Nothing is reversed for you.

```dart
final down = (await context.migrations.plan()).withOperations([
  MigrationOperation.sql(
    'ALTER TABLE books RENAME COLUMN name TO title',
    reason: 'Restore the previous column',
  ),
]);
await context.migrations.apply(
  down,
  approval: MigrationApproval.forPlan(down),
);
```

Removing a class is the same shape. `plan()` stops until you retain the table or drop it.

```dart
final dropped = (await context.migrations.plan()).withOperations([
  MigrationOperation.sql(
    'DROP TABLE books',
    reason: 'The model no longer maps this table',
  ),
]);
await context.migrations.apply(
  dropped,
  approval: MigrationApproval.forPlan(dropped),
);
```

`MigrationOperation.retainTable('books')` keeps the table and its rows, and stops managing it. A type change is a rebuild you write: create the new table, `INSERT SELECT` with your cast, drop the old table, and rename.

## Read it back

A JSON document is a path on the `@DbJson` field.

```dart
final notes = context.set(NoteMapping.instance);
final north = await notes.query
    .filter((row) => row.path(r'$.shelf').equalTo('north'))
    .toList();
```

A purchase points at its customer before the save. `load` returns the same instance the context already tracks.

```dart
final ada = customers.add(Customer(name: 'Ada'));
final order = purchases.add(Purchase(total: 12.5));
order.reference(PurchaseRelationships.customer).set(ada);
await context.saveChanges();
final buyer = await order.reference(PurchaseRelationships.customer).load();
```

With a generated mapping the filter is a closure. `selectWhere` is that same filter. `where` and `andWhere` take the predicate directly. `select`, `get`, `findAll`, and `all` read the rows. `orderBy` and `sortBy` take the ordering list. `orderByFields` takes the closure. `offset` and `limit` are `skip` and `take`. `exists` is `any`. `first` requires a row. `singleOrNull` is null when none match and fails when several do.

```dart
final expensive = await purchases.query
    .selectWhere((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .select();
```

## Call a function on the row

`twice` reads `revision`. On a loaded book it returns the number. In the query it is the same method, and the comparison is SQL.

```dart
@DbEntity(table: 'books')
class Book {
  Book({this.id, required this.title, required this.revision});

  final BigInt? id;
  String title;
  BigInt revision;

  @DbScalar()
  BigInt? twice() => revision * BigInt.two;
}
```

```dart
final large = await books.query
    .selectWhere((row) => (row.twice() > 20) | row.title.upper().equalTo('WEST'))
    .orderByFields((row) => [row.title.length().ascending])
    .toList();
```

`large` keeps a book whose doubled revision is above 20, or whose title is `WEST`, and orders those rows by title length. Parenthesize a comparison before `&` or `|`.

| You write | The engine runs |
|---|---|
| `row.twice() > 20` | `books_twice("revision") > ?` |
| `row.revision.abs() > 3` | `abs("revision") > ?` |
| `row.title.upper().equalTo('WEST')` | `upper("title") = ?` |
| `row.title.trim().length()` | `length(trim("title"))` |
| `row.note.coalesce(row.title)` | `coalesce("note", "title")` |
| `row.title.substr(1, 4)` | `substr("title", ?, ?)` |
| `row.updated.date()` | `date("updated")` |
| `row.path(r'$.shelf').equalTo('north')` | `json_extract("body", ?) = ?` |

The method takes no parameters. A getter is the same shape. The body reads mapped fields and stays synchronous. `DbContext` registers `books_twice` on the connection. A null stored in a non-nullable field makes that call null. A thrown body fails the statement. `abs`, `upper`, `lower`, `length`, `trim`, `substr`, `replace`, `round`, `coalesce`, `ifNull`, `concat`, `sign`, `floor`, `ceil`, `sqrt`, `date`, `time`, `dateTime`, `unixEpoch`, and `julianDay` are the engine, called on the column or on another call.

## Search and nearest neighbors

`module` and `tokenizer` are strings. The constants are the names this ORM already knows how to create. A name that is not in the list is still a string, so you can write it by hand.

| Constant | Value | What it selects |
|---|---|---|
| `DbModules.fts5` | `fts5` | Full-text table. The key is `rowid`. Other columns are text |
| `DbModules.rtree` | `rtree` | Rectangle table: integer key, then `minX`, `maxX`, `minY`, `maxY` |
| `DbModules.vec0` | `vec0` | One vector column, stored by `sqlite_plus_vec` |
| `DbTokenizers.unicode61` | `unicode61` | FTS5 default. Letters stay whole tokens. This is not an Arabic stemmer |
| `DbTokenizers.porter` | `porter` | English Porter stemmer |
| `DbTokenizers.trigram` | `trigram` | Overlapping three-character tokens |
| `DbTokenizers.ascii` | `ascii` | ASCII letters and digits. FTS3 and FTS4 default |
| `DbTokenizers.simple` | `simple` | FTS3 spelling of `ascii`. FTS5 rejects this name |
| `DbVectorMetrics.l2` | `l2` | Euclidean distance. The default `@DbVector` metric |
| `DbVectorMetrics.cosine` | `cosine` | One minus cosine similarity, from 0 to 2 |

`DbVectorLimits.minimumDimensions` is 1. `DbVectorLimits.maximumDimensions` and `DbVectorLimits.maximumNeighbors` are 4096.

```dart
@DbEntity(module: DbModules.fts5, tokenizer: DbTokenizers.porter)
class Article {
  Article({this.rowid, required this.body});
  @DbKey(generated: true)
  final BigInt? rowid;
  final String body;
}

@DbEntity(module: DbModules.vec0)
class Point {
  Point({this.rowid, required this.embedding});
  @DbKey(generated: true)
  final BigInt? rowid;
  @DbVector(4, metric: DbVectorMetrics.cosine)
  final List<double> embedding;
}
```

`tokenizer: 'arabic'` is valid on `DbModules.fts5` because the value is a string. Register `SqlitePlusArabic` before `ensureCreated`. Register `SqlitePlusVec` before creating or querying a `vec0` table. `search('kept')` is the full-text query. `nearest(const [0.9, 0.1, 0, 0], k: 1)` writes `embedding MATCH ? AND k = ?` and orders by distance. An unknown module such as `'vec9'` is rejected, because the ORM has to write `CREATE VIRTUAL TABLE`. An unknown metric identifier is kept and checked by `vec0` when the table is created.

## The other packages

[`sqlite_plus`](../sqlite_plus) is the engine. The same connection answers SQL directly.

```dart
final rows = await connection.database.query(
  'SELECT title FROM books WHERE upper(title) = ?',
  ['WEST'],
);
```

[`sqlite_plus_arabic`](../sqlite_plus_arabic) registers the `arabic` tokenizer. [`sqlite_plus_vec`](../sqlite_plus_vec) registers `vec0` and answers `nearest`. [`sqlite_plus_generator`](../sqlite_plus_generator) writes `twice()`, `search`, and `nearest` from the class.

```sh
dart run sqlite_plus_generator
```

From the package root this writes a part for every public `@DbEntity` and writes `lib/sqlite_plus_migrations.g.dart` for `ensureCreated`. One library is still `dart run sqlite_plus_generator --input lib/models.dart`.

## The engine underneath

1,000 rows on Linux, release build. The same SQL, and every checksum matched. In memory, a transaction of inserts was 263× and search was 107×. On a file, search was 142× and a point lookup was 104×.

![Memory, 1,000 rows.](doc/bench-time.png)

![File, 1,000 rows.](doc/bench-file.png)

## Rules worth knowing

| Change | What happens |
|---|---|
| First schema | `ensureCreated` |
| Nullable column, new table, non-unique index | `plan` then `applySafe` |
| Unique index | `apply` with approval. Duplicates roll the save back |
| Rename, drop, type change, required column | You write the SQL, then approve that plan |
| Down | The reverse statement, after the model points at the old shape |
| Second `plan()` | Empty when the stored schema matches, including FTS5, R-tree, and vec0 |

One object per key lives in the context. `saveChanges` freezes values before the first await and publishes generated keys after commit. A stale revision aborts the whole save. `count` returns `BigInt`.
