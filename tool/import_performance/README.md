# Import performance tooling

Development-only native AOT measurements; no runtime dependency on Python,
vm_service or native SQLite. Run from workspace root using Dart 3.13.7.

Compile `tool/workflows_benchmark/main.dart` to `/tmp/workflows-optimized`,
`shape_benchmark.dart` to `/tmp/import-shapes-after`, and
`ordinary_benchmark.dart` to `/tmp/import-ordinary-after` with `dart compile exe`.
Keep the preceding milestone's `/tmp/workflows-benchmark` binary for comparison.
For independent reproduction, use the before manifest's core source from the
base commit with the same current ORM/import/benchmark sources. Compile shape
and ordinary drivers against that old core to the corresponding `-before`
paths. An explicit package_config.json overriding only sqlite_plus is sufficient;
do not compare a historical ORM against the new one.

Stop other tests/compilers, then `python3 tool/import_performance/run_measurements.py`.
It records fresh sequential processes, rotating before/after order, in
`benchmark_results/import_performance/runs.json`. It overwrites that artifact;
archive existing samples before a rerun. Results validate complete logical rows
and include file hashes, sizes and process RSS. Timers exclude source seeding.
100-row SKU baselines are single probes; 1000-row candidate samples do not imply
a measured before/after ratio at that size.

Diagnostic CPU profile (JIT, whole workflow, not AOT timing):

```
dart --observe=0 --disable-service-auth-codes --profiler --no-pause-isolates-on-exit run tool/import_performance/profile.dart 1000
```

The driver writes `/tmp/import-cpu-profile.json`. VM service is local development
instrumentation only. Tests use the pinned reference via tool/build_sqlite_reference.sh.

Targeted ordinary-update follow-up (overwrites its artifact):

```sh
python3 - <<'PY'
import subprocess,json,pathlib
runs=[]
for i in range(12):
    for v in (['before','after'] if i%2==0 else ['after','before']):
        p=subprocess.run(['/tmp/import-ordinary-'+v,'update','1000'],capture_output=True,text=True,check=True)
        runs.append({'variant':v,'iteration':i,'result':json.loads(p.stdout)})
pathlib.Path('benchmark_results/import_performance/ordinary_update_followup.json').write_text(json.dumps(runs,indent=2)+'\n')
PY
```
