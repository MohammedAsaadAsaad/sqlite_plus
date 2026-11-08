# First branch milestone

- [x] Isolated full main-image copy, immutable base, stable IDs and source scope.
- [x] Exact schema validation and finite, defensive SQL values/composite identities.
- [x] Final net diff; three-way field and row conflicts; stale preview checks.
- [x] Atomic merge, SQL conflict-policy verification and final foreign-key check.
- [x] Same-transaction merge receipt; archive-before-commit safe retry.
- [x] Portable archive, two-slot IO checkpoint, corruption/fault/process-exit tests.
- [x] ORM example with explicit handwritten/generated descriptor origins.
- [x] VM/native/JS assertions, AOT evidence and honest compatibility limits.

Not implemented: shared-page copy-on-write, branch catalog/list/rebase, branch
schema migrations, virtual/generated/triggered tables, automatic key remapping,
Changes/Sync/Reactive transaction integration, receipt pruning, remote branch
transport/security or a production power-loss/cross-platform acceptance gate.
