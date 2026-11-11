"""Compile binaries first, then run sequentially with tests/compilers stopped.
See benchmark_results/prepared/README.md for baseline preparation.
"""
import json
import subprocess
from pathlib import Path

runs = []

def run(binary, args, iteration):
    result = json.loads(subprocess.check_output([binary, *args], text=True).strip().splitlines()[-1])
    runs.append(dict(binary=binary, args=args, iteration=iteration, result=result))
    Path('benchmark_results/prepared/runs.json').write_text(json.dumps(runs, indent=2)+'\n')
    print(binary, args, result['duration_us'], flush=True)

for mode in ['read', 'update', 'orm']:
    for i in range(5):
        variants = ['ordinary', 'prepared'] + (['cache'] if mode=='orm' else [])
        if i%2: variants.reverse()
        for variant in variants:
            run('/tmp/prepared-benchmark', [mode, variant], i)

for mode in ['read', 'insert', 'update', 'guarded']:
    for i in range(5):
        variants = ['before', 'after'] if i%2==0 else ['after', 'before']
        for variant in variants:
            run('/tmp/prepared-ordinary-'+variant, [mode, '1000'], i)

for i in range(5):
    variants = ['before', 'after'] if i%2==0 else ['after', 'before']
    for variant in variants:
        run('/tmp/prepared-orm-ordinary-'+variant, [], i)

for i in range(5):
    variants = ['ordinary', 'prepared'] if i%2==0 else ['prepared', 'ordinary']
    for variant in variants:
        run('/tmp/prepared-syntax', [variant], i)
