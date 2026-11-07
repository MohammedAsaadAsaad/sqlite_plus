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
  The source read is a stopped rowid window of 1000 rows. Keyword search loads
  `MATCH` hits, then resolves those ids with one primary-key probe. Semantic
  search asks `rankVec0` for the eligible ids. Unfiltered ranking scans the
  shadow in stopped pages. Filtered ranking passes only the eligible ids. It
  does not keep a Dart list of every decoded embedding. The 2026-11-05 append
  run completed 1000 records in 0.300666 s of indexing, 10000 in 4.704192 s,
  and 100000 in 75.807267 s. At 10000 records that run recorded source update
  alone at 35.599 ms and synchronization at 1.699659 s. The 1,000,000 run
  exited 255 after 2914 seconds and wrote no result, so it has no timings.
  The separate catalog keyword sample is in the package README: 20,000 product
  names, Linux x64 AOT, and one arm64 phone at 47.236 ms. See benchmark/RESULTS.md.
- With autoUpdate, search replays the transactional trigger log. Without it, explicit
  rebuild is required after edits. Replay only regenerates changed embeddings and uses typed equality for common
  INT/TEXT keys. When the trigger census matches `count(*)`, only pending keys
  are read. A census mismatch, including a REPLACE that deletes an unlogged row,
  still scans mapping and source keys. A one-row external-content replace edits
  that row's leaf when the new leaf fits. The stored fingerprint is version 2.
  A matching sync adjusts the changed key, docsize, and vector hashes and
  rehashes the other owned shadows. `verifyIndex` still reads every derived row.
  A version 1 baseline fails until an explicit rebuild. A new unique key past
  the current maximum is appended; other unique-key shapes still rebuild the
  image. The measured sync still rewrites the derived row and, on this corpus,
  compacts the image. It is not a large-scale indexing path.
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

## Optional fuzzy fallback

Fuzzy candidate discovery scans all normalized derived text in pages and retains
the distinct vocabulary in memory per fallback. Expansion is capped per token
before filtering, so filtered alternatives can be omitted. Unicode lexical runs
are used for candidates; custom query syntax/analyzers require integration tests.
Final ranking is BM25/RRF, not edit-distance ranking. Only filtered keyword
hits covering every lexical query token suppress fallback. Fuzzy-enabled queries
use AND across tokens and OR across alternatives for each token; non-fuzzy queries
retain the analyzer's existing expression behavior. No persistent
fuzzy index, morphology, phonetic matching or large-corpus latency guarantee.

## Learned fuzzy alternatives

Optional learnAfter stores observation rows even before promotion; candidate lists
are stored only at the threshold. No eviction policy or hard total-entry cap.
All query tokens need ready entries to avoid discovery scanning. Changing fuzzy
settings/threshold uses a separate learning key. Rebuild or autoUpdate replay
invalidates collection learning. verifyIndex does not fingerprint learning rows.
Applications exporting images must persist learning changes explicitly.

## Optional precision ranking

Keyword mode only. All matching candidates are classified before pagination, so
CPU/memory grows with result count and text size; there is no constant-latency
promise or top-candidate truncation. Field weights affect normalized token
coverage within precision tiers, not native per-field BM25. Scores remain base
scores. Query processing is literal/analyzer-normalized; special MATCH overrides
need integration tests. No precision index is stored.
