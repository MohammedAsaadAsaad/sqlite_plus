# Strengthen existing packages: preview, import and diagnostics

Scope approved 2026-11-08. Build inside Branch, ORM and Inspector, without adding
packages or installing hooks into the core engine. Existing Branch schema and
exclusive-ownership constraints remain in force. This is development work, not a
release/publication or permission to automatically merge main.

## 1. Branch operation preview

- [x] Add generic callback preview using an existing isolated full-copy branch.
- [x] Return callback value, immutable reviewed diff/conflicts and merge/close.
- [x] Merge the reviewed image only; reject a stale source or escaped branch edit.
- [x] Cleanup on callback/validation error, preserve original failure, no implicit
      approval or saveChanges; examples cover SQL and a short-lived ORM context.

## 2. ORM import preparation and application

- [x] Add bounded prepared import of mapped entities with per-input diagnostics,
      developer validation, explicit duplicate policies and snapshotted values.
- [x] Inspect actual unique-index collations; never deduplicate with Dart string
      equality when SQL uses NOCASE/RTRIM. NULL conflict keys are invalid.
- [x] Reuse the atomic upsertMany write path, adding import-only empty-value
      handling: overwrite or preserve stored value for NULL/empty text on conflict.
      Inserts use incoming values; required-field/DB failures remain atomic.
- [x] Plan counts are input counts, not promised inserted/updated counts. Invalid
      rows/duplicates are reviewable; apply rejects unresolved validation errors.
- [x] Apply consumes the captured snapshot and revalidates DB uniqueness metadata;
      plans are not stale-safe row approvals. Use Branch preview to review actual
      final stored changes and merge with its stale-source check.
- [x] Example: Product and every Column, input mapping/validation, duplicate and
      empty policies, previewing import on Branch, then explicit acceptance.

## 3. Inspector index analysis

- [x] Explicit bounded snapshot-only advisor for conservative single-table SELECTs:
      AND equality/range filters and simple column ORDER BY. Reject unsupported
      joins/CTEs/OR/functions/limits rather than guess about them.
- [x] Read actual columns/collations/indexes; avoid redundant ordinary index
      prefixes and primary-key access. Candidate SQL quotes all identifiers.
- [x] Build candidate on a disposable copy; compare plan, query samples and result
      multiset, index-build time and image-size cost. Never replay user SQL or
      build an index on main automatically; no write-cost claim without measurement.
- [x] Recommendations are evidence for one snapshot/query, not workload-wide proof.

## 4. Inspector diagnostic recording/replay decision

Decision: implement an explicit optional library in Inspector. Ordinary records
stay redacted and insufficient for replay. A separate recorder deliberately stores
raw SQL/parameters plus initial/expected-final SQLite images; bounded/checksummed artifacts must
be treated as sensitive plaintext and not as authenticated input.

- [x] Record serial query/execute outcomes, including errors/transactions, from
      an exclusively loaned engine. Unsupported/overflow capture becomes visibly
      incomplete; finish rejects incomplete sessions. Do not hide original SQL errors.
- [x] Validate allowed SQL and byte/statement/image limits on decode; no ATTACH,
      file SQL, schema/PRAGMA/custom-host action replay in this milestone.
- [x] Replay only in a newly created in-memory engine. Compare outcomes and final
      logical state, report first divergence, never target an existing production connection.
- [x] Nondeterministic functions/custom registries/external operations are not
      promised reproducible. No automatic recording/export or network upload.

## 5. Verification, performance and delivery

- [x] Positive/negative/boundary cases for all APIs, tracking/Changes/Reactive
      regressions, BLOB/64-bit/VM+JS value handling and preview cleanup.
- [x] Pinned SQLite differential checks for import SQL and advisor index/result
      behavior; existing Branch corruption/commit tests continue passing.
- [x] Analyze/format and affected full package suites, VM/Node runnable examples.
- [x] Reproducible AOT samples for import/preview/advisor/replay plus unchanged
      ordinary paths. Report raw runs, fingerprints, sizes, limits and variance.
- [x] Package READMEs/changelogs/examples, compatibility/log and CI definitions.
      Remote CI, actual browser/device, production crash and public dependency
      publication remain separate gates unless actually verified.

Implementation proceeds in this order, checking each stage before the next.
Deferred: CSV/XLSX parsers, streaming/resumable cross-transaction import, automatic
index application, general SQL tuning, engine-wide recording, host callbacks,
shared-page branches and triggered/virtual-table branch merges.


## Completion and open gates

All scoped development steps are implemented. Validation includes the affected
full suites, additional boundary/native cases, VM/Node examples and fingerprinted
AOT runs. See DEVELOPMENT_LOG.md for counts and benchmark_results/workflows for
raw samples. Import apply is still slow at 1000 rows (~13s); exploratory batch
sizes and conditional simplification did not materially improve it. No fast-import,
strict zero-overhead, production crash, browser/device, remote CI or public-release
acceptance is claimed. These remain explicit follow-up gates, not silent passes.


Performance follow-up: the historical 13-second apply limitation is superseded
for the tested workload by [IMPORT_PERFORMANCE.md](IMPORT_PERFORMANCE.md) and
[final AOT measurements](../../benchmark_results/import_performance/README.md).
The subsequent approved performance work changes the core internally; the
original feature milestone above did not. Remaining ordinary-update overhead,
10k memory/scaling and release limits are documented in that follow-up.
