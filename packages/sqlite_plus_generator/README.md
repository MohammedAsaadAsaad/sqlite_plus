# sqlite_plus_generator

A development-time generator for `sqlite_plus_orm`. It reads Dart classes and writes the runtime mappings: columns, codecs, keys, revisions, relationships, JSON `path`, FTS5 `search`, and R-tree `bounds`. The generated application depends on `sqlite_plus_orm`. The analyzer stays in this development tool.

Version `0.0.1-dev.1` is the current pre-release. Publication on pub.dev is planned and waits for an explicit request. Until then:

```yaml
dev_dependencies:
  sqlite_plus_generator:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus_generator
      ref: main
```

```sh
dart run sqlite_plus_generator --input lib/models.dart
dart run sqlite_plus_generator --input lib/models.dart --check
```

## What one run writes

From a concrete public class the generator writes:

- an `EntityType` and a column list, with SQL names taken from the Dart names unless `@DbColumn` says otherwise
- a constructor call that rebuilds the object from a row, and an `applyStoreValues` path for tracked updates
- `filter` and `orderByFields` on the query, so comparisons stay in Dart
- a relationship when a field is `<Parent>Id` or carries `@DbReference`
- `path(String path)` when one `String` field carries `@DbJson`
- `search(String text)` when `@DbEntity(module: 'fts5')` marks the class
- `bounds` when `@DbEntity(module: 'rtree')` marks the class

`--check` compares that output with the file on disk and writes nothing. The write itself is deterministic, formatted, and replaced through a unique temporary file.

## The model

`example/lib/models.dart` is a complete library: a customer with a generated key and a revision, a purchase that points at the customer, a JSON note, an FTS5 article, and an R-tree place.

```dart
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

part 'models.orm.g.dart';

class Customer {
  Customer({this.id, required this.name, this.revision = 0});

  final BigInt? id;
  final String name;
  @DbVersion()
  final int revision;
}

class Purchase {
  Purchase({this.id, this.customerId, required this.total});

  BigInt? id;
  BigInt? customerId;
  double total;
}

class Note {
  Note({this.id, required this.document});

  final BigInt? id;
  @DbJson()
  final String document;
}

@DbEntity(module: 'fts5')
class Article {
  Article({this.rowid, required this.body});

  @DbKey(generated: true)
  final BigInt? rowid;
  final String body;
}

@DbEntity(module: 'rtree')
class Place {
  Place({
    required this.id,
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
  });

  final BigInt id;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
}
```

`Customer.id` follows the `id` convention and is a generated `BigInt` key. `Purchase.customerId` is the customer relationship. `Note.document` emits `path`. The article key is `rowid`, which FTS5 requires, and the content column is `body`. The place key is the integer `id`, followed by the four doubles the R-tree module stores.

## The application

`example/lib/library_app.dart` imports `sqlite_plus_orm` and `models.dart`. It opens memory, ensures the schema, and saves ten rows: one customer, three purchases, two notes, two articles, and two places. The purchase is linked before the save, so the foreign key is written with the row.

```dart
final connection = await MutableDatabaseConnection.openMemory();
final context = DbContext(connection, generatedModel);
await context.migrations.ensureCreated();

final customers = context.set(CustomerMapping.instance);
final purchases = context.set(PurchaseMapping.instance);
final notes = context.set(NoteMapping.instance);
final articles = context.set(ArticleMapping.instance);
final places = context.set(PlaceMapping.instance);

final customer = customers.add(Customer(name: 'Ada'));
final purchase = purchases.add(Purchase(total: 22.5));
purchases.add(Purchase(total: 4));
purchases.add(Purchase(total: 30));
purchase.reference(PurchaseRelationships.customer).set(customer);
notes.add(Note(document: '{"title":"kept"}'));
notes.add(Note(document: '{"title":"other"}'));
articles.add(Article(body: 'alpha kept'));
articles.add(Article(body: 'beta lost'));
places.add(Place(id: BigInt.one, minX: 0, maxX: 1, minY: 0, maxY: 1));
places.add(Place(id: BigInt.two, minX: 5, maxX: 6, minY: 5, maxY: 6));
await context.saveChanges(); // 10

final matched = purchases.query
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending]);
final rows = await matched.toList(); // totals 22.5, then 30.0
final matchCount = await matched.count(); // BigInt.two

final note = (await NoteQuery(notes.query)
        .filter((row) => row.path(r'$.title').equalTo('kept'))
        .toList())
    .single;
// note.document == '{"title":"kept"}'

final article =
    (await ArticleQuery(articles.query).search('kept').toList()).single;
// article.body == 'alpha kept'

final inside = await PlaceQuery(places.query)
    .filter((row) => row.bounds.intersects(
        const Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
    .toList();
// inside.single.id == BigInt.one, and places.query.count() == BigInt.two

final buyer = await purchase.reference(PurchaseRelationships.customer).load();
// buyer?.name == 'Ada'
```

