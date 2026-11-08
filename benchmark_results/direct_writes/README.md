# Direct ORM writes benchmark

AOT, three fresh processes per mode and size; rotated execution order. Setup excluded. Existing integer-primary-key rows, two columns, in-memory connection, no triggers, managed versions, Changes or tracked entities in direct modes. This compares API strategies, not enabled-versus-disabled overhead.

| Rows | Operation | Median ms | ORM queries / executes | Database bytes |
| --- | --- | ---: | --- | ---: |
| 100 | tracked | 176.234 | 102 / 102 | 12288 |
| 100 | update | 2.865 | 1 / 3 | 12288 |
| 100 | upsert | 75.109 | 4 / 3 | 12288 |
| 1000 | tracked | 13995.463 | 1002 / 1002 | 24576 |
| 1000 | update | 29.586 | 1 / 3 | 24576 |
| 1000 | upsert | 6178.551 | 4 / 7 | 24576 |

All final rows and affected counts were asserted. Logical hashes match across modes. Physical image hashes can differ because mutation strategies pack pages differently. Raw timings, memory and hashes are in `runs.json`. RSS measurements are process snapshots, not allocated-byte measurements.

Reproduce from repository root:

```sh
dart compile exe tool/direct_writes_benchmark/main.dart -o /tmp/direct-writes-benchmark
/tmp/direct-writes-benchmark tracked 1000
/tmp/direct-writes-benchmark update 1000
/tmp/direct-writes-benchmark upsert 1000
```

Results cover only these small in-memory workloads. They do not establish performance for file I/O, large tracked contexts, Changes, or larger datasets. The core collation correctness fix is included in every mode. Existing Inspector measurements describe their earlier source snapshot.
