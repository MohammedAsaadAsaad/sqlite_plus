# Garden notes

One in-memory FTS5 table. The mapping lives in `lib/garden_notes.dart`. It uses [`sqlite_plus_orm`](../../sqlite_plus_orm) for the table and [`sqlite_plus_arabic`](../) for the stemmer. The engine underneath is [`sqlite_plus`](../../sqlite_plus).

`Note` has a generated `rowid` and a `body`. The entity is `DbModules.fts5` with `ArabicTokenizers.arabic`. Those two constants are the strings `'fts5'` and `'arabic'`.

`runGardenNotes` does five steps:

1. `MutableDatabaseConnection.openMemory` opens an empty database.
2. `SqlitePlusArabic.register(connection.database)` installs the tokenizer on that connection.
3. `ensureCreated` writes `tokenize = 'arabic'` into the virtual table.
4. Two notes are saved: `في الحديقة` and `كتاب بعيد`.
5. `search('الحديقة')` reads one row. `search('سيارة')` reads none. A second `plan()` is empty.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

```text
في الحديقة | missed true | stable true
```

`في الحديقة` is `found`, the body returned by `search('الحديقة')`. The article `ال` is removed and the suffix `ة` is removed, so the query and the stored sentence share the token `حديق`. `missed true` means `search('سيارة')` returned an empty list. `كتاب بعيد` stays in the table. It does not match `سيارة`. `stable true` means the migration plan after the save is empty, so the stored `CREATE` still matches the mapping.

The package README walks through the same stemmer with SQL, a generated class, and the words `الله` and `كتابه`.
