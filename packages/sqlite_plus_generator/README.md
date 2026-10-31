![sqlite_plus](doc/logo.png)

# sqlite_plus_generator

Write the class. This tool writes the columns, the revision, the JSON path, the full-text search, and the R-tree box. The analyzer stays on your machine. The application depends on `sqlite_plus_orm`.

```yaml
dev_dependencies:
  sqlite_plus_generator: ^0.1.2
```

```sh
dart run sqlite_plus_generator --input lib/models.dart
```

`--check` compares the part with the file on disk. `--class Book` limits the write.

## The classes

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

## What you call

```dart
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
final inside = (await PlaceQuery(places.query)
        .filter((row) => row.bounds.intersects(
            const Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
        .toList())
    .single;
final buyer = await purchase.reference(PurchaseRelationships.customer).load();
```

`expensive` is `22.5` then `30.0`. `note.document` is `{"title":"kept"}`. `article.body` is `alpha kept`. `inside` is place `1`. `buyer` is `Ada`.

After the first `ensureCreated`, a new nullable field is an up migration:

```sh
dart run sqlite_plus_generator --input lib/models.dart
```

```dart
final plan = await context.migrations.plan();
await context.migrations.applySafe(plan);
```

A renamed SQL column is not guessed. Keep `@DbColumn(name: 'title')` when only the Dart name changes. When the column itself changes, write the `ALTER` and approve that plan. The reverse statement is the down migration. The ORM page shows both.

## The engine underneath

1,000 rows on Linux, release build. The same SQL, and every checksum matched. In memory, a transaction of inserts was 263× and search was 107×. On a file, search was 142× and a point lookup was 104×.

![Memory, 1,000 rows.](doc/bench-time.png)

![File, 1,000 rows.](doc/bench-file.png)

## What the part contains

| You write | The part contains |
|---|---|
| A concrete public class | `EntityType`, columns, `filter`, `orderByFields` |
| `id` or `<ClassName>Id` | The primary key |
| `@DbColumn(name: ...)` | That SQL name |
| `@DbIgnore` | The field left out of the table |
| `@DbKey(generated: true)` | A key assigned on insert |
| `@DbVersion()` | The revision column |
| `<Parent>Id` or `@DbReference` | `reference` and `collection` |
| `@DbJson()` on one `String` | `path` |
| `@DbEntity(module: 'fts5')` | `USING fts5` and `search` |
| `@DbEntity(module: 'rtree')` | `USING rtree` and `bounds` |

The write is deterministic and formatted. Hand-written files and symbolic links stay in place. Fields are `int`, `BigInt`, `double`, `bool`, `String`, `Uint8List`, and `DateTime`, including nullable aliases. A generic, an inherited field, or an unsupported type is reported before any file is written.
