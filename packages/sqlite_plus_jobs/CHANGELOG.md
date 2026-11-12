# Changelog

## 0.0.1-dev.1 (unreleased workspace)

- Require `sqlite_plus` ^0.1.14.
- Explicit durable queue with queue-scoped dedup, priority/delay, random-token
  leases, renewal/expiry, bounded retries, cancellation and terminal pruning.
- Atomic application DML plus enqueue or lease-fenced acknowledgement.
- Optional explicit runOne worker, without scheduling/ORM/core hooks.
- Same-connection serialization only; durability follows the selected backend.

- Processing follow-up: scheduling-metadata equality reads, preserved SQL lease
  fences, generic engine guarded-row/index-check improvements and live read-cache
  correctness fix. No schema migration. Repeated AOT memory/file results and
  remaining limits: ../../benchmark_results/jobs_performance/README.md.
