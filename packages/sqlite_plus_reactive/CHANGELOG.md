# Changelog

## 0.0.1-dev.1 (unpublished)

- Lazy shared SQL watches with parameter/dependency isolation, coalescing,
  distinct snapshots, row changes, pause/cancel/close and manual refresh.
- Optional Changes source with stateless bounded log reads, commit hints and
  full refresh after pruning/generation changes. No durable watch consumer.
- Native ORM watch APIs, independent untracked snapshots and optional shared
  Changes/Sync transactions. Existing ordinary ORM save path retained.
- Per-query retained-row budget; VM/Node examples and native SQL assertions.
