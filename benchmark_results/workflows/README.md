# Existing-package workflows AOT evidence

Historical measurements before the core UPSERT optimization. The 13-second import
limitation below is superseded for the tested workload by the [performance
follow-up](../import_performance/README.md). Original data and fingerprints remain
unchanged; complex-schema and release limits still require separate validation.

Linux AOT, three fresh processes per mode/size; no concurrent tests/compilation while sampling. Source initialization excluded from timers. Ordinary comparison alternates baseline/current process order. Feature size order alternates; modes run import/preview/advisor/replay. Small samples on a shared host are descriptive, not a zero-regression or production gate.

## Ordinary writes (1000 rows)

Baseline binary is the previously fingerprinted direct_writes benchmark. Its source hashes were checked against HEAD for core values.dart, ORM writes.dart and the driver before sampling. The new binary compiles the same driver against the changed ORM. Both modes assert all final values/counts.

| Mode | Before median ms | After median ms | Change |
| --- | ---: | ---: | ---: |
| update | 29.353 | 31.307 | +6.66% |
| upsert | 6365.076 | 6281.476 | -1.31% |

The initial three-sample update increase prompted a separate, targeted follow-up of 12 fresh processes per variant with alternating order; raw data is ordinary_update_followup.json. It does not erase the initial samples. Both datasets are reported; a strict zero-regression gate remains open. No unchanged-engine timing claim is inferred solely from source structure.

## New explicit workflows

| Mode | Rows | Median phases (ms) | Relevant bytes |
| --- | ---: | --- | --- |
| import | 100 | prepare=6.275, apply=146.095 | base_bytes=8192, final_bytes=8192 |
| preview | 100 | preview=9.134, merge=11.871 | base_bytes=8192, final_bytes=16384 |
| advisor | 100 | advice=12.232, index_build=5.712 | base_bytes=8192, index_bytes=4096, final_bytes=8192 |
| replay | 100 | record=2.613, replay=7.763 | base_bytes=8192, artifact_bytes=25967, final_bytes=8192 |
| import | 1000 | prepare=52.091, apply=12929.090 | base_bytes=28672, final_bytes=28672 |
| preview | 1000 | preview=58.765, merge=77.373 | base_bytes=28672, final_bytes=36864 |
| advisor | 1000 | advice=84.773, index_build=43.663 | base_bytes=28672, index_bytes=16384, final_bytes=28672 |
| replay | 1000 | record=10.556, replay=45.910 | base_bytes=28672, artifact_bytes=80583, final_bytes=28672 |

Import prepares/applies all rows, keeping incoming empty names from overwriting existing ones. Preview changes/merges 10 rows, validating reviewed source isolation. Advisor explicitly samples a query, builds a disposable (grp,n) index and checks unchanged source bytes. Replay records BEGIN/20 point updates/COMMIT/SELECT, exports initial plus final image, replays and verifies outcomes/logical state. Every mode asserts all final rows. Random branch receipt IDs can change preview physical hashes; logical hashes must agree.

RSS/peak_rss are process readings, not allocated-byte or hard-heap caps. In-memory 100/1000 row workloads only: no file IO, cross-process acceptance, million-row scalability or actual browser/device performance claim. Advisor measurements include snapshot/query/index work; they do not measure ongoing indexed-write cost. Recording files are synthetic benchmark data, not user artifacts.

Reproduce current feature samples:

```sh
dart compile exe tool/workflows_benchmark/main.dart -o /tmp/workflows-benchmark
/tmp/workflows-benchmark import 1000
/tmp/workflows-benchmark preview 1000
/tmp/workflows-benchmark advisor 1000
/tmp/workflows-benchmark replay 1000
```

For ordinary comparison, compile tool/direct_writes_benchmark/main.dart on each source revision, then run update/upsert 1000 in rotated fresh processes. The baseline fingerprints are retained in benchmark_results/direct_writes/manifest.json; current and baseline binary hashes plus source fingerprints are in manifest.json. Raw samples: ordinary_runs.json and feature_runs.json.

## Update follow-up and import limitations

Update follow-up medians before/after: 28.916/29.415 ms (+1.72%). Ranges: 27.745–32.980 / 27.646–33.010 ms. Broad overlap is consistent with host/cold-process variance; this is not proof of zero effect. Upsert's small decrease is also not a speedup claim.

Import apply remains around 13 seconds at 1000 rows here. Input-wide empty-field SQL simplification did not deliver a measurable overall improvement: the earlier snapshot samples in import_pre_optimization.json are retained, with their original writes.dart source hash below. Single-run batch-size probes (1/10/50/1000) in import_batch_probe.json did not resolve this expensive apply phase; they are exploratory, not comparative medians. More profiling/optimization is required before performance-sensitive bulk production use. No fast-import or 10k-row throughput claim is made.

To reproduce the exploratory probe, apply batch_probe_driver.patch to a temporary copy of the driver, compile it, then supply a third argument for batchSize (e.g. `import 1000 10`). All primary feature samples use the unpatched default driver.