`filter((row) => row.total > 20.0)` is a generated predicate. The comparison is SQL, and `20.0` is a bound parameter. `path(r'$.title')` is `json_extract` with the path bound. `search('kept')` is `MATCH` ordered by rank. `bounds.intersects` is the four R-tree comparisons. `load()` returns the tracked customer.

From a checkout, after `dart pub get` at the repository root:

```sh
cd example
dart run sqlite_plus_generator --input lib/models.dart --check
dart run bin/main.dart
```

The program prints:

```text
Ada bought [22.5, 30.0]; {"title":"kept"}; alpha kept; place 1 of 2
```

`example/test/library_app_test.dart` expects customer `Ada`, totals `22.5` then `30.0`, note `{"title":"kept"}`, article `alpha kept`, place id `1` of two stored places, and an empty second migration plan. `example/lib/models.dart` passes `--check`. `models.orm.g.dart` is checked in.

## Command line

The executable name is `sqlite_plus_generator`.

```sh
dart run sqlite_plus_generator --input lib/models.dart
dart run sqlite_plus_generator --input lib/models.dart --class Customer --class Purchase
dart run sqlite_plus_generator --input lib/models.dart --output lib/models.orm.g.dart
dart run sqlite_plus_generator --input lib/models.dart --check
```

Repeated `--class` selects classes. `--output` sets the part path. `--check` fails when the part would change. From this package directory the repository example is:

```sh
dart run bin/sqlite_plus_generator.dart --input example/lib/models.dart --check
```

The source file imports `sqlite_plus_orm` and declares `part 'models.orm.g.dart';`.

## Conventions

Concrete public classes with `id` or `<ClassName>Id` are mapped. SQL names default to the exact Dart names. Optional `@DbEntity`, `@DbColumn`, `@DbIgnore`, `@DbKey`, `@DbVersion`, `@DbJson`, and `@DbReference` override those conventions. Annotations resolve by type identity and accept an import prefix.

`@DbReference.column` names a target Dart property. Without it, the target needs one primary key. `@DbJson()` on one `String` field emits `path`. `@DbEntity(module: 'fts5')` needs a `rowid` key and `String` content columns, and emits `search`. `@DbEntity(module: 'rtree')` needs an integer key first and `double` `minX`, `maxX`, `minY`, and `maxY`, and emits `bounds`.

Supported fields are `int`, `BigInt`, `double`, `bool`, `String`, `Uint8List`, `DateTime`, and nullable aliases of those types. Constructors must map persisted state. Mutable fields can be assigned after construction. Immutable generated keys reconstruct the entry value after save. Nullable assigned keys still require a non-null value when an entity is tracked. Composite keys are supported. Composite relationships, custom codecs, indexes, and unsupported model shapes use manual metadata on `sqlite_plus_orm`.

Generic storage, inherited storage, mixin storage, unsupported types, collection fields, ambiguous constructors, and unmappable final state produce located diagnostics. The generator validates every selected model before it writes. Hand-written files and symbolic links stay in place. `--check` compares the part with the file on disk.

Tests cover golden output, conventions, annotations, aliases, constructors, negative diagnostics, CLI ownership and staleness, and compiled generated consumers. Those consumers run migrations, linked CRUD, revisions, queries, relationships, and a reopen. Analyzer `6.4.1` and `dart_style` `2.3.6` are pinned for the tested SDK. They are generator dependencies. The ORM runtime depends on `sqlite_plus`.

## Planned

The generator follows the engine and ORM plan: a durable browser store, Android, iOS, and the wider SQL surface of `json_pretty`, correlated `json_each`, EXPLAIN bytecode, STAT4, `auto_vacuum`, a durable two-database commit, more journal modes, extended FTS, and ICU and locale collations. Benchmarks at 100000 and 1000000 rows are planned.
