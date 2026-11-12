# Changelog

## Unreleased

- Require `sqlite_plus` ^0.1.14. The library behavior stays the 0.1.6 release until this package's own version changes.

## 0.1.6

Depends on `sqlite_plus` ^0.1.13. The library behavior is the 0.1.5 release.

## 0.1.5

Depends on `sqlite_plus` ^0.1.12. The README opens `garden.db` with `openFileImage`. The library behavior is the 0.1.4 release.

## 0.1.4

Depends on `sqlite_plus` ^0.1.11. The library behavior is the 0.1.3 release.

## 0.1.3

Depends on `sqlite_plus` ^0.1.9. The README opens on the stemmer. The library behavior is the 0.1.2 release.

## 0.1.2

Depends on `sqlite_plus` ^0.1.8.

`ArabicText.normalize` folds Arabic text without registering an FTS tokenizer. It removes a wider diacritic range than the tokenizer, folds Arabic-Indic digits, and can fold ya and hamza. `stem: true` runs the existing light stemmer on Arabic runs only, so Greek, CJK, and other letters stay in the string. `ArabicTokenizer` and `tokenize = 'arabic'` are unchanged.

## 0.1.1

Depends on `sqlite_plus` ^0.1.7. The stemmer is unchanged. The README links the other packages on pub.dev and shows a short example of each.

## 0.1.0

Light Arabic FTS5 tokenizer named `arabic`.

- `SqlitePlusArabic.register` accepts a `SqliteDatabase`, a `MutableSqliteDatabase`, or the connection's `SqlFunctionRegistry`.
- `ArabicTokenizers.arabic` is the string `'arabic'`.
- Diacritics and tatweel are removed. Alef variants, alef maksura, ئ, and ؤ fold. One prefix and one suffix are removed when three letters remain. `الله` stays `الله`. `حديقة` and `الحديقة` share a token.
- Token text uses one Dart code unit per UTF-8 byte, the same representation as the engine's `unicode61` tokenizer.
- An ORM table uses `DbModules.fts5` and `ArabicTokenizers.arabic`. `search` finds the stemmed word.
- This is not the SQLite ICU Arabic tokenizer.
