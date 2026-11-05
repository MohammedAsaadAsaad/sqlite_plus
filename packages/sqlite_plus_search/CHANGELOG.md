## 0.1.0-dev.3

- The clinic-shelf example shows diacritic folding, a bound shelf filter, an insert picked up by `autoUpdate`, Arabic light stemming, and a hybrid rank explanation.
- `FixtureEmbeddingProvider` in that example is an exact string map. A missing string fails. It is not a language model.
- Keyword and semantic resolution load the source keys and the internal map separately. A correlated `EXISTS` is not used.
- Source indexing reads stopped rowid windows of 1000. Unfiltered `rankVec0` reads stopped shadow pages of 512.
- Non-contentless-delete FTS5 leaves pack many documents. The writer probes leaf length instead of re-encoding after every document.
- A one-row external-content FTS replace edits the leaf that holds that row when the new leaf fits, plus the averages row and that document's docsize row. Other FTS shapes still rebuild the postings.
- Ordinary writes can publish several changed rowid tables without rebuilding untouched tables. A new unique key past the current maximum is appended instead of rebuilding the image. Other unique-key shapes still rebuild it.
- With `autoUpdate`, a census distinguishes a pending-key replay from a full key scan. The integrity baseline is version 2. An incremental sync adjusts changed rows. `verifyIndex` still reads every derived row, and a version 1 baseline requires an explicit rebuild.
- `bm25()` with no column weights returns the score already stored for that row.
- A later Linux x64 AOT run on the same synthetic 2D corpus: 1000 indexed in 0.300666 s, 10000 in 4.704192 s, and 100000 in 75.807267 s. At 10000, source update alone is 35.599 ms and sync is 1.699659 s. Warm keyword time stayed in the earlier format 3 range. The 10000-record image is 1216512 bytes after indexing and 1118208 bytes at the end. See `benchmark/RESULTS.md`. The 1,000,000 run exited 255 after 2914 seconds and wrote no result, so it has no timings. A real model and other operating systems were not measured.

## 0.1.0-dev.2

- Call `ArabicText.normalize` instead of a second Arabic fold.
- Store embeddings in `vec0` and score eligible row ids with `rankVec0`.
  `embedding MATCH ? AND k = ?` is not the search query.
- Keep the index in the caller’s database. `open` does not rebuild it.
- Format 3 rejects format 2 and earlier development indexes until `indexTable`.
- Keyword `MATCH` stays on the FTS table. Eligible ids are resolved after it,
  because joining that virtual table currently returns no rows.
- Format 2 AOT numbers were not remeasured. No new speed claim.

## 0.1.0-dev.1

- Add persistent existing-table FTS5/BM25 indexes and configurable lexical analysis.
- Reuse Arabic light stemming and vec float32/cosine primitives.
- Add pluggable local embedding contract, validated synthetic fixture, exact
  filtered vector retrieval, RRF hybrid ranking and optional rank explanations.
- Add atomic explicit rebuilds, schema/analyzer/model guards and trigger-backed
  incremental replay before search.
- Add bounded collection-local feedback weights, versioned reset/export/import,
  retention limits and deterministic relevance evaluation fixtures.
- Add AOT benchmark harness, browser compilation and CI configuration.
- Production embedding runtime, real-model cross-language evaluation, physical
  crash recovery gates and large-scale performance acceptance remain pending.

### Hardening

- Preserve original durable commit errors; verify 80 storage fault points.
- Fix engine FTS block-ID truncation on JavaScript and execute VM/Node assertions.
- Add explicit SHA-256 index diagnostics and clear corrupt-vector/metadata failures.
- Validate provider identity across inference and reconcile secondary-unique REPLACE.
- Add held-out synthetic rank evaluation, coordinated handle failures and feedback
  retention/influence boundary tests.
- Use format-2 external-content FTS, initial single rebuild and explicit synchronize.
- Verify 61 search tests, pinned native integrity and the full engine suite.
- Record completed 1k/10k AOT runs; 100k/1m scale and production models remain open.
