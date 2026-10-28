# Reading log

A tracked reading log for sqlite_plus_orm. The application names fields. The runtime writes the SQL.

| Call | What it does | Result |
|---|---|---|
| `books.add` twice, then `saveChanges` | Inserts both rows in one transaction | `2` |
| Assign `title`, then `saveChanges` | Updates one object and increments the revision | `1`, revision `1` |
| `saveChanges` again | Finds no dirty objects | `0` |
| `title.eq(...) & MappedField.at(r'$.shelf')` | Binds the title and the JSON path | `Kept Garden Revised` on `north` |
| The same path with `south` | Reads the untouched row | `Other Atlas` at revision `0` |
| `migrations.plan` a second time | Compares the live schema with the model | empty |

| File | Role |
|---|---|
| `lib/reading_log.dart` | Columns, version setter, `EntityType`, save, and filter |
| `bin/main.dart` | Prints the line below |
| `test/reading_log_test.dart` | Checks revision `1`, revision `0`, one match, idle `0`, empty plan |

`MutableDatabaseConnection.openMemory` supplies the database. `DbContext` owns the identity map and the transaction.

This example ships with the package.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

```text
Kept Garden Revised on north, revision 1; Other Atlas stays at revision 0; 1 match; idle save 0
```

Relationships and reviewed renames are in the [package README](../README.md).
