"""Build isolated AOT variants; never modify the working checkout.

Run after configuring the Dart SDK/PUB_CACHE:
  python3 tool/reactive_benchmark/reproduce.py
Pass --runs to execute the five-pair/two-size comparison (several minutes).
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASELINE = 'b918a160249069d8b5fc206a3ee609826562a2d3'
DART = shutil.which('dart')
if DART is None:
    raise SystemExit('Configure the Dart SDK on PATH first')
OUTPUT = Path(tempfile.mkdtemp(prefix='sqlite-plus-reactive-benchmark-'))
# Only source/configuration required by the Dart workspace, not build products.
for name in ['pubspec.yaml', 'pubspec.lock']:
    if (ROOT / name).exists():
        shutil.copy2(ROOT / name, OUTPUT / name)
for line in (ROOT / 'pubspec.yaml').read_text().splitlines():
    if not line.startswith('  - '):
        continue
    relative = line[4:].strip()
    source = ROOT / relative
    target = OUTPUT / relative
    target.mkdir(parents=True, exist_ok=True)
    for name in ['pubspec.yaml', 'analysis_options.yaml']:
        if (source / name).exists():
            shutil.copy2(source / name, target / name)
    if (source / 'lib').exists():
        shutil.copytree(source / 'lib', target / 'lib', dirs_exist_ok=True)
shutil.copytree(ROOT / 'tool/reactive_benchmark', OUTPUT / 'tool/reactive_benchmark')
subprocess.run([DART, 'pub', 'get', '--offline'], cwd=OUTPUT, check=True)
# Compile current code with runtime-reachable optional watch branch.
after = OUTPUT / 'after'
subprocess.run([DART, 'compile', 'exe', 'tool/reactive_benchmark/after.dart',
                '-o', str(after)], cwd=OUTPUT, check=True)
# Restore only pre-feature ORM runtime. Core stays the matching workspace engine.
manifest = json.loads((ROOT / 'benchmark_results/reactive/runtime_before.json').read_text())
for path, expected in manifest.items():
    if not path.startswith('packages/sqlite_plus_orm/lib/'):
        continue
    content = subprocess.check_output(['git', 'show', BASELINE + ':' + path], cwd=ROOT)
    if hashlib.sha256(content).hexdigest() != expected:
        raise RuntimeError('Baseline hash mismatch: ' + path)
    (OUTPUT / path).write_bytes(content)
before = OUTPUT / 'before'
subprocess.run([DART, 'compile', 'exe', 'tool/reactive_benchmark/before.dart',
                '-o', str(before)], cwd=OUTPUT, check=True)
print('Isolated binaries:', OUTPUT)
if '--runs' in sys.argv:
    runs = []
    for count in [100, 1000]:
        for iteration in range(5):
            variants = ['before', 'after'] if iteration % 2 == 0 else ['after', 'before']
            for variant in variants:
                row = json.loads(subprocess.check_output([str(OUTPUT / variant), str(count)]))
                row.update(variant=variant, iteration=iteration)
                runs.append(row)
        for iteration in range(3):
            row = json.loads(subprocess.check_output([str(after), str(count), '--watch']))
            row.update(variant='enabled', iteration=iteration)
            runs.append(row)
    (OUTPUT / 'runs.json').write_text(json.dumps(runs, indent=2) + '\n')
    print('Raw results:', OUTPUT / 'runs.json')
