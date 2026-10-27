# sqlite_plus

A Pure Dart SQLite engine, a typed ORM, and a mapping generator. SQL, JSON, FTS5, R-tree, change tracking, and generated filters run in the Dart VM. The production runtime has no FFI, native SQLite, or WASM.

Version `0.0.1-dev.1` is the current pre-release. Publication on pub.dev is planned and waits for an explicit request. Until then, each package README shows a git dependency.

| Package | You write | You get |
|---|---|---|
| [`sqlite_plus`](packages/sqlite_plus) | SQL, bound parameters, and Dart callbacks | Joins, CTEs, windows, UPSERT, triggers, JSON, FTS5, R-tree, geopoly, and a reopenable database image |
| [`sqlite_plus_orm`](packages/sqlite_plus_orm) | Columns, predicates, and entity objects | Tracked saves, revisions, JSON paths, relationships, and reviewed migrations |
| [`sqlite_plus_generator`](packages/sqlite_plus_generator) | Ordinary Dart classes | Mappings, `filter`, JSON `path`, FTS `search`, and R-tree `bounds` |

Each package has an example project under `example/`. The examples are workspace members and stay in the repository.

## A generated library

`sqlite_plus_generator` reads the classes in `packages/sqlite_plus_generator/example/lib/models.dart` and writes `models.orm.g.dart`. The application imports `sqlite_plus_orm` and the model. The runtime writes the SQL.

```dart
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

`packages/sqlite_plus_generator/example/lib/library_app.dart` saves one customer, three purchases, two notes, two articles, and two places. That is ten rows. It then keeps the purchases above 20, the JSON note whose title is `kept`, the FTS article matching `kept`, and the place that intersects the unit box. The purchase points at the customer, and the load returns that same object.

```dart
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

final rows = await purchases.query
    .filter((row) => row.total > 20.0)
    .orderByFields((row) => [row.total.ascending])
    .toList();
final note = (await NoteQuery(notes.query)
        .filter((row) => row.path(r'$.title').equalTo('kept'))
        .toList())
    .single;
final article =
    (await ArticleQuery(articles.query).search('kept').toList()).single;
final inside = await PlaceQuery(places.query)
    .filter((row) => row.bounds
        .intersects(const Rect(minX: 0, minY: 0, maxX: 1, maxY: 1)))
    .toList();
final buyer = await purchase.reference(PurchaseRelationships.customer).load();
```

The example prints:

```text
Ada bought [22.5, 30.0]; {"title":"kept"}; alpha kept; place 1 of 2
```

The second migration plan is empty. The full classes, the save, and the checks live in the [generator package](packages/sqlite_plus_generator) and its [example](packages/sqlite_plus_generator/example).

## SQL, JSON, FTS5, and R-tree in one image

`sqlite_plus` is the engine those mappings call. `packages/sqlite_plus/example/lib/library_tour.dart` builds one in-memory library:

- two cards inserted with bound `json_object` arguments
- a third insert inside `BEGIN` … `ROLLBACK`, so `COUNT(*)` stays `2`
- `json_extract` with a bound path, returning the title `Kept Garden` and the page count `320`
- an FTS5 table, `highlight`, and `bm25` for the token `kept`
- a second `MATCH` on an Arabic token, returning `Arabic Shelf` once
- an R-tree query that returns shelf `1` from the unit box and leaves shelf `2` outside it
- `PRAGMA user_version=7`, then `exportImage` and `fromImage`

The reopened image still has the title `Kept Garden` and version `7`. The example prints:

```text
Kept Garden (320 pages) | a garden [kept] in the margin | Arabic Shelf x1 | place 1 | cards 2 | version 7 | reopen Kept Garden v7 | 40960 bytes
```

The same process can register a Dart function and call it from SQL:

```dart
final db = await MutableSqliteDatabase.create();
db.functions.registerScalar('twice', 1,
    (args) => args.single == null ? null : (args.single as BigInt) * BigInt.two);
