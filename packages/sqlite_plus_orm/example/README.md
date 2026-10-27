# Reading log

A tracked reading log for sqlite_plus_orm. The application names fields. The runtime writes the SQL.

Two books go into an in-memory context. Renaming one increments its revision. The other stays at revision `0`. A save with nothing dirty returns `0`. The renamed book is then read by title and by a JSON shelf path.

| Call | What it does | Result |
|---|---|---|
| `books.add` twice, then `saveChanges` | Inserts both rows in one transaction | `2` |
| Assign `title`, then `saveChanges` | Updates one tracked object and increments `@DbVersion` | `1`, revision `1` |
| `saveChanges` again | Finds no dirty objects | `0` |
| `title.eq(...) & MappedField.at(r'$.shelf')` | Binds the title and the JSON path | `Kept Garden Revised` on `north` |
| The same path with `south` | Reads the untouched row | `Other Atlas` at revision `0` |
| `migrations.plan` a second time | Compares the live schema with the model | empty |

The mapping is hand-written in `lib/reading_log.dart`: `Column` codecs, a version column with a write setter, and `EntityType.create`. `MutableDatabaseConnection.openMemory` supplies the database. `DbContext` owns the identity map and the transaction.

This example is its own Dart project and a workspace member. It stays in the repository. Publication of the packages is planned.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

`bin/main.dart` prints the log. `test/reading_log_test.dart` expects revision `1` for the renamed book, revision `0` for the other, one match, an idle save of `0`, and an empty second plan.

The program prints:

```text
Kept Garden Revised on north, revision 1; Other Atlas stays at revision 0; 1 match; idle save 0
```

Relationships, `applySafe`, and reviewed renames are in the [package README](../README.md). Generated `filter`, `path`, `search`, and `bounds` are in the [generator example](../../sqlite_plus_generator/example).
