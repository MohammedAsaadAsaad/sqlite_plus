# Phase 1 implementation and release status

Core functionality is implemented; production release acceptance remains open.

- [x] 1. Repository/public API inspection and integration strategy.
- [x] 2. Workspace package and validated local embedding contracts.
- [x] 3. Configurable Unicode/Arabic lexical processing using engine BM25.
- [x] 4. Persistent metadata, atomic rebuilds, explicit integrity diagnostics,
  schema guards and modelled crash recovery.
- [x] 5. Exact filtered vector retrieval using sqlite_plus_vec primitives.
- [x] 6. RRF hybrid ranking, bound filters, explanations and stable ordering.
- [x] 7. Bounded, versioned collection-local feedback; reset/export/import.
- [x] 8. Transactional trigger logs and logical incremental replay. A one-row
  external-content FTS replace edits that row's leaf when the new leaf fits.
  When the trigger census matches the source count, sync reads only the pending
  keys. The integrity baseline is an order-independent per-row sum; that sync
  adjusts the changed rows instead of hashing every derived row.
- [ ] 9. Release validation. Tests, native comparisons, and Linux AOT runs at
  1k, 10k, and 100k pass on the synthetic fixture. Real-model quality, the 1m
  scale, real browser persistence, and broader OS gates remain.
- [x] 10. Runnable examples, development docs and CI configuration. No remote
  CI result or publication is claimed.

## Completed hardening milestones

- [x] H1: Precise embedding failures and 80 injected storage-operation crashes.
  Fixed original commit errors being masked by rollback on a poisoned connection.
- [x] H2: Fixed JavaScript bit-37 FTS block IDs. Shared VM/Node assertions execute
  in CI; pinned native SQLite comparisons pass.
- [x] H3: Coordinated multi-handle failures; 24-step replay-versus-rebuild checks;
  disjoint held-out synthetic judgments/control; corruption/rebuild diagnostics;
  provider identity contracts and secondary-unique REPLACE displacement.
- [x] H4: Build external-content FTS once after loading normalized content,
  replace changed FTS rows once, use typed key lookups, expose synchronize,
  measure larger sizes and retain source hashes/raw output. Format 2 requires
  explicit rebuild of earlier development indexes; no source-data migration.

## Verified results (Dart 3.13.7, Linux x64)

- Formatting and fatal-info analysis pass. Offline enforced-lockfile pub resolution
  passes. No cloud/model download, network inference, telemetry or native binding
  was added to the production search runtime.
- **61 search tests pass**: 60 deterministic tests plus one optional pinned-native
  integration. Feedback tests cover 1001-hit retention/expiry and repeated-label
  weight/score bounds. Native snapshots pass SQLite integrity checks and external
  FTS integrity-check after initial indexing and incremental updates.
- **10609 engine tests pass, 1 skipped** with the exact SQLite 3.53.1 pin available.
  An initial run had 9 loopback socket permission failures; affected reruns and
  the complete rerun with required local socket permission pass.
- Crash tests sweep **80 failure points** across rebuild/replay/feedback,
  delete/persist journals and volatile/immediate persistence. Index/log,
  model/label and integrity-baseline atomicity survive repeated recovery.
  This is storage fault modelling, not real-device power-loss verification.
- Shared assertions pass on the Linux VM and compiled JavaScript/Node 24.19.0:
  lexical multilingual search, filtered vectors, RRF, feedback, rollback, replay,
  image/model round trips and integrity diagnostics. Real browser IO is unrun.
- Held-out synthetic tea/juice queries and documents never supply training labels:
  MRR .5 -> 1 and NDCG@10 .6309297535714574 -> 1, with Recall@10 unchanged at 1
  and a control ranking unchanged. These are rank-feature tests, not real-model
  semantic quality or a guarantee against regressions on other data.

## Actual AOT performance and remaining gates

See benchmark/RESULTS.md and committed raw JSON/progress logs/source hashes.
Memory backend; synthetic 2D provider; one shared-host process per size with five
warm samples. Initial indexing includes integrity metadata.

