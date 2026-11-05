# Current limitations and release gates

This is a Phase 1 development package, not a completed production release.

## Semantics

No production embedding runtime/model is bundled or automatically downloaded.
All committed vector tests use explicit synthetic lookup fixtures. They establish
vector/hybrid mechanics, not semantic understanding or cross-language retrieval.
Supply a real local provider and run held-out multilingual model integration tests
before making those claims. Missing/incompatible providers fail explicitly.

## Platforms

Dart VM tests and the runnable example pass on Linux. A shared assertion program
runs successfully on the VM and JavaScript compiled for Node 24.19.0, covering
Arabic/English/Greek/CJK, filtered vector retrieval, hybrid ranking, feedback,
transaction rollback, incremental changes and image/model round trips. CI now
executes these assertions rather than only compiling JavaScript. The original
JavaScript FTS insertion failure was traced to a 37-bit bitwise shift and fixed
with exact arithmetic; pinned SQLite comparisons guard the VM format.

This verifies Node execution, not a real browser persistence backend or every
JavaScript numeric boundary. GitHub Actions run 41909170732 on commit `d0b7cbd`
passed the format 2 search tests on Linux, macOS, and Windows. Format 3 was
checked with local `dart test` on Linux. Android, iOS, and a real browser
persistence backend were not run for this change.

## Storage and indexing

- Source must be an ordinary table with one declared nonnull text/integer primary
  key. Composite/blob/implicit keys, attached schemas and owner-isolate ORM adapters
  are unsupported. Dynamic integer/text keys with identical string representations
  are rejected by the mapping uniqueness rule.
- FTS content is derived index text; original application rows are not copied or
  rewritten. Initial normalized-content writes are batched and FTS is built once.
  The source query still materializes. Keyword search loads `MATCH` hits, then
  resolves those ids. Semantic search loads eligible id and source-key pairs and
  asks `rankVec0` for those rows in pages of 64. It does not keep a Dart list of
  every decoded embedding. The hardened format 2 AOT run completed 10000 records
  in 26.93 s of indexing; the 100000-record attempt still timed out during
  indexing at 120 s. That embedding harness was not remeasured for format 3.
  The separate catalog keyword sample is in the package README: 20,000 product
  names, Linux x64 AOT, and one arm64 phone at 47.236 ms. See benchmark/RESULTS.md.
- With autoUpdate, search replays the transactional trigger log. Without it, explicit
  rebuild is required after edits. Replay only regenerates changed embeddings and uses typed equality for common
  INT/TEXT keys. Mapping/source ID reconciliation still scans, and the engine FTS
  writer still rebuilds its physical postings during a row replacement. Incremental
  updates remain costly.
- Replay reconciles missing source keys, including rows displaced by secondary
  UNIQUE conflicts under REPLACE with recursive triggers off. Source schema changes
  and missing triggers fail explicitly. verifyIndex detects changed trigger SQL,
  derived records and metadata; it is an explicit full scan, not a per-query guard.
- Failed rebuild/replay rolls back transactionally, and explicit rebuild recovers
  a damaged mapping. Comprehensive corruption diagnosis, generation-pinned cursors
  and actual device power-loss testing remain open. Storage-operation crash
  injection now covers rebuild/replay/feedback and repeat recovery in redo and
  persist journal modes, including volatile and immediate byte persistence. Backend
  durability remains governed by the engine's storage contract.
- External database operations must not interleave facade operations. The facade
  serializes its own calls per database and rejects active caller transactions;
  it cannot claim an external ORM's lease. Pagination is stable only while source,
  index and ranking model stay unchanged.
- Metadata reads use NOT INDEXED to avoid a reproduced engine stale empty unique
  lookup inside a transaction. A first-build/rebuild regression covers the workaround.

## Relevance and analysis

Learning uses two reciprocal-rank features only. Weights are clamped to [-1,1],
learning rate to (0,0.5], and score adjustment to at most 50% of maximum base-score
magnitude. This can harm relevance: evaluate held-out judgments before enabling it.
Feedback context retention is 1000 returned hits across the database; each accepts
one label. Rebuild resets weights; replay invalidates prior collection contexts.
Embedding weights are never trained. Synthetic ranking improvements include disjoint held-out query/document tests;
they are not real-model semantic quality guarantees.

The built-in analyzer supports the documented Arabic folds and optional light
stemming. It is not a morphological analyzer. Language-specific rules and synonym
dictionaries can be supplied through SearchAnalyzer with versioned signatures;
no built-in language detector or synonym database is bundled.

Hardening adds deterministic replay-versus-rebuild testing, blocked/failing-provider
multi-handle tests, and held-out synthetic queries/documents with a control query.
The latter tests feature preference transfer, not real-model semantic relevance.

Index format 3 requires an explicit rebuild of format 2 and earlier development
indexes. No automatic or destructive migration of source records is performed.
`open` does not rebuild an index that is already stored in the database file.
