# Changelog

## 0.0.1-dev.1

Depends on `sqlite_plus` ^0.1.13 and `sqlite_plus_changes` ^0.0.1-dev.1. The README opens `catalog.db`.

- Initial development milestone: explicit state-based push/pull,
  immutable durable outbox and stable operation IDs, scoped server namespaces,
  typed composite keys, monotonic revisions and tombstones.
- Atomic Changes output/ack, incoming source/revision/origin/cursor commits and
  durable blocking conflicts with explicit local/remote resolution.
- Explicit bounded bootstrap and resumable registration; guarded source writes,
  protocol validation, no-op origin safety and unexpected trigger-effect checks.
- Development reference transport, two-replica/VM/Node examples, native image/SQL
  checks, simulated storage-failure recovery and AOT measurements.
- No existing app activation, package publication, production server deployment,
  automatic networking, raw/ORM interception or universal compatibility claim.
