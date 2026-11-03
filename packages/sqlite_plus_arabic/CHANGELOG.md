# Changelog

## 0.1.0

Light Arabic FTS5 tokenizer named `arabic`.

- `SqlitePlusArabic.register` accepts a `SqliteDatabase`, a `MutableSqliteDatabase`, or the connection's `SqlFunctionRegistry`.
- `ArabicTokenizers.arabic` is the string `'arabic'`.
- Diacritics and tatweel are removed. Alef variants, alef maksura, ئ, and ؤ fold. One prefix and one suffix are removed when three letters remain. `الله` stays `الله`. `حديقة` and `الحديقة` share a token.
- Token text uses one Dart code unit per UTF-8 byte, the same representation as the engine's `unicode61` tokenizer.
- An ORM table uses `DbModules.fts5` and `ArabicTokenizers.arabic`. `search` finds the stemmed word.
- This is not the SQLite ICU Arabic tokenizer.
