# sqlite_plus_search

Offline search for rows that already live in a [sqlite_plus](https://pub.dev/packages/sqlite_plus) database. The index sits in that same database. Keyword search is BM25 over packed FTS5 leaves. This package does not download a model and does not send text anywhere.

```yaml
dependencies:
  sqlite_plus: ^0.1.9
  sqlite_plus_search: ^0.1.0-dev.5
```

`0.1.0-dev.5` is a pre-release. The clinic shelf below is the example. The catalog measurement is at the end. Embeddings stay a local fixture you supply. The limits are in [doc/LIMITATIONS.md](doc/LIMITATIONS.md).

## Clinic shelf

`حَلِيب` is stored with a diacritic. The query is `حليب`. The pharmacy filter is your SQL, with the value bound. `شاي أخضر` stays out of that result. `mint tea` is inserted after `indexTable` and is found on the next search.

```dart
import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

final file = File('clinic.db');
final db = file.existsSync()
    ? await MutableSqliteDatabase.fromImage(await file.readAsBytes())
    : await MutableSqliteDatabase.create();
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
await file.writeAsBytes(db.exportImage(), flush: true);
```

![The note is written to clinic.db and read back from that file.](doc/shelf-file.png)

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

See [architecture](doc/ARCHITECTURE.md), [status](doc/IMPLEMENTATION_PLAN.md), and [limitations](doc/LIMITATIONS.md). The catalog numbers above are keyword search on packed leaves. The synthetic embedding harness recorded a later append run: 10,000 documents indexed in 4.704192 s and one change synchronized in 1.699659 s. Those files are in the repository benchmark results. That harness is not a language model.

## Twenty thousand names

A page loads 20 names out of the full hit count. The time on the line is that search.

The catalog holds 10,000 Arabic product names and 10,000 English product names. On one arm64 phone, release build 0.5.2, `بسكويت` read `20 of 493 matches · 47.236 ms`. That was page 1 of 25. The keyword score on those titles was 3.965.

![Page time for the Arabic query before and after packed leaves.](doc/search-compare.png)

![Catalog on one arm64 phone. Twenty of 493 matches in 47.236 ms.](doc/catalog-phone.jpg)

The same lists on Linux x64, Dart 3.13.7, AOT, and not a phone:

| Query | Page of 20 | Offset 320 | Raw `MATCH` |
|---|---:|---:|---:|
| `بسكويت` | 26.967 ms, then 20.819 ms | 25.663 ms | 18.861 ms |
| `biscuit` | 19.717 ms, then 25.481 ms | 25.621 ms | 20.249 ms |

Each of those queries returned 493 hits. Indexing took 46.880 s. The image was 3,387,392 bytes and held 347 leaves. Pinned SQLite 3.53.1 opened that image: `integrity_check` returned `ok`, and both queries returned 493 rows.

Before the leaves were packed, that Linux process took 405 ms and then 359 ms. The previous phone build showed 472.000 ms for page 17 of `بسكويت`. Those searches read one leaf per product.

A query of whole terms reads the leaves that contain those terms, plus one document-length blob. One document keeps the older leaf. An index that still has one leaf per product searches as before. Rebuild it to pack the leaves.

| Package | Version | Page |
|---|---|---|
| sqlite_plus | `^0.1.9` | <https://pub.dev/packages/sqlite_plus> |
| sqlite_plus_arabic | `^0.1.3` | <https://pub.dev/packages/sqlite_plus_arabic> |
| sqlite_plus_vec | `^0.1.3` | <https://pub.dev/packages/sqlite_plus_vec> |
