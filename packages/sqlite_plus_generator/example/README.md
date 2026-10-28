# Generated library

Five classes mapped by `sqlite_plus_generator` and saved through `sqlite_plus_orm`. The application calls the ORM only.

| Class | Marker | Generated call |
|---|---|---|
| `Customer` | `@DbVersion()` | `PurchaseRelationships.customer` |
| `Purchase` | `customerId` | `filter((row) => row.total > 20.0)` |
| `Note` | `@DbJson()` | `path(r'$.title')` |
| `Article` | `@DbEntity(module: 'fts5')` | `search('kept')` |
| `Place` | `@DbEntity(module: 'rtree')` | `bounds.intersects` |

`lib/library_app.dart` saves ten rows: one customer, three purchases, two notes, two articles, and two places.

| Read | Stored rows | Result |
|---|---|---|
| `filter` and `orderByFields` on `total` | `22.5`, `4`, `30` | `[22.5, 30.0]`, count `2` |
| `path(r'$.title').equalTo('kept')` | `kept` and `other` | `{"title":"kept"}` |
| `search('kept')` | `alpha kept` and `beta lost` | `alpha kept` |
| `bounds.intersects` on the unit box | places `1` and `2` | place `1` of `2` |
| `reference(...).load()` | purchase linked to `Ada` | `Ada` |
| `migrations.plan` a second time | schema matches `generatedModel` | empty |

| File | Role |
|---|---|
| `lib/models.dart` | The five classes. Input to the generator |
| `lib/models.orm.g.dart` | Checked-in part |
| `lib/library_app.dart` | Save and the four reads |
| `bin/main.dart` | Prints the line below |
| `test/library_app_test.dart` | Checks Ada, both totals, the note, the article, and place `1` |

This example ships with the package.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run sqlite_plus_generator --input lib/models.dart --check
dart run bin/main.dart
```

```text
Ada bought [22.5, 30.0]; {"title":"kept"}; alpha kept; place 1 of 2
```

CLI flags and field rules are in the [package README](../README.md).
