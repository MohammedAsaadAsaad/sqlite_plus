# Reproducible AOT harness

From the repository root:

```sh
dart compile exe packages/sqlite_plus_search/benchmark/search_benchmark.dart -o /tmp/search-bench
/tmp/search-bench 1000
/tmp/search-bench 10000
/tmp/search-bench 100000
/tmp/search-bench 1000000
```

Only those four sizes are accepted. Output is JSON; progress goes to stderr.
The corpus contains identical Arabic/English documents and one changed document.
The provider is a two-dimensional synthetic lookup fixture, so this does not
measure real model inference, semantic quality or representative corpus diversity.
The backend is memory. Source generation is excluded from indexing time. Initial
indexing includes normalized-content loading, one FTS build, vector/trigger setup
and the integrity baseline. Incremental time includes source
update, replay and a hybrid query. Queries include local learning-context writes.
The first queries after indexing are called cold; OS caches are not reset.
Warm query arrays contain five samples, not five independent process runs.
RSS is process memory; peak RSS is sampled before final image export.

Raw measured runs and host details are in results/. These are shared-host Linux
measurements, not cross-platform guarantees. An earlier per-record indexing
implementation timed out at 120 seconds for 1000 records before reaching queries;
that incomplete attempt has no fabricated indexing or latency numbers. Initial
writes now use batches of 100. See the results report for larger-run status.

Hardening runs additionally record cold/warm semantic latency and separate source
update, synchronize, and post-update hybrid query timings. `hardened_attempts.json`
records source SHA-256 values and explicit timeout outcomes. Index format 2 loads
1000 derived rows per batch and builds external-content FTS once. Old format-1
results remain historical; measurements are single shared-host processes.
