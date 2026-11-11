# Reproduce jobs processing measurements

Use Dart 3.13.7 from workspace root after `dart pub get`. Native SQLite is needed
only for differential tests, not the runtime or benchmarks.

Create a copied baseline by reversing this milestone's two production patches:

```sh
python3 tool/jobs_performance/prepare_baseline.py
```

The script prints an absolute package_config.json path under /tmp. Use that path
as `BASELINE_CONFIG` below; it overrides only sqlite_plus/sqlite_plus_jobs roots.
No working-tree sources are changed. Verify reconstructed core/queue hashes
against benchmark_results/jobs_performance/before_manifest.json.

```sh
dart compile exe --packages="$BASELINE_CONFIG" tool/jobs_benchmark/main.dart -o /tmp/jobs-before-performance
dart compile exe tool/jobs_benchmark/main.dart -o /tmp/jobs-after-performance
dart compile exe --packages="$BASELINE_CONFIG" tool/jobs_performance/processing.dart -o /tmp/jobs-processing-before
dart compile exe tool/jobs_performance/processing.dart -o /tmp/jobs-processing-after
dart compile exe --packages="$BASELINE_CONFIG" tool/jobs_performance/ordinary.dart -o /tmp/jobs-ordinary-before
dart compile exe tool/jobs_performance/ordinary.dart -o /tmp/jobs-ordinary-after
dart compile exe --packages="$BASELINE_CONFIG" tool/workflows_benchmark/main.dart -o /tmp/jobs-workflows-before
dart compile exe tool/workflows_benchmark/main.dart -o /tmp/jobs-workflows-after
python3 tool/jobs_performance/run.py
```

Stop tests/compilers/profilers before running measurements. The runner overwrites
runs.json; archive previous evidence first. Processing accepts depth/processed
counts plus optional `file`; file fixtures are existing temporary rollback-journal
files, not an OS power-loss or physical-device durability benchmark. Timers
include task transactions/commits but exclude seeding; seeding is reported.
All final rows/FIFO/attempts are asserted. Memory readings are process values.

A diagnostic JIT profile (initialization excluded) can be captured separately:

```sh
dart --observe=0 --disable-service-auth-codes --profiler --no-pause-isolates-on-exit run tool/jobs_performance/profile.dart 1000
```

It writes /tmp/jobs-processing-profile.json. Do not treat JIT sample counts as
AOT phase timings. Tests are run with the pinned tool/build_sqlite_reference.sh
reference and normal `dart test` in packages/sqlite_plus, or targeted test paths.
