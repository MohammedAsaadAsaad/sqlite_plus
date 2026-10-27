# Generated library

A customer, a purchase, a JSON note, an FTS5 article, and an R-tree place, mapped by `sqlite_plus_generator` and saved through `sqlite_plus_orm`. The application calls the ORM only.

`lib/models.dart` declares the five classes. One generator run writes `lib/models.orm.g.dart`, which is checked in. `lib/library_app.dart` opens memory, calls `ensureCreated`, and saves ten rows.

| Generated call | Stored rows | Result |
|---|---|---|
| `filter((row) => row.total > 20.0)` and `orderByFields` | purchases `22.5`, `4`, `30` | `[22.5, 30.0]`, count `2` |
| `path(r'$.title').equalTo('kept')` | notes `kept` and `other` | `{"title":"kept"}` |
| `search('kept')` | articles `alpha kept` and `beta lost` | `alpha kept` |
| `bounds.intersects` on the unit box | places `1` and `2` | place `1` of `2` |
| `reference(...).load()` | purchase linked to customer `Ada` | `Ada` |
| `migrations.plan` a second time | schema already matches `generatedModel` | empty |

`Customer` uses a generated `BigInt` key and `@DbVersion`. `Purchase.customerId` becomes `PurchaseRelationships.customer`. `Note.document` carries `@DbJson`. `Article` is `@DbEntity(module: 'fts5')` with a `rowid` key. `Place` is `@DbEntity(module: 'rtree')` with an integer key and four doubles.

This example is its own Dart project and a workspace member. It stays in the repository. Publication of the packages is planned.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run sqlite_plus_generator --input lib/models.dart --check
dart run bin/main.dart
```

`--check` compares the part with the file on disk. `bin/main.dart` prints the library. `test/library_app_test.dart` expects Ada, the two totals, the kept note, the FTS body, and place `1`.

The program prints:

```text
Ada bought [22.5, 30.0]; {"title":"kept"}; alpha kept; place 1 of 2
```

The generator conventions, the CLI, and the diagnostics are in the [package README](../README.md).