- Format 2, kept as provenance: 1000 records indexed in 2.549333 s (historical
  format-1 run: 7.901779 s). 10000 records indexed in 26.926220 s. The 100000
  format 2 attempt created the source and timed out at 120 s during indexing.
- Format 3, measured 2026-11-05 on the same class of Linux x64 AOT host: 1000
  records indexed in 1.189207 s; 10000 records indexed in 20.311424 s. At 10000
  records, source update alone is 3.008387 s and synchronization is 5.319037 s.
  Median warm keyword/vector/hybrid queries are 455.066 ms, 348.888 ms, and
  639.255 ms. The database image is 1110016 bytes. A format 3 100000-record
  attempt was stopped after 16 minutes while indexing. No metrics are reported
  for it. 1000000 was not started.
- Later the same day, after row-level image edits, the same harness recorded
  1000 records indexed in 1.092900 s and 10000 in 19.658282 s. At 10000 records,
  source update alone is 27.872 ms and synchronization is 2.117051 s. Median
  warm keyword/vector/hybrid queries are 474.704 ms, 339.157 ms, and 624.415 ms.
  The 10000-record image is still 1110016 bytes. Query time did not move out of
  the format 3 range on this all-matching corpus. 100000 was not started again.
  The full engine suite was not re-run for this edit.
- Later the same day, after unique-key append and incremental sync, the same
  harness recorded 1000 records indexed in 0.300666 s, 10000 in 4.704192 s, and
  100000 in 75.807267 s. At 10000 records, source update alone is 35.599 ms and
  synchronization is 1.699659 s. The 10000-record image is 1216512 bytes after
  indexing and 1118208 bytes at the end. 100000 completed. The 1,000,000 run
  exited 255 after 2914 seconds and wrote no result, so it has no timings. See benchmark/RESULTS.md.
- A new unique key past the current maximum is appended without rewriting
  unrelated tables. When the census matches, sync does not scan every key, and
  the fingerprint update does not hash every derived row. `verifyIndex` still
  does. The measured sync time is still the derived-row rewrite. That is not a
  production-scale index build.
- Catalog keyword search of the two 10,000-name product lists is a separate
  AOT measurement, recorded in the repository development log on 5 November
  2026. It is lexical BM25 on packed FTS leaves, not this embedding benchmark.

Production embeddings/cross-language evaluation, repeated-process performance
statistics, arbitrary external-writer ownership, real-device/torn-byte recovery,
real browser storage and macOS/Windows/mobile execution remain open. Models must
be provisioned locally by the application; none are downloaded automatically.

## Optional fuzzy fallback (2026-11-06)

- [x] Per-query opt-in Levenshtein fallback for filtered-empty keyword results.
- [x] Limits, literal expansion, BM25/RRF integration and public API documentation.
- [x] Nine new tests; Linux suite: 70 pass, 1 native test skipped (CLI absent).
- [ ] Persistent candidate index and reproducible large-corpus fuzzy benchmarks.

No storage format change or production-release acceptance claim.

## Optional repeated-typo learning (2026-11-07)

- [x] Configurable opt-in threshold, pending counters, persistent promotion and
  learned token alternatives; no whole-vocabulary deletion index.
- [x] Explicit new-input recording flag, cache/write result flags, collection and
  settings isolation; rebuild/replay invalidation and corruption checks.
- [x] App threshold 5, image persistence, exclusion of page navigation.
- [x] AOT benchmark on actual 20,000-name catalog, raw results in benchmark/.
- [ ] Eviction limits and comprehensive learned-metadata integrity diagnostics.

## Optional match precision (2026-11-07)

- [x] Keyword precision tiers, field coverage weights, configurable precedence,
  explanations and stable ordering before pagination.
- [x] Single-field normalized-text reuse and shared multi-field source probe.
- [x] Six precision tests, sample integration, 20k-name paired AOT measurements.
- [ ] Precision policies for hybrid/semantic retrieval.

Requires the workspace engine Unicode61Tokenizer export; no new index format.
