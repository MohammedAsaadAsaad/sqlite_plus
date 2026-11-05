## 0.1.0-dev.3

- `indexTable` reads an ordinary source table 1,000 rows at a time, ordered by `rowid`, and can report `(done, total)` through `onProgress`. A `WITHOUT ROWID` source is still loaded, then written in the same page size. Search results are unchanged.
- The clinic-shelf example shows diacritic folding, a bound shelf filter, an insert picked up by `autoUpdate`, Arabic light stemming, and a hybrid rank explanation.
- `FixtureEmbeddingProvider` in that example is an exact string map. A missing string fails. It is not a language model.
- Search behavior is otherwise the 0.1.0-dev.2 library.

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
