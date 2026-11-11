## Unreleased — explicit diagnostics

- Isolated index candidate advice with measured plans/results/timing/size.
- Optional bounded raw recording and in-memory replay with logical-state proof.
- Default redaction/collector paths unchanged; complete VM/JS examples.

# Changelog

## 0.0.1-dev.1

Depends on `sqlite_plus` ^0.1.13, `sqlite_plus_orm` ^0.1.12, and `sqlite_plus_changes` ^0.0.1-dev.1. The README opens `catalog.db`.

- Optional raw/read-only/file/ORM observation adapters; no engine runtime hooks.
- Bounded records, aggregates and nested/concurrent operation scopes, slow-query
  flags, failure/row statistics, repeated-read hints and JSON export.
- Default bind/literal redaction, bounded opt-in previews, no result-value retention.
- In-flight/history/depth budgets, clear/disable/close lifecycle and original errors.
- Explicit main-image SELECT planning; no automatic query re-execution/indexing.
- Changes transaction-driver/Reactive and file/browser ORM integration tests.
