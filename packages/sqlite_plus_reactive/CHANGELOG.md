# Changelog

## 0.0.1-dev.1

Depends on `sqlite_plus` ^0.1.13 and `sqlite_plus_changes` ^0.0.1-dev.1. The README opens on `watch`.

- Lazy shared SQL watches with parameter/dependency isolation, coalescing,
  distinct snapshots, row changes, pause/cancel/close and manual refresh.
- Optional Changes source with stateless bounded log reads, commit hints and
  full refresh after pruning/generation changes. No durable watch consumer.
- Native ORM watch APIs, independent untracked snapshots and optional shared
  Changes/Sync transactions. Existing ordinary ORM save path retained.
- Per-query retained-row budget; VM/Node examples and native SQL assertions.
