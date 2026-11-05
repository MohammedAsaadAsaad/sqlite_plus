# sqlite_plus_search

Offline search for rows that already live in a [sqlite_plus](https://pub.dev/packages/sqlite_plus) database. The index sits in that same database. This package does not download a model and does not send text anywhere.

The first example is a clinic shelf. A stored note can contain Arabic diacritics, a query without them still finds it, and a bound `shelf` predicate keeps the other rooms out. A later insert is visible because `autoUpdate` was on. A second scene turns on the light Arabic stemmer. A third scene shows hybrid ranking with an exact string-to-vector map, then shows that a missing string fails.

This is a development release, `0.1.0-dev.3`. It is not a production embedding runtime. The limits are in [doc/LIMITATIONS.md](doc/LIMITATIONS.md).

| Package | Version | Page |
|---|---|---|
| sqlite_plus | `^0.1.7` | <https://pub.dev/packages/sqlite_plus> |
| sqlite_plus_arabic | `^0.1.2` | <https://pub.dev/packages/sqlite_plus_arabic> |
| sqlite_plus_vec | `^0.1.2` | <https://pub.dev/packages/sqlite_plus_vec> |

## Clinic shelf

`حَلِيب` is stored with a diacritic. The query is `حليب`. The pharmacy filter is your SQL, with the value bound. `شاي أخضر` stays out of that result. `mint tea` is inserted after `indexTable` and is found on the next search.

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

final db = await openInMemory();
await db.execute(
  'CREATE TABLE notes(id INTEGER PRIMARY KEY, shelf TEXT NOT NULL, body TEXT)',
);
await db.execute(
  "INSERT INTO notes VALUES (1, 'pharmacy', 'حَلِيب للأطفال')",
);
final search = await SqlitePlusSearch.open(database: db);
await search.indexTable(
  table: 'notes',
  primaryKey: 'id',
  textColumns: ['body'],
  autoUpdate: true,
);
final pharmacy = await search.search(
  'حليب',
  table: 'notes',
  filter: SearchFilter('shelf = ?', ['pharmacy']),
);
print(pharmacy.hits.single.documentId); // 1
```

`SearchFilter` is trusted SQL. Put user text in the parameter list, not in the string. Do not add `WHERE`, `ORDER BY`, or `LIMIT`. The source table needs one non-null text or integer primary key. Indexed values are text or null. Names starting with `_sps_` are reserved for the derived index.

Keyword scores are larger-is-better. They are the engine BM25 value with the sign flipped. `limit` and `offset` apply after the filter. Order is stable only while the rows and the index stay still.

Run the whole walk, including the stem and the fixture:

```text
cd packages/sqlite_plus_search/example && dart run bin/main.dart
```

## Arabic stemming

The default analyzer folds diacritics and leaves words whole. `stemArabic: true` runs the light stemmer from [sqlite_plus_arabic](https://pub.dev/packages/sqlite_plus_arabic) on Arabic runs only, so `حديقة` finds `الحديقة`. Greek and CJK letters stay in the string. This is not the ICU Arabic tokenizer and not a morphological analyzer.

Use the same analyzer for indexing and for queries. If the signature changes, call `indexTable` again.

```dart
final search = await SqlitePlusSearch.open(
  database: db,
  analyzer: const SearchTextAnalyzer(stemArabic: true),
);
```

## A vector beside the words

`SearchMode.hybrid` mixes the keyword order with a vector order. You supply the vectors through `LocalEmbeddingProvider`. The provider must be local: no download and no network during `embed`.

`FixtureEmbeddingProvider` is a lookup table for tests and for this example. It returns a vector only when the string is one of its keys. `fresh milk` is a key, so the query works. `coffee` is not, so semantic search throws `StateError` instead of pretending the keyword result is a vector result.

```dart
final fixture = FixtureEmbeddingProvider(
  modelId: 'clinic-fixture-v1',
  dimensions: 2,
  vectors: {
    'fresh milk': [1, 0],
    'green tea': [0, 1],
    'milk powder': [0.8, 0.2],
  },
);
final search = await SqlitePlusSearch.open(
  database: db,
  embeddingProvider: fixture,
);
final hits = await search.search(
  'fresh milk',
  table: 'drinks',
  mode: SearchMode.hybrid,
  explain: true,
);
```

`explain: true` adds `keywordRank`, `vectorRank`, `baseScore`, `keywordWeight`, and `vectorWeight`. The fixture does not know that milk and tea are drinks. A real `LocalEmbeddingProvider` replaces that map with an already installed local model. Changing `modelId` or the dimension count requires `indexTable` again.

`embedding MATCH ? AND k = ?` is a different `sqlite_plus_vec` query. Search does not use it. Filtered ranking asks `rankVec0` for the eligible row ids, in pages of 512, so `k` is not applied before the filter. An unfiltered ranking scans the shadow in those same stopped pages.

## What stays in your hands

`open` creates metadata tables. It does not rebuild an index that is already in the file. Format 2 and older development indexes are rejected until you call `indexTable`.

`await search.verifyIndex(table: 'notes')` checks a SHA-256 of the derived rows, schema, metadata, and trigger text. A mismatch throws `StateError`. Rebuild with `indexTable`. A writer who can change both the index and the stored digest is not stopped by this check.

`await search.synchronize(table: 'notes')` applies the pending trigger log without running a query. Do not run other statements on the same database while a search call is in progress, and do not call search inside an application transaction.

`learning: const AdaptiveLearningConfig(enabled: true)` stores a small local weight for one table. Label one returned hit once:

```dart
await search.feedback.submit(
  searchId: results.searchId,
  documentId: '1',
  relevance: Relevance.high,
);
```

Two weights move keyword and vector ranks. They can make ranking worse. The example does not turn learning on. Held-out judgments belong to the application. Synthetic fixtures are not evidence of model quality.

See [architecture](doc/ARCHITECTURE.md), [status](doc/IMPLEMENTATION_PLAN.md), and [limitations](doc/LIMITATIONS.md). Measured Linux timings are in [benchmark/RESULTS.md](benchmark/RESULTS.md). The append run indexed 10,000 synthetic documents in 4.704192 s and synchronized one change in 1.699659 s. Warm keyword time stayed in the earlier range. No general speedup is claimed.
