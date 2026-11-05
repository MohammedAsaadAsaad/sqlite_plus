# sqlite_plus_search (Phase 1 development)

Pure Dart, offline search over existing sqlite_plus tables. Keyword search with
Arabic normalization, engine Unicode tokenization and BM25 is implemented.
Persistent derived indexes support explicit atomic rebuilds and schema/analyzer
change detection. The complete Phase 1 search engine is still under construction.

```dart
import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:sqlite_plus_search/sqlite_plus_search.dart';

final db = await openInMemory();
await db.execute('CREATE TABLE products(id INTEGER PRIMARY KEY, name TEXT)');
await db.execute('INSERT INTO products VALUES (?, ?)', [1, 'حَلِيب milk']);
final search = await SqlitePlusSearch.open(database: db);
await search.indexTable(
  table: 'products', primaryKey: 'id', textColumns: ['name'],
);
final results = await search.search('حليب', table: 'products');
print(results.hits.single.documentId); // 1
```

`SearchFilter('category = ?', ['baby'])` binds filter values against the original
table. SQL predicates are trusted developer code. Results have a larger-is-better
score and deterministic ID tie ordering. Offset/limit apply after filtering.
Ordering is stable only while source/index state stays unchanged. Indexes persist
in the caller's database image/backend; this package does not save files itself.
The caller keeps ownership of the database. Do not interleave outside database
operations while facade operations run, or invoke them in an application transaction.
Source tables need a single text or integer primary key. Indexed values are text
or null. `_sps_` tables are reserved derived index/metadata storage.

Pass `autoUpdate: true` to record inserts/updates/deletes with transactional
triggers. Each search replays pending changes atomically, including embeddings.
Provider failure preserves the change log for retry. Without autoUpdate, call
`indexTable` again after source edits to rebuild explicitly.
Normalization options must match indexing; changes require explicit rebuild.
`SearchTextAnalyzer` calls `ArabicText.normalize`. `stemArabic: true` stems Arabic runs with the existing light stemmer and leaves Greek, CJK, and other letters in the string. The search FTS table stays `unicode61`.

Implement `LocalEmbeddingProvider` for an already provisioned local model.
`validatedEmbedding` rejects invalid vectors using sqlite_plus_vec codecs.
`FixtureEmbeddingProvider` is an exact lookup for tests, with no language
understanding. Use `mode: SearchMode.semantic` or `SearchMode.hybrid` with an indexed provider.
Hybrid uses Reciprocal Rank Fusion; `explain: true` includes component ranks.
A missing or incompatible provider fails explicitly. No models are
downloaded and there is no network/telemetry code. Provider implementations must
honor the local-only contract; Dart cannot sandbox arbitrary application code.

See [architecture](doc/ARCHITECTURE.md), [status](doc/IMPLEMENTATION_PLAN.md),
[limitations](doc/LIMITATIONS.md). Run `dart test` or `dart run example/main.dart`
from this package. Cross-language semantic model tests and benchmarks are pending.

Enable local learning with `learning: const AdaptiveLearningConfig(enabled: true)`
on open. Label a returned hit with
`search.feedback.submit(searchId: results.searchId, documentId: '1', relevance: Relevance.high)`.
`Relevance.low` supplies negative feedback. Two bounded weights adjust reciprocal
keyword/vector rank features. Each returned search/document pair accepts one label;
the latest 1000 hit contexts are retained. Models are scoped to each table, persisted
in SQLite and reset by explicit rebuild. Use `feedback.reset(table: ...)`,
`exportModel(table: ...)`, and `importModel(table: ..., model: ...)` for management.
Imports require matching collection, analyzer, embedding identity and model version.
`evaluateRanking` provides Recall@k, reciprocal rank and NDCG@k for application
judgments. Synthetic training-fixture improvements do not establish held-out quality.

For language-specific analyzers or synonym dictionaries, extend `SearchAnalyzer`
and supply `normalize` and a stable `signature` including the dictionary revision.
The default literal MATCH builder is inherited. The same analyzer processes
indexed documents and queries; change its signature whenever its rules change,
then rebuild. Custom analyzer/provider code must be deterministic and local.

Current release gates: production embeddings, large-scale performance, broader
corruption/concurrency coverage and platform verification. Format 3 was checked
on the Linux VM. The format 2 suite also passed in GitHub Actions on macOS and
Windows. Real browser persistence was not run. See
[limitations](doc/LIMITATIONS.md) and
[actual benchmark results](benchmark/RESULTS.md) before adoption. The benchmark
file is the format 2 measurement.

Call `await search.verifyIndex(table: 'products')` for an explicit read-only
corruption diagnostic. SHA-256 covers derived records, schema, metadata and
trigger definitions; pending source edits are allowed. Verification scans the
index and throws `StateError` on a mismatch. Recover with explicit `indexTable`.
A checksum is not protection against a malicious database writer who can also
replace the baseline. Missing baselines on older development indexes require rebuild.

`await search.synchronize(table: 'products')` applies pending changes without
ranking a query. Development index format 3 stores vectors in a `vec0` table in
the same database and builds external-content FTS once after loading normalized
derived content. `open` creates metadata tables only. It does not rebuild an
index that is already in the file. Format 2 and earlier development indexes are
rejected until `indexTable`. Application records remain unchanged. Semantic and
hybrid ranking call `rankVec0` for the eligible source rows, so `k` is not
applied before the filter. Keyword `MATCH` is read from the FTS table on its
own; joining that virtual table currently returns no rows in this engine.
