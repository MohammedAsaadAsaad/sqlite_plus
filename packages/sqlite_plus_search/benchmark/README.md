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
RSS and peak RSS are sampled after the source load, after indexing, after the warm queries, after synchronization, and at the end. Image size is recorded after indexing and at the end.

Raw measured runs and host details are in results/. These are shared-host Linux
measurements, not cross-platform guarantees. An earlier per-record indexing
implementation timed out at 120 seconds for 1000 records before reaching queries;
that incomplete attempt has no fabricated indexing or latency numbers. Initial
writes now use batches of 100. See the results report for larger-run status.

Hardening runs additionally record cold/warm semantic latency and separate source
update, synchronize, and post-update hybrid query timings. `hardened_attempts.json`
records source SHA-256 values and explicit timeout outcomes. The committed format-2 numbers use 1000 derived rows per batch and one
external-content FTS build. Format 3 was measured again on 2026-11-05 for 1,000
and 10,000 records; those JSON files are `linux_1000_format3.json` and
`linux_10000_format3.json`. Format 2 and format 1 results remain historical.
Measurements are single shared-host processes. A format 3 run of 100,000
records was stopped after 16 minutes while indexing, with no completed metrics.
The append run completed 1,000, 10,000, and 100,000. Its JSON files are
`linux_1000_append.json`, `linux_10000_append.json`, and
`linux_100000_append.json`. The 1,000,000 run exited 255 after 2914 seconds
and wrote no result, so it has no timings. The row-edit JSON files are `linux_1000_row_edits.json` and
`linux_10000_row_edits.json`. The catalog keyword sample is a different program,
`catalog_lookup.dart`, recorded in the repository development log.
