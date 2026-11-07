"""Build both revisions with one SDK; temporarily substitutes one engine file.

Do not run tests/builds concurrently. The baseline file is reconstructed from the
recorded reverse patch (see OPTIMIZATION.md). Restoration is in a finally block.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

engine = Path('packages/sqlite_plus/lib/src/sql/image_mutations.dart')
current = engine.read_bytes()
baseline = Path(sys.argv[1]).read_bytes()
recorded = json.loads(Path('benchmark_results/changes_optimization/runtime.json').read_text())
assert hashlib.sha256(baseline).hexdigest() == recorded['before'][str(engine)]
assert hashlib.sha256(current).hexdigest() == recorded['after'][str(engine)]
for name, digest in recorded['after'].items():
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest, name
workloads = {
    'enabled': 'packages/sqlite_plus_changes/benchmark/enabled.dart',
    'disabled': 'tool/changes_benchmark/after.dart',
}
try:
    for revision, source in [('old', baseline), ('new', current)]:
        engine.write_bytes(source)
        for workload, path in workloads.items():
            subprocess.run(['dart', '--suppress-analytics', 'compile', 'exe', path,
                            '-o', f'/tmp/changes-opt-{revision}-{workload}'], check=True)
finally:
    engine.write_bytes(current)
Path('benchmark_results/changes_optimization/workloads.json').write_text(json.dumps({
    path: hashlib.sha256(Path(path).read_bytes()).hexdigest()
    for path in [*workloads.values(), 'tool/changes_benchmark/workload.dart',
                 *map(str, sorted(Path('packages/sqlite_plus_changes/lib').rglob('*.dart'))) ]
}, indent=2) + '\n')
