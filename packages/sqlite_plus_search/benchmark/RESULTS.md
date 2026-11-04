# Hardened format-2 measurements — 2026-11-04

Dart 3.13.7/Linux x64 AOT, memory backend, synthetic 2D fixture, shared managed
host. One process per size with five warm samples. No concurrent test workload
was deliberately run during these samples. CPU scheduling is not isolated.
Raw runs: [1000](results/linux_1000_hardened.json),
[10000](results/linux_10000_hardened.json), and
[attempts/source hashes](results/hardened_attempts.json).

| Metric | 1,000 records | 10,000 records |
|---|---:|---:|
| Initial indexing (s) | 2.549333 | 26.926220 |
| Cold keyword (ms) | 82.394 | 1009.831 |
| Cold vector (ms) | 57.373 | 620.604 |
| Cold hybrid (ms) | 108.836 | 1205.973 |
| Median warm keyword (ms) | 83.864 | 911.457 |
| Median warm vector (ms) | 49.239 | 577.129 |
| Median warm hybrid (ms) | 98.715 | 1110.798 |
| Source update alone (ms) | 1179.562 | 12795.218 |
| Incremental sync alone (ms) | 1952.261 | 20004.185 |
| Feedback (ms) | 2.952 | 17.263 |
| Process RSS (bytes) | 50921472 | 108879872 |
| Peak RSS (bytes) | 54398976 | 240500736 |
| Image size (bytes) | 241664 | 1708032 |

Format 2 loads normalized content before a single external-content FTS rebuild.
Initial indexing includes the integrity fingerprint. Incremental timings separate
source update, synchronization and the post-update query (raw JSON). Logical
synchronization regenerates one embedding, but physical FTS persistence remains
expensive; neither these figures nor synthetic inference imply production readiness.
The hardened 100,000-record attempt reached source creation but timed out at
120 seconds during indexing. No index/search metrics are reported for that size.
1,000,000 was not run: the smaller scale gate remains unresolved.

The historical sample below is retained verbatim for provenance. The new harness
also measures vector queries and separate update/sync phases. Single shared-host
samples are not a statistical speed guarantee.

---

# Historical format-1 measurements — 2026-11-04

Dart 3.13.7/Linux x64, AOT, memory backend, shared managed host (3 visible CPUs).
See [raw output](results/linux_1000.json) and [host/attempts](results/environment.json).
Synthetic 2D fixture inference; corpus and measurement boundaries are in README.
This is one process with five warm samples, not an isolated statistical study.

| 1,000 records | Measured |
|---|---:|
| Initial indexing | 7.901779 s |
| First keyword query | 74.058 ms |
| First hybrid query | 128.114 ms |
| Median of 5 warm keyword samples | 81.981 ms |
| Median of 5 warm hybrid samples | 93.300 ms |
| Warm hybrid / keyword median ratio | 1.138 |
| One update + replay + hybrid query | 2881.557 ms |
| One feedback update | 2.142 ms |
| Process RSS | 50425856 bytes |
| Peak process RSS before image export | 77864960 bytes |
| Database image | 249856 bytes |

The per-record write baseline timed out at 120 seconds while indexing 1,000
records, with no completed query measurements. Batching initial writes in groups
of 100 completed the run above. The 10,000-record batched attempt reached source
creation but timed out at 180 seconds before indexing completed. It has no
index/search latency numbers. This reveals a scale blocker, not a successful
10,000-record benchmark. The 100,000-record attempt likewise reached source creation but timed out
at 60 seconds during indexing; no completed metrics are available. 1,000,000 is not practical before resolving this bottleneck.

Incremental FTS delete/insert and exact materialized retrieval are still expensive.
Further optimization must preserve filtered recall and transactional replay.
No real-model inference, physical disk persistence, browser, macOS or Windows
performance results are claimed. Larger-size and repeated-process gates remain open.
