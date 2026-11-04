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