final result = await db.query('SELECT twice(?)', [21]);
```

`twice(21)` is `42`. Callbacks stay on that connection. The [engine README](packages/sqlite_plus) lists the SQL surface and walks through the tour.

## Typed saves with no SQL in the application

`sqlite_plus_orm` tracks objects you already hold. `packages/sqlite_plus_orm/example/lib/reading_log.dart` maps a `Book`, saves two of them, renames one, and reads it back by title and by a JSON shelf path. The renamed book moves to revision `1`. The other stays at revision `0`. A later save with no edits returns `0`.

```dart
book.title = 'Kept Garden Revised';
await context.saveChanges(); // 1
final kept = books.query.where(_bookTitle.eq('Kept Garden Revised') &
    MappedField(_bookNote).at(r'$.shelf').equalTo('north'));
final stored = await kept.orderBy([_bookTitle.asc()]).single();
```

The example prints:

```text
Kept Garden Revised on north, revision 1; Other Atlas stays at revision 0; 1 match; idle save 0
```

Codecs cover signed 64-bit `BigInt`, portable 53-bit `int`, finite `double`, `String`, `bool`, copied `Uint8List`, and canonical UTC `DateTime`. Relationships load explicitly. Migrations plan against the live schema, apply the safe subset, and require a reviewed statement for a rename. The [ORM README](packages/sqlite_plus_orm) has the mapping, the relationship, and the migration.

## Run the three examples

From a checkout:

```sh
dart pub get
(cd packages/sqlite_plus/example && dart run bin/main.dart)
(cd packages/sqlite_plus_orm/example && dart run bin/main.dart)
(cd packages/sqlite_plus_generator/example && dart run bin/main.dart)
```

Regenerate and check the generated library from its example directory:

```sh
(cd packages/sqlite_plus_generator/example && dart run sqlite_plus_generator --input lib/models.dart --check)
```

## Depend on the git repository

```yaml
dependencies:
  sqlite_plus:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus
      ref: main
  sqlite_plus_orm:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus_orm
      ref: main

dev_dependencies:
  sqlite_plus_generator:
    git:
      url: https://github.com/MohammedAsaadAsaad/sqlite_plus
      path: packages/sqlite_plus_generator
      ref: main
```

File databases use `package:sqlite_plus/sqlite_plus_io.dart`. That library imports `dart:io`. Browser storage is a separate path: `openBrowserStorage` reports `canRead`, `canWrite`, `durabilityPromised`, and `placement`.

## Planned

The next engine work adds `json_pretty`, correlated `json_each`, EXPLAIN bytecode, STAT4, `auto_vacuum`, a durable commit across two databases, and more journal modes. The FTS plan adds multi-page leaves, porter, trigram, detail, tokendata, locale, and FTS3/FTS4 writes. ICU and locale collations are planned. A durable browser store, Android, iOS, power-loss durability, and benchmarks at 100000 and 1000000 rows are planned. The Linux AOT file `benchmark_results/scenarios_10k_linux_x64.json` is the current 10000-row measurement. `COMPATIBILITY_MATRIX.md` is the test record.

## Develop

The workspace lockfile is at the repository root. Packages require Dart >=3.6.0. CI uses Dart 3.13.7.

```sh
dart pub get --enforce-lockfile
dart format .
python3 tool/generate_fixtures.py --verify
for package in sqlite_plus sqlite_plus_orm sqlite_plus_generator; do
  (cd packages/$package && dart analyze --fatal-infos && dart test) || exit
  (cd packages/$package/example && dart analyze --fatal-infos && dart test && dart run bin/main.dart) || exit
done
```

The Linux GitHub job runs every `tool/generate_*.py --verify` script. A checksum mismatch fails that job. Those scripts do not execute SQLite in `--verify` mode. The macOS and Windows jobs run format, fatal-info analysis, package tests, and the example project check.

`docs/REFERENCE.md` is the format and SQL reference. `docs/ENGINE_SUPPORT.md` is the current baseline and the planned follow-up. `CHANGELOG.md` records this version.
