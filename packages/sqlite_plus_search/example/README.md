# Clinic shelf

One in-memory database. The walk lives in `lib/clinic_shelf.dart`. It uses [`sqlite_plus_search`](../) on [`sqlite_plus`](../../sqlite_plus).

`runClinicShelf` does six steps:

1. A pharmacy note stores `حَلِيب` with a diacritic. The query is `حليب`, and `shelf = ?` keeps the other room out.
2. The same query without that filter also returns the note outside the pharmacy.
3. `mint tea` is inserted after `indexTable`. `autoUpdate` makes it visible.
4. `stemArabic: true` lets `حديقة` find `الحديقة`.
5. Hybrid ranking uses `FixtureEmbeddingProvider`, an exact string map. `fresh milk` is a key.
6. `coffee` is not a key, so semantic search throws instead of pretending the keyword hits are vectors.

From a checkout, after `dart pub get` at the repository root:

```sh
dart run bin/main.dart
```

```text
Pharmacy notes for حليب: 1
Every note for حليب: 1, 3
Tea inserted after the index: 4
Stemmed حديقة: 1
Hybrid 1  keyword 1.0  vector 1.0
Hybrid 3  keyword 2.0  vector 2.0
Hybrid 2  keyword null  vector 3.0
Unknown fixture query rejected: true
```

The package README records the 20,000-name catalog and walks the same shelf in shorter form. The fixture is not a language model.
