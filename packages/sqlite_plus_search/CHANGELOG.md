## 0.1.0-dev.7

Depends on `sqlite_plus` ^0.1.12, `sqlite_plus_arabic` ^0.1.5, and `sqlite_plus_vec` ^0.1.5. The README opens `clinic.db` with `openFileImage`. The search behavior is the 0.1.0-dev.6 release.

## 0.1.0-dev.6

Depends on `sqlite_plus` ^0.1.11, `sqlite_plus_arabic` ^0.1.4, and `sqlite_plus_vec` ^0.1.4. The search behavior is the 0.1.0-dev.5 release.

## 0.1.0-dev.5

Depends on `sqlite_plus` ^0.1.9, `sqlite_plus_arabic` ^0.1.3, and `sqlite_plus_vec` ^0.1.3. The README opens on `clinic.db`. The catalog measurement is at the end. The search behavior is the 0.1.0-dev.4 release.

## 0.1.0-dev.4

- Requires `sqlite_plus` ^0.1.8. Two or more documents share FTS5 leaves, and a query of whole terms reads those leaves.
- The README records the 20,000-name catalog. Linux x64 AOT, not a phone: `بسكويت` returned 493 hits and 20 names in 26.967 ms, then 20.819 ms, and 25.663 ms at offset 320. One arm64 phone, catalog 0.5.2, showed 47.236 ms for page 1 of that query.
- Keyword search behavior is otherwise the 0.1.0-dev.3 library. A new maximum key can be appended, and the integrity sum is refreshed without hashing every derived row. A term-packed FTS leaf is rebuilt on the next edit. The synthetic append timings are in the repository benchmark results.

## 0.1.0-dev.3

- Keyword search resolves hit ids with one primary-key `IN` list, then checks that those source keys still exist. It no longer runs a correlated `EXISTS` that casts the source key for every hit.
- `indexTable` reads an ordinary source table 1,000 rows at a time, ordered by `rowid`, and can report `(done, total)` through `onProgress`. A `WITHOUT ROWID` source is still loaded, then written in the same page size. Search results are unchanged.
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
