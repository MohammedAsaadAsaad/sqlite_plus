![sqlite_plus](doc/logo.png)

# sqlite_plus_orm

Dart objects on `sqlite_plus`. You change a field. `saveChanges` writes one transaction and bumps the revision. You change the class. The migrator creates the table, or asks you for the SQL when a change would drop data.

```yaml
dependencies:
  sqlite_plus_orm: ^0.1.11
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

final books = await DbSet.openDbFile(BookMapping.instance, 'books.db');
final book = books.add(Book(title: 'Kept Garden'));
books.add(Book(title: 'Other Atlas'));
await books.saveChanges(); // 2

book.title = 'Kept Garden Revised';
await books.saveChanges(); // 1
await books.saveChanges(); // 0

final stored = await books.query
    .filter((row) => row.title.equalTo('Kept Garden Revised'))
    .single();
```

`stored.revision` is 1. An idle save writes nothing. The other book stays at revision 0. Closing the set leaves `books.db` on disk, and the next `openDbFile` reads the revised title.

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

`@DbDocument()` stores one object in that same kind of TEXT column. The class writes `toJson` and `fromJson`. The filter reads one value with `path`, and `fromJson` runs for the rows that come back.

```dart
@DbEntity(table: 'notes')
class Note {
  Note({this.id, required this.card, this.revision = 0});

  final BigInt? id;
  @DbDocument()
  Card card;
  @DbVersion()
  int revision;
}

class Card {
  Card({required this.title, required this.pages});
  final String title;
  final int pages;

  Map<String, Object?> toJson() => {'title': title, 'pages': pages};

  factory Card.fromJson(Map<String, Object?> json) => Card(
    title: json['title']! as String,
    pages: json['pages']! as int,
  );
}
```

```dart
final notes = context.set(NoteMapping.instance);
notes.add(Note(card: Card(title: 'Kept Garden', pages: 320)));
notes.add(Note(card: Card(title: 'Other Atlas', pages: 40)));
await context.saveChanges();
final kept = await notes.query
    .filter((row) => row.card.path(r'$.title').equalTo('Kept Garden'))
    .single();
```

`kept.card.pages` is 320. The SQL is `json_extract("card", ?) = ?`, with parameters `$.title` and `Kept Garden`. `Other Atlas` stays stored text.

```dart
kept.card = Card(title: 'Kept Garden', pages: 321);
await context.saveChanges();
final revised = await notes.query
    .filter((row) => row.card.path(r'$.title').equalTo('Kept Garden'))
    .single();
```

`revised.card.pages` is 321 and `revised.revision` is 1. The other note stays at revision 0. `fromJson` can take `Map<String, dynamic>`; the generator wraps that parameter. A `String` field still uses `@DbJson`.

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

## Names you can write by hand

`module`, `tokenizer`, and `metric` are strings. The constants are the names this ORM already knows how to spell. `DbModules.fts5` and `'fts5'` are the same value. A tokenizer or a metric that is not in the list is still a string, so a package can add a name without an ORM release. A module outside `fts5`, `rtree`, and `vec0` is rejected: the generator has to write `CREATE VIRTUAL TABLE`, and it only knows those three shapes.

| Constant | Value | What a row does |
|---|---|---|
| `DbModules.fts5` | `fts5` | Full-text table. The key is `rowid`. Other columns are text. `search('kept')` returns `alpha kept` |
| `DbModules.rtree` | `rtree` | Rectangle table: integer key, then `minX`, `maxX`, `minY`, `maxY`. `bounds.intersects` returns the overlapping place |
| `DbModules.vec0` | `vec0` | One `List<double>` column. `nearest` returns the closest rows |
| `DbTokenizers.unicode61` | `unicode61` | FTS5 default when `tokenizer` is omitted. `مرحبا` stays one token and matches itself |
| `DbTokenizers.porter` | `porter` | English stemmer. A row `running` matches `search('run')` |
| `DbTokenizers.trigram` | `trigram` | Overlapping three-character tokens. `abcdef` matches `bcd`. A query shorter than three characters matches nothing |
| `DbTokenizers.ascii` | `ascii` | ASCII letters and digits. This is the FTS3 and FTS4 default |
| `DbTokenizers.simple` | `simple` | The FTS3 spelling of `ascii`. FTS5 answers `no such tokenizer: simple` |
| `DbVectorMetrics.l2` | `l2` | Euclidean distance. `[0, 0]` to `[3, 4]` is `5`. This is the `@DbVector` default |
| `DbVectorMetrics.cosine` | `cosine` | One minus cosine similarity. Equal vectors are `0`, orthogonal vectors are `1`, opposite vectors are `2` |

