# Reading log

A tracked reading log for sqlite_plus_orm. The application names fields. The runtime writes the SQL.

| Call | What it does | Result |
|---|---|---|
| `books.add` twice, then `saveChanges` | Inserts both rows in one transaction | `2` |
| Assign `title`, then `saveChanges` | Updates one object and increments the revision | `1`, revision `1` |
| `saveChanges` again | Finds no dirty objects | `0` |
| `row.title.equalTo(...) & row.path(r'$.shelf')` | Binds the title and the JSON path | `Kept Garden Revised` on `north` |
| The same path with `south` | Reads the untouched row | `Other Atlas` at revision `0` |
| `migrations.plan` a second time | Compares the live schema with the model | empty |

| File | Role |
|---|---|
| `lib/reading_log.dart` | The `Book` class. The generator writes `BookMapping` |
| `bin/main.dart` | Prints the line below |
| `test/reading_log_test.dart` | Checks revision `1`, revision `0`, one match, idle `0`, empty plan |

`DbSet.openMemory` opens the database, creates the `books` table, and returns that set. `saveChanges`, `migrations`, and `close` belong to the set. A file uses `DbSet.openDbFile` from the same library. On the Web that call throws `UnsupportedError`. `DbContext` remains available for a connection that already exists.

`lib/shared_shelf.dart` is the other three shapes. `runSharedMemory` stores a book and a note in one memory database. `runFileKeepsRow` closes a file and reads the note back. `runSecondFileOpenRejected` is the second open of that file. `runSecondSaveRejected` is a save that starts while another save is running. `runQueuedQueries` starts two queries on one context, and both return.

This example ships with the package.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

```text
Kept Garden Revised on north, revision 1; Other Atlas stays at revision 0; 1 match; idle save 0
```

Relationships and reviewed renames are in the [package README](../README.md).
