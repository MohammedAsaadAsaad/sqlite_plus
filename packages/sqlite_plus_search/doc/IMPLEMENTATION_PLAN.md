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
- [x] 8. Transactional trigger logs and logical incremental replay. Physical FTS
  persistence still rewrites postings and is an unresolved performance limit.
- [ ] 9. Release validation. Tests, native comparisons, and format 3 AOT runs at
  1k and 10k pass. Real-model quality, 100k/1m scale, real browser persistence,
  and broader OS gates remain.
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
- Logical embedding updates are incremental. Physical FTS persistence still
  rewrites postings for the collection. That rewrite is not production-scale
  optimized.

Production embeddings/cross-language evaluation, repeated-process performance
statistics, arbitrary external-writer ownership, real-device/torn-byte recovery,
real browser storage and macOS/Windows/mobile execution remain open. Models must
be provisioned locally by the application; none are downloaded automatically.