`DbVectorLimits.minimumDimensions` is 1. `DbVectorLimits.maximumDimensions` and `DbVectorLimits.maximumNeighbors` are 4096. Each constant has a dartdoc comment on the declaration.

`ForeignKeyAction`, `MigrationSafety`, `EntityState`, and `MigrationKind` stay enums. Their sets are closed inside the ORM and a handwritten string would not select another behavior.

## Search a word

```dart
@DbEntity(module: DbModules.fts5, tokenizer: DbTokenizers.porter)
class Article {
  Article({this.rowid, required this.body});
  @DbKey(generated: true)
  final BigInt? rowid;
  final String body;
}
```

`ensureCreated` writes `CREATE VIRTUAL TABLE "Article" USING fts5("body", tokenize = 'porter')`. `rowid` is the key and is omitted from the `fts5(...)` list.

```dart
final articles = context.set(ArticleMapping.instance);
articles.add(Article(body: 'running'));
articles.add(Article(body: 'other words'));
await context.saveChanges(); // 2
final hit = await articles.query.search('run').single();
```

`hit.body` is `running`. Porter did the stemming. The engine already contains this tokenizer, so no extra package is registered.

Arabic stemming is the string `'arabic'`. [`sqlite_plus_arabic`](https://pub.dev/packages/sqlite_plus_arabic) registers that name. The ORM only stores it.

```dart
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';

@DbEntity(module: DbModules.fts5, tokenizer: ArabicTokenizers.arabic)
class Note {
  Note({this.rowid, required this.body});
  @DbKey(generated: true)
  final BigInt? rowid;
  final String body;
}
```

`tokenizer: 'arabic'` is the same annotation. The created SQL contains `tokenize = 'arabic'`.

```dart
SqlitePlusArabic.register(connection.database);
await context.migrations.ensureCreated();
final notes = context.set(NoteMapping.instance);
notes.add(Note(body: 'في الحديقة'));
notes.add(Note(body: 'سيارة'));
await context.saveChanges(); // 2
final garden = await notes.query.search('الحديقة').single();
final missed = await notes.query.search('كتاب').toList();
```

`garden.body` is `في الحديقة`. `الحديقة` and `حديقة` share a token. `missed` is empty. Register before `ensureCreated`. Without that call the create fails with `no such tokenizer: arabic`. A later `plan()` is empty while the stored virtual SQL still matches. The Arabic package page lists the prefix and suffix rules, including why `الله` stays `الله`.

## Find the nearest vector

```dart
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

@DbEntity(module: DbModules.vec0)
class Point {
  Point({this.rowid, required this.embedding});
  @DbKey(generated: true)
  final BigInt? rowid;
  @DbVector(4, metric: DbVectorMetrics.cosine)
  final List<double> embedding;
}
```

`@DbVector(4)` without `metric` uses `DbVectorMetrics.l2`. The created SQL for the class above is `CREATE VIRTUAL TABLE "Point" USING vec0("embedding" float[4] distance_metric=cosine)`. `Codecs.vector(4)` stores little-endian float32 and rejects a list of another length.

```dart
SqlitePlusVec.register(connection.database);
await context.migrations.ensureCreated();
final points = context.set(PointMapping.instance);
points.add(Point(embedding: const [1, 0, 0, 0]));
points.add(Point(embedding: const [0, 1, 0, 0]));
await context.saveChanges(); // 2
final nearest =
    await points.query.nearest(const [0.8, 0.2, 0, 0], k: 1).single();
```

`nearest.embedding[0]` is greater than `0.5`. The query is `"embedding" MATCH ? AND "k" = ?`, ordered by `distance`. The scan reads both rows. [`sqlite_plus_vec`](https://pub.dev/packages/sqlite_plus_vec) owns the distance. This ORM writes the SQL and checks the list length. `nearest(const [1, 0], k: 1)` throws `OrmCodecException`. `k: 0` throws `RangeError`. `k` above 4096 throws `RangeError` as well.

`module: 'vec9'` is rejected while the model is built. `metric: 'hamming'` is accepted as an identifier and `vec0` rejects it at `CREATE` with `vec0: unknown distance metric`. A column named `distance` or `k` on a `vec0` entity is rejected, because those names are the hidden query columns.

## The other packages

[`sqlite_plus`](https://pub.dev/packages/sqlite_plus) is the engine. The same connection answers SQL directly.

```dart
final rows = await connection.database.query(
  'SELECT title FROM books WHERE upper(title) = ?',
  ['WEST'],
);
```

[`sqlite_plus_arabic`](https://pub.dev/packages/sqlite_plus_arabic) registers `arabic` and documents the stem of `حديقة`, `كتابه`, and `الله`. [`sqlite_plus_vec`](https://pub.dev/packages/sqlite_plus_vec) registers `vec0`, encodes float32, and answers `MATCH` with `k`. [`sqlite_plus_generator`](https://pub.dev/packages/sqlite_plus_generator) writes `twice()`, `search`, and `nearest` from the class. The generated part does not import the two extension packages. Call `register` on the connection yourself.

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

## The packages on pub.dev

Each package is a complete library. Import only what you call. The links below are the package pages.

| Package | Version | Page |
|---|---|---|
| sqlite_plus | `^0.1.12` | <https://pub.dev/packages/sqlite_plus> |
| sqlite_plus_orm | `^0.1.11` | <https://pub.dev/packages/sqlite_plus_orm> |
| sqlite_plus_generator | `^0.1.11` | <https://pub.dev/packages/sqlite_plus_generator> |
| sqlite_plus_arabic | `^0.1.5` | <https://pub.dev/packages/sqlite_plus_arabic> |
| sqlite_plus_vec | `^0.1.5` | <https://pub.dev/packages/sqlite_plus_vec> |
| sqlite_plus_geo | `^0.1.4` | <https://pub.dev/packages/sqlite_plus_geo> |

### sqlite_plus

```yaml
dependencies:
  sqlite_plus: ^0.1.12
```

```dart
import 'package:sqlite_plus/sqlite_plus_io.dart';

final db = await openDatabase('shelf.db');
await db.execute(
  'CREATE TABLE IF NOT EXISTS note (id INTEGER PRIMARY KEY, title TEXT)',
);
await db.insert('note', {'title': 'Kept Garden'});
final rows = await db.query(
  'note',
  columns: ['title'],
  where: 'title LIKE ?',
  whereArgs: ['%Garden%'],
);
```

The title is `Kept Garden`. A missing `shelf.db` is created. The next launch opens the same file. Integers come back as `BigInt`. There is no FFI and no native SQLite in this engine.

![The row is written to shelf.db, the handle closes, and the next open reads the same title.](doc/shelf-file.png)

### sqlite_plus_orm

```yaml
dependencies:
  sqlite_plus_orm: ^0.1.11
```

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

@DbEntity()
class Note {
  Note({this.id, required this.title, this.revision = 0});
  final BigInt? id;
  String title;
  @DbVersion()
  int revision;
}
```

`saveChanges` writes one transaction and bumps `revision`. A table with no `PRIMARY KEY` still maps. Its key is the SQLite row id:

```dart
@DbKey(generated: true)
final BigInt? rowid;
```

`plan()` adopts that row id and does not rebuild the table.

### sqlite_plus_generator

```yaml
dev_dependencies:
  sqlite_plus_generator: ^0.1.11
```

```sh
dart run sqlite_plus_generator
```

From the package root, that command writes a part for every public `@DbEntity` under `lib/`, plus `lib/sqlite_plus_migrations.g.dart`.

### sqlite_plus_arabic

```yaml
dependencies:
  sqlite_plus_arabic: ^0.1.5
```

```dart
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';

SqlitePlusArabic.register(db);
await db.execute(
  "CREATE VIRTUAL TABLE passage USING fts5(body, tokenize = 'arabic')",
);
```

`حديقة` and `الحديقة` share one token. `الله` stays `الله`. This is not the SQLite ICU Arabic tokenizer. Register before `CREATE`, and again after the image is reopened.

### sqlite_plus_vec

```yaml
dependencies:
  sqlite_plus_vec: ^0.1.5
```

```dart
import 'package:sqlite_plus_vec/sqlite_plus_vec.dart';

SqlitePlusVec.register(db);
await db.execute(
  'CREATE VIRTUAL TABLE point USING vec0(embedding float[2] distance_metric=l2)',
);
```

`MATCH` with `k` scans every stored float32 vector. The file is not a sqlite-vec database.

### sqlite_plus_geo

```yaml
dependencies:
  sqlite_plus_geo: ^0.1.4
```

```dart
import 'package:sqlite_plus_geo/sqlite_plus_geo.dart';

final geo = GeoSession(db);
await geo.createSpatialTable(
  'facilities',
  geometryColumn: 'location',
  geometryType: GeoGeometryType.point,
  srid: 4326,
);
```

X is longitude and Y is latitude. `ST_SetSRID` only labels a geometry. `ST_Transform` moves a coordinate between EPSG:4326, EPSG:3857, and WGS84 UTM. A degree is not a metre. This is not an OGC, PostGIS, SpatiaLite, or GeoPackage certification.
