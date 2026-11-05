# Append measurements — 2026-11-05

Dart 3.13.7/Linux x64 AOT, memory backend, synthetic 2D fixture, shared managed
host. One process per size with five warm samples. Cold means the first query
after indexing, not an OS cache reset. No concurrent test workload was
deliberately run during these samples. CPU scheduling is not isolated.
Raw runs: [1000](results/linux_1000_append.json),
[10000](results/linux_10000_append.json), and
[100000](results/linux_100000_append.json).

| Metric | 1,000 records | 10,000 records | 100,000 records |
|---|---:|---:|---:|
| Initial indexing (s) | 0.300666 | 4.704192 | 75.807267 |
| Cold keyword (ms) | 47.788 | 441.266 | 5176.545 |
| Cold vector (ms) | 21.292 | 186.061 | 2378.166 |
| Cold hybrid (ms) | 47.838 | 493.197 | 5691.671 |
| Median warm keyword (ms) | 48.229 | 475.981 | 5510.411 |
| Median warm vector (ms) | 23.061 | 215.387 | 2444.129 |
| Median warm hybrid (ms) | 49.161 | 498.088 | 5822.828 |
| Source update alone (ms) | 2.587 | 35.599 | 481.015 |
| Incremental sync alone (ms) | 191.076 | 1699.659 | 17883.826 |
| Feedback (ms) | 1.528 | 4.096 | 29.016 |
| RSS after source (bytes) | 23388160 | 55726080 | 74940416 |
| RSS after index (bytes) | 56631296 | 155729920 | 267067392 |
| RSS after queries (bytes) | 79015936 | 94773248 | 449126400 |
| RSS after sync (bytes) | 60743680 | 93614080 | 586375168 |
| RSS at end (bytes) | 49815552 | 124542976 | 271568896 |
| Peak RSS (bytes) | 80805888 | 225472512 | 633675776 |
| Image after index (bytes) | 192512 | 1216512 | 12226560 |
| Image at end (bytes) | 192512 | 1118208 | 11067392 |

Same corpus and harness as the sections below. A new unique key whose rowid is
past the current maximum is appended, and that key is inserted into the unique
index, without rewriting unrelated tables. An empty table, empty index, view,
or trigger is appended to the schema leaf when the new schema row fits.
Indexing creates those empty shadows before it loads keys. With `autoUpdate`,
triggers keep a census. When that census matches `count(*)`, sync reads only
the pending keys. The integrity baseline is version 2, an order-independent sum
of per-row hashes. That sync adjusts the changed key, docsize, and vector rows
and rehashes the other owned shadows. `verifyIndex` still reads every derived
row. A version 1 baseline fails until an explicit rebuild. The census table is
not part of the fingerprint.

On this corpus, 10,000-record indexing fell from 19.658282 s to 4.704192 s.
Sync fell from 2.117051 s to 1.699659 s. The remaining sync time is the
derived-row rewrite: the image is smaller after that sync than after indexing,
so the sync still compacts the database. Warm keyword time stays in the earlier
format 3 range because every benchmark document matches the query. 100,000
completed in this run. The earlier stop after 16 minutes is historical and was
not reused as a measurement. The 1,000,000 run exited 255 after 2914 seconds
and wrote no result, so it has no timings. RSS is one sample at each named phase, not a stable memory guarantee.
No real-model, browser, or other-OS timing is claimed.

---

# Row-edit measurements — 2026-11-05

Dart 3.13.7/Linux x64 AOT, memory backend, synthetic 2D fixture, shared managed
host. One process per size with five warm samples. Cold means the first query
after indexing, not an OS cache reset. No concurrent test workload was
deliberately run during these samples. CPU scheduling is not isolated.
Raw runs: [1000](results/linux_1000_row_edits.json) and
[10000](results/linux_10000_row_edits.json).

| Metric | 1,000 records | 10,000 records |
|---|---:|---:|
| Initial indexing (s) | 1.092900 | 19.658282 |
| Cold keyword (ms) | 46.483 | 470.877 |
| Cold vector (ms) | 32.327 | 309.975 |
| Cold hybrid (ms) | 59.923 | 594.552 |
| Median warm keyword (ms) | 48.142 | 474.704 |
| Median warm vector (ms) | 34.815 | 339.157 |
| Median warm hybrid (ms) | 60.049 | 624.415 |
| Source update alone (ms) | 2.415 | 27.872 |
| Incremental sync alone (ms) | 227.408 | 2117.051 |
| Feedback (ms) | 1.472 | 4.257 |
| Process RSS (bytes) | 49893376 | 75509760 |
| Peak RSS (bytes) | 79724544 | 237608960 |
| Image size (bytes) | 184320 | 1110016 |

Same corpus and harness as the format 3 section below. The engine now writes
changed ordinary tables without rebuilding untouched ones, and a one-row
external-content FTS replace edits the leaf that holds that row when the new
leaf fits. On this corpus the measured change is the source update and the
following sync. Warm keyword, vector, and hybrid times stay in the same range
as the earlier format 3 run; every benchmark document matches the query, so
those queries still score the whole collection. Indexing stayed near the
earlier format 3 time because a new unique key still rebuilds the image.
100,000 was not started again. The earlier format 3 attempt at that size was
stopped after 16 minutes while indexing, and that stop still stands. 1,000,000
was not started. RSS and peak RSS are one sample each. No real-model, browser,
or other-OS timing is claimed.

---

# Format 3 measurements — 2026-11-05

Dart 3.13.7/Linux x64 AOT, memory backend, synthetic 2D fixture, shared managed
host. One process per size with five warm samples. Cold means the first query
after indexing, not an OS cache reset. No concurrent test workload was
deliberately run during these samples. CPU scheduling is not isolated.
Raw runs: [1000](results/linux_1000_format3.json) and
[10000](results/linux_10000_format3.json).

| Metric | 1,000 records | 10,000 records |
|---|---:|---:|
| Initial indexing (s) | 1.189207 | 20.311424 |
| Cold keyword (ms) | 48.878 | 484.488 |
| Cold vector (ms) | 32.624 | 314.710 |
| Cold hybrid (ms) | 58.915 | 592.748 |
| Median warm keyword (ms) | 49.681 | 455.066 |
| Median warm vector (ms) | 36.054 | 348.888 |
| Median warm hybrid (ms) | 62.974 | 639.255 |
| Source update alone (ms) | 359.419 | 3008.387 |
| Incremental sync alone (ms) | 616.455 | 5319.037 |
| Feedback (ms) | 1.486 | 3.585 |
| Process RSS (bytes) | 51392512 | 77606912 |
| Peak RSS (bytes) | 79622144 | 226885632 |
| Image size (bytes) | 184320 | 1110016 |

These are format 3. Embeddings are `vec0` rows. Unfiltered ranking reads the
shadow in stopped rowid pages of 512. Keyword ids are resolved with a source-key
set and a key-table scan, not a correlated `EXISTS`. Non-contentless-delete FTS5
rows share leaves. A one-row sync still rewrites the FTS postings; the rewrite
encodes each leaf by probing its length instead of re-encoding after every
document. A 100,000-record attempt on the same host finished source creation
and was still indexing after 16 minutes, so it was stopped. No index or query
numbers are reported for that size. 1,000,000 was not started. Process RSS is
one sample and is not a stable memory guarantee. No real-model, browser, or
other-OS timing is claimed.

---

# Hardened format-2 measurements — 2026-11-04

These numbers are format 2. They are kept as provenance for the index that
stored vectors outside `vec0`. They are not format 3 timings.

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
