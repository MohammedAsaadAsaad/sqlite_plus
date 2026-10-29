# sqlite_plus_generator

Write a Dart class. This tool writes the ORM mapping: columns, a revision, a JSON path, full-text search, and an R-tree box. The analyzer stays on your machine. The application depends on `sqlite_plus_orm`.

Version `0.1.1`.

```yaml
dev_dependencies:
  sqlite_plus_generator: ^0.1.1
```

```sh
dart run sqlite_plus_generator --input lib/models.dart
```

`--check` compares the part with the file on disk. `--class Customer` limits the write. `--output` sets the part path.

## Five classes, four reads

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
  final double minX, maxX, minY, maxY;
}
```

`customerId` becomes `PurchaseRelationships.customer`. The part is `models.orm.g.dart`.

```dart
final connection = await MutableDatabaseConnection.openMemory();
final context = DbContext(connection, generatedModel);
await context.migrations.ensureCreated();

final purchases = context.set(PurchaseMapping.instance);
final ada = context.set(CustomerMapping.instance).add(Customer(name: 'Ada'));
final purchase = purchases.add(Purchase(total: 22.5));
purchases.add(Purchase(total: 4));
purchases.add(Purchase(total: 30));
purchase.reference(PurchaseRelationships.customer).set(ada);
final notes = context.set(NoteMapping.instance);
notes.add(Note(document: '{"title":"kept"}'));
final articles = context.set(ArticleMapping.instance);
articles.add(Article(body: 'alpha kept'));
final places = context.set(PlaceMapping.instance);
places.add(Place(id: BigInt.one, minX: 0, maxX: 1, minY: 0, maxY: 1));
await context.saveChanges();

final expensive = await purchases.query
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .toList();
final note = (await NoteQuery(notes.query)
        .filter((row) => row.path(r'$.title').equalTo('kept'))
        .toList())
    .single;
final article = (await ArticleQuery(articles.query).search('kept').toList()).single;
final inside = await PlaceQuery(places.query)
    .filter((row) => row.bounds.intersects(
        const Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
    .toList();
final buyer = await purchase.reference(PurchaseRelationships.customer).load();
```

`expensive` is `22.5` then `30.0`. `note.document` is `{"title":"kept"}`. `article.body` is `alpha kept`. `inside` is place `1`. `buyer` is `Ada`. The checked-in example also stores the rows that do not match, ten in all, and prints:

```text
Ada bought [22.5, 30.0]; {"title":"kept"}; alpha kept; place 1 of 2
```

## The engine underneath

These pictures are the `sqlite_plus` engine on one arm64 phone, Bench versionCode 2009, Asia/Hebron 14:00 on 2026-10-29. One thousand rows, the same SQL, every checksum matched. Each bar is that row's measured time. In memory, a transaction of inserts was 39× and search was 17×. On a file, search was 11× and a point lookup was 14×. One sample. The phone model was not in the log.

![Memory round, 1000 rows. Bar length matches measured time.](doc/bench-time.png)

![File round, 1000 rows. Bar length matches measured time.](doc/bench-file.png)

## What one class becomes

| You write | The part contains |
|---|---|
| A concrete public class | `EntityType`, columns, `filter`, `orderByFields` |
| `id` or `<ClassName>Id` | The primary key |
| `@DbColumn` | The SQL name |
| `@DbIgnore` | The field left out of the table |
| `@DbKey` | Key order, or `generated: true` |
| `@DbVersion()` | The revision column |
| `<Parent>Id` or `@DbReference` | `reference` and `collection` |
| `@DbJson()` on one `String` | `path(String path)` |
| `@DbEntity(module: 'fts5')` | `USING fts5` and `search(String text)` |
| `@DbEntity(module: 'rtree')` | `USING rtree` and `bounds` |

SQL names default to the exact Dart names. The write is deterministic and formatted. Hand-written files and symbolic links stay in place. The FTS key is `rowid`. The R-tree key is the integer `id`, then `minX`, `maxX`, `minY`, and `maxY`.

From a checkout, after `dart pub get` at the repository root:

```sh
cd example
dart run sqlite_plus_generator --input lib/models.dart --check
dart run bin/main.dart
```

## Field rules

| Field | Accepted |
|---|---|
| `int`, `BigInt`, `double`, `bool`, `String`, `Uint8List`, `DateTime` | Yes, including nullable aliases |
| Constructor | Must be able to rebuild persisted state |
| Mutable field | Assigned after construction |
| Immutable generated key | Reconstructed after save |
| Nullable assigned key | A non-null value when the entity is tracked |
| Composite key | Yes |
| Composite relationship, custom codec, index | Manual metadata on `sqlite_plus_orm` |

| Diagnostic | Examples |
|---|---|
| Located, before any write | Generic, inherited, or mixin storage |
| Located, before any write | Collection fields, unsupported types, ambiguous constructors, unmappable final state |

Tests cover golden output, conventions, annotations, aliases, constructors, diagnostics, CLI ownership, and compiled consumers. Those consumers run migrations, linked CRUD, revisions, queries, relationships, and a reopen. The tool resolves `analyzer` 14 and `dart_style` 3. The ORM runtime depends on `sqlite_plus`.

## Where the generated code runs

The generator stays on the development machine. The ORM runtime it writes was executed on Android 15, API 35, `x86_64`: two inserts, one revision update, and an idle save of `0`. The line is `packages/sqlite_plus/tool/android_probe_api35_x86_64.log`. An iOS simulator run is planned.

## Planned

| Area | Next |
|---|---|
| Storage | A durable browser store |
| Platforms | iOS |
| SQL | `json_pretty`, correlated `json_each`, EXPLAIN bytecode, STAT4, `auto_vacuum`, a durable two-database commit, more journal modes, extended FTS, ICU and locale collations |
| Scale | Benchmarks at 100000 and 1000000 rows |
