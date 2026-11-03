# sqlite_plus_arabic

A light Arabic stemmer for FTS5. Register it on the connection, then create the table with `tokenize = 'arabic'`.

```yaml
dependencies:
  sqlite_plus_arabic: ^0.1.0
```

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';

final db = await openInMemory();
SqlitePlusArabic.register(db);
await db.execute(
  "CREATE VIRTUAL TABLE docs USING fts5(body, tokenize = 'arabic')",
);
```

`ArabicTokenizers.arabic` is the string `'arabic'`. Diacritics and tatweel are removed. Alef variants fold to ا, alef maksura and ئ fold to ي, and ؤ folds to و. One prefix is removed when three letters remain: وال، بال، كال، فال، لل، ال. One suffix is then removed on the same condition: يات، ون، ين، ات، ان، ها، ية، يه، ه، ة، ي. A word that starts with one of those prefixes, and would have fewer than three letters left, keeps its suffix too, so `الله` stays `الله`. `حديقة` and `الحديقة` share a token. ASCII letters are lowercased and are not stemmed. This is not a morphological analyzer and it is not the SQLite ICU Arabic tokenizer.

The same name works on a mapped table. The ORM stores the string. This package supplies the stemmer.

```dart
import 'package:sqlite_plus_arabic/sqlite_plus_arabic.dart';
import 'package:sqlite_plus_orm/sqlite_plus_orm.dart';

@DbEntity(module: DbModules.fts5, tokenizer: ArabicTokenizers.arabic)
class Note {
  Note({this.rowid, required this.body});
  @DbKey(generated: true)
  final BigInt? rowid;
  final String body;
}
```

```dart
SqlitePlusArabic.register(connection.database);
await context.migrations.ensureCreated();
final found = await notes.query.search('الحديقة').toList();
```

Register the tokenizer before `ensureCreated` or `search`. A second `register` replaces the factory. Reopening an image needs another `register` on that connection. `search('سيارة')` does not return a garden note.

[`sqlite_plus`](../sqlite_plus) stores the index. [`sqlite_plus_orm`](../sqlite_plus_orm) writes `tokenize = 'arabic'` from [DbModules.fts5] and the tokenizer string. [`sqlite_plus_generator`](../sqlite_plus_generator) emits that string and `search`. The generated part does not import this package.
