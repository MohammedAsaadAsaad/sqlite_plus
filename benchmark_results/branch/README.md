# Full-copy branch AOT measurements

Three fresh AOT processes per size; size order alternated. Setup excluded. In-memory ordinary integer-PK products, 10 branch price changes and 10 main stock changes on the same rows; no conflicts, FKs, triggers, ORM or file I/O. Each sample times create, diff, preview, archive and merge once in that order. No pre-warmup; later phases can benefit from caches.

| Rows | Create ms | Diff ms | Preview ms | Archive ms | Merge ms | Base bytes | Archive bytes | Merged bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1000 | 10.654 | 11.338 | 25.427 | 11.436 | 36.440 | 20480 | 54875 | 28672 |
| 10000 | 92.707 | 117.738 | 237.270 | 120.322 | 380.056 | 131072 | 349787 | 139264 |

Every final row/affected count is asserted. Create must preserve the entire source image hash. Random branch IDs in merge receipts mean final physical image hashes may differ between runs; final logical hashes must match at each size. The archive contains TWO complete images in base64 plus metadata. IO checkpoint slots add a further outer encoding and retain two generations. RSS is a process snapshot, not an allocated-byte/heap cap measurement.

Reproduce from repository root:

```sh
dart compile exe tool/branch_benchmark/main.dart -o /tmp/branch-benchmark
/tmp/branch-benchmark 1000
/tmp/branch-benchmark 10000
```

Raw samples are in runs.json; source/binary fingerprints and platform are in manifest.json. This is one Linux host and six samples, not a no-regression gate or a physical-storage/large-data performance result. Unused-package safety is structural: no existing engine/ORM runtime source changes or global hooks. No disabled-feature latency claim is made. No 100k/1m workloads, shared pages, actual browser/device or power-loss benchmark.
