# Jobs AOT benchmark

From workspace root with Dart 3.13.7:

```sh
dart compile exe tool/jobs_benchmark/main.dart -o /tmp/jobs-benchmark
python3 tool/jobs_benchmark/run.py
```

The runner overwrites benchmark_results/jobs/runs.json. Archive existing samples
before rerunning. Stop other tests/compilers first. It uses three fresh processes per mode at 100 rows, rotating order: atomic
enqueue batch vs individual enqueue transactions. Three extra 1000-row batch processes each process ten jobs; this does not
measure draining a 1000-job queue. Each process times installation, enqueue, 100 duplicate
requests, and a configured number of sequential claim+complete pairs (100 at size100,
ten at size1000), then checks all row
states and FIFO payload order. Initial empty engine creation is outside timers.
All timestamps are fixed; payloads are synthetic small JSON. Sample RSS/peak RSS
are process readings, not attributable allocated bytes or heap caps. No file IO,
100k/1m, actual browser/device or concurrent-worker throughput is measured.
The logical checksum excludes random lease tokens; physical hashes are evidence,
not assumed identical across transaction shapes or free-page histories.
