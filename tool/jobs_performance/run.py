"""Fresh-process sequential AOT comparison; stop tests/compilers first."""
import json
import subprocess
from pathlib import Path

runs = []

def run(label, binary, args, iteration):
    process = subprocess.run([binary, *map(str, args)], capture_output=True,
                             text=True, check=True)
    result = json.loads(process.stdout.strip().splitlines()[-1])
    runs.append(dict(label=label, binary=binary, args=args,
                     iteration=iteration, result=result))
    Path('benchmark_results/jobs_performance/runs.json').write_text(
        json.dumps(runs, indent=2) + '\n')
    print(label, args, result, flush=True)


def order(iteration):
    return ['before', 'after'] if iteration % 2 == 0 else ['after', 'before']


for i in range(3):
    for variant in order(i):
        run('legacy-' + variant, '/tmp/jobs-' + variant + '-performance',
            [1000, 'batch', 10], i)

for args in [[100, 100], [1000, 10], [1000, 10, 'file']]:
    for i in range(3):
        for variant in order(i):
            run('phase-' + variant, '/tmp/jobs-processing-' + variant, args, i)

for args in [[1000, 1000], [10000, 10]]:
    for i in range(3):
        run('scale-after', '/tmp/jobs-processing-after', args, i)

for mode in ['read', 'insert', 'update', 'guarded']:
    for i in range(5):
        for variant in order(i):
            run('ordinary-' + variant, '/tmp/jobs-ordinary-' + variant,
                [mode, 1000], i)

# Preserve the earlier ORM import improvement under the core changes.
for i in range(3):
    for variant in order(i):
        run('import-' + variant, '/tmp/jobs-workflows-' + variant, ['import', 1000], i)
