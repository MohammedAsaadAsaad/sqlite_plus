# Integration strategy (inspection milestone)

## Repository findings

The root README, MASTER_SPEC, implementation plan, development log and compatibility
matrix require a pure-Dart runtime and honest, incremental compatibility claims.
All six packages' manifests and public entrypoints were inspected. Engine, ORM,
Arabic, vec and geo target Dart >=3.6; the generator currently needs >=3.11.
The workspace uses pub workspaces and test/lints. CI runs Linux, macOS and Windows
package matrices plus examples; browser smoke tests are separate.

- `sqlite_plus`: `MutableSqliteDatabase`, `openInMemory`, bound `query`/`execute`,
  SQL transactions/savepoints, image export/reopen, FTS5 MATCH and bm25,
  custom `FtsTokenizerRegistry`, row triggers and schema PRAGMAs are public.
  External-content FTS stays stale until explicitly maintained; it does not
  automatically synchronize arbitrary application tables.
- `sqlite_plus_arabic`: `ArabicTokenizer` and `SqlitePlusArabic.register` implement
  a fixed light stemmer. Token text is UTF-8 bytes represented as Dart code units.
  Its scanner recognizes Arabic/ASCII, so it cannot be the general Unicode analyzer.
  `ArabicText.normalize` is the shared fold and optional stem for mixed text.
- `sqlite_plus_vec`: `SqlitePlusVec.register`, `encodeVec`, `decodeVec`,
  `vecDistance`, and `rankVec0`. vec0 is an exact float32 scan, not ANN. MATCH
  requires k in 1..100000 and applies that limit before a later SQL predicate.
  `rankVec0` scores only the requested row ids, in pages, with no `k` cutoff.
- ORM exposes typed search/nearest, schema migrations and connection ownership;
  generator emits these helpers. Neither is needed for a raw-table search API.
  Geo is unrelated and will not become a dependency.

## Planned data flow

Application table -> transactional trigger change log -> persistent derived FTS
and vector indexes -> SQL-filtered eligible IDs -> independent keyword/vector
rankings -> reciprocal rank fusion -> bounded collection-local reranker.
Application records remain in their own table. Derived token/vector data and
metadata live in reserved search tables. Identifiers must be quoted and validated;
filter values are always bound. Plain search input must be quoted as FTS terms,
never interpreted as arbitrary MATCH syntax.

Use a stable internal integer ID mapping for arbitrary source primary keys. Store
schema signature, analyzer version, embedding model ID/dimensions and generation
with each collection. Build a new generation in a transaction and publish only
when complete. Reject incompatible schema/model changes and offer explicit rebuild.
Recover by retaining the prior generation and replaying the durable change log.

## Synchronization and concurrency

Triggers record insert/update/delete in the same source transaction, including
old and new IDs for primary-key changes. Rollback therefore rolls back pending
work. Embeddings cannot run inside synchronous SQL triggers; process pending work
before a search, atomically publishing all derived changes and acknowledging only
processed log entries. Require serialized ownership of the connection during this
operation; SQL statement serialization alone is insufficient for a multi-statement
transaction. ORM owner-isolate adapters need a separate integration contract.
Do not promise instantaneous vector synchronization before the drain completes.

## Embeddings and learning

A provider declares a stable model/version ID, dimensions and local execution.
Validate finite, nonzero vectors and dimensions at the boundary. No provider means
semantic/hybrid mode fails explicitly. The deterministic fixture provider tests
plumbing only; no built-in production runtime or cross-language semantic claim.
There is no model download, HTTP client, telemetry, or embedding-weight training.

Persist a versioned, bounded linear reranker per collection. Explicit labels train
only recorded features for that collection/search/document. Cap updates and stored
history, expire feedback contexts, validate imports atomically, and expose reset,
export/import. Evaluate held-out Recall@10, MRR and NDCG@10 before/after training.
Pagination sorts by score then stable ID and is stable only within an unchanged
index/model generation; a future cursor should encode that generation.

## Current implementation versus target

The implemented facade accepts MutableSqliteDatabase directly, queues facade calls
per database and rejects existing transactions. It uses versioned collection
metadata plus derived per-collection key, FTS, vec0 and pending-event tables.
Embeddings are the vec0 shadow rows. Search calls `rankVec0` for eligible internal
ids and does not keep a second vector table or a second cosine loop. `MATCH` plus
`k` is not used, because that limit is applied before a filter. Unfiltered
ranking reads the shadow in stopped rowid pages of 512. Initial index writes are
batched in groups of 1000. Each source page is a stopped rowid window, so the
read does not scan the whole source table again for every page.
Incremental replay coalesces source keys, atomically replaces their derived
entries and acknowledges only captured event IDs. Embedding failure rolls
everything back. Explicit rebuild resets ranking weights/context.

The analyzer interface supports application-supplied language/synonym processing.
The built-in normalizer calls `ArabicText.normalize` and then unicode61 through
FTS5. Optional stemming covers Arabic runs only. It does not implement
morphological or semantic language analysis.

Feedback persists two clamped logistic-gradient weights over reciprocal ranks.
Score adjustment is capped by 0.25 times maximum base-score magnitude per feature;
context retention is 1000 returned hits across this database. Search IDs come from
a persistent counter. Only returned search/document contexts accept one label.

Generation-pinned cursors, comprehensive corruption diagnosis, physical crash
injection, an owner-isolate adapter, production embeddings and scale optimization
are future gates. Explicit rebuild uses one transaction rather than two concurrently
published index generations. No claim of these target designs is implied.

## Development index format 3

Format 3 stores normalized content in the owned key table, builds one
external-content FTS index after batches of 1000 derived rows, and stores each
embedding as a `vec0` row in the same database. This avoids a parallel vector
table. The engine's external-content loader currently maps columns positionally,
so the owned key table deliberately puts body immediately after the integer
rowid alias; native SQLite also finds the correct named body column. Application
table column order is unrestricted. Opening a database does not rebuild this
index. Format 2 and earlier development indexes are rejected until `indexTable`.

Incremental replay replaces an existing FTS/vector row once rather than deleting
and reinserting it, and uses typed primary-key equality for common INT/TEXT keys.
When that FTS statement is an external-content replace of explicit row ids and
the new leaf fits, the engine edits that leaf, the averages row, and that
document's docsize row. Other FTS shapes rebuild the postings. Ordinary writes
publish changed rowid tables without rebuilding untouched tables. A new unique
key whose rowid is past the current maximum is appended, and that key is
inserted into the unique index. Other unique-key shapes still rebuild the image.
Empty tables, empty indexes, views, and triggers are appended to the schema leaf
when the new row fits. Triggers maintain a census. When it matches `count(*)`,
replay reads only the pending keys. A mismatch still scans mapping and source
IDs so a REPLACE that deletes an unlogged row is reconciled. The integrity
baseline is version 2, an order-independent sum of per-row hashes. That replay
adjusts the changed key, docsize, and vector rows and rehashes the other owned
shadows. `verifyIndex` still reads every derived row. The census is not hashed.
`synchronize` exposes replay without query ranking so benchmark timings separate
source update, replay and query cost. Single-token AND/OR `MATCH` can score
from postings and docsize. On the all-matching benchmark corpus that path did
not move warm query time out of the earlier format 3 range.

Format 2 and earlier development indexes are rejected until the caller
explicitly rebuilds with indexTable. Source records are never migrated or
rewritten.
