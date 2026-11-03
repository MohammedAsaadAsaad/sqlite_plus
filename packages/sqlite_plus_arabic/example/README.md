# Garden notes

One in-memory FTS5 table with the Arabic light stemmer.

| Step | Call | Result |
|---|---|---|
| Register | `SqlitePlusArabic.register` | Tokenizer name `arabic` |
| Create | `ensureCreated` with `DbModules.fts5` | `tokenize = 'arabic'` |
| Save | two notes | `في الحديقة` and `كتاب بعيد` |
| Search | `search('الحديقة')` | `في الحديقة` |
| Miss | `search('سيارة')` | no row |

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

```text
في الحديقة | missed true | stable true
```
