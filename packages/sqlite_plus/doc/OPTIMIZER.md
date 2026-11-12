# Optimizer progress: bounded result selection

The user-facing examples for version 0.1.14 are in the
[engine README](../README.md#the-query-planner): a covering index seek, a
two-table inner-join seek, one-end `MAX` of an integer primary key, folded
arithmetic, and a contradictory filter. That version is prepared and not
uploaded. `STAT4` planning, skip-scan, index intersection, hash join, and
flattening a correlated subquery are not implemented.

The engine already has rowid/index access planning, STAT1 index ranking and
selected covering/streaming/join-ordering paths. These are bounded subsets,
not a complete SQLite-equivalent optimizer.

The first measured follow-up improves execution of eligible ORDER BY/LIMIT
queries automatically, with unchanged SQL and no new index:

```sql
CREATE TABLE items(
  id INTEGER PRIMARY KEY, score INTEGER, flag INTEGER, payload TEXT
);
SELECT id,payload FROM items
WHERE flag>=0
ORDER BY score,id
LIMIT 1000 OFFSET 0;
```

Existing execution already retained LIMIT+positive OFFSET candidates, but
searched them linearly for the worst row. For capacity >=32, execution now
builds an in-place max-heap lazily when that retained set fills. It uses the
same list and final output ordering, retaining earliest ties and projection
eligibility decisions. Small capacities keep the linear path; unsupported
shapes such as DISTINCT keep their existing behavior. Huge limits over short
inputs do not allocate a huge buffer eagerly.

This changes selection CPU work, not index choice or pages read. It does not
remove upstream materialization or imply that all LIMIT queries stop reading
early. No schema, file-format, public API or new dependency is introduced.

[Measurements and control costs](../../../benchmark_results/optimizer/README.md)
include strong target-workload gains, unchanged result/IO/callback checks, whole
process memory and ordinary-path comparisons. Small update-control differences
are reported, so zero overhead is not claimed. VM/JS assertions verify behavior;
performance numbers are Linux AOT measurements, not device/browser benchmarks.

See the [42-item roadmap](../../../docs/plans/OPTIMIZER.md) for what remains.
