"""Run already-compiled before/after AOT binaries without concurrent workloads."""
import json
import subprocess
import time
from pathlib import Path

OUTPUT = Path('benchmark_results/import_performance/runs.json')
runs = []


def run(binary, args, label):
    started = time.time()
    process = subprocess.run([binary, *map(str, args)], capture_output=True,
                             text=True, check=True)
    result = json.loads(process.stdout.strip().splitlines()[-1])
    runs.append(dict(label=label, binary=binary, args=args,
                     wall_seconds=time.time() - started, result=result))
    OUTPUT.write_text(json.dumps(runs, indent=2) + '\n')
    print(label, args, result, flush=True)


def order(iteration):
    return ['before', 'after'] if iteration % 2 == 0 else ['after', 'before']


for iteration in range(3):
    for variant in order(iteration):
        binary = ('/tmp/workflows-benchmark' if variant == 'before'
                  else '/tmp/workflows-optimized')
        run(binary, ['import', 1000], variant)

for mode in ['read', 'insert', 'update']:
    for iteration in range(5):
        for variant in order(iteration):
            run('/tmp/import-ordinary-' + variant, [mode, 1000],
                'ordinary-' + variant)

for mode in ['insert', 'update', 'mixed']:
    for variant in ['before', 'after']:
        run('/tmp/import-shapes-' + variant, [100, mode], 'sku-' + variant)

for mode in ['insert', 'update', 'mixed']:
    for iteration in range(3):
        run('/tmp/import-shapes-after', [1000, mode], 'sku-after')

for iteration in range(3):
    run('/tmp/workflows-optimized', ['import', 10000], 'scale-after')
