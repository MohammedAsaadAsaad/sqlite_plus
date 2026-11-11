"""Run compiled AOT jobs driver sequentially, without concurrent test workloads."""
import json
import subprocess
from pathlib import Path

runs = []
workloads = [(i, 100, mode, 100) for i in range(3)
             for mode in (['batch', 'individual'] if i % 2 == 0 else ['individual', 'batch'])]
# Larger queue, ten claim/complete pairs per process; no full drain claim.
workloads.extend((i, 1000, 'batch', 10) for i in range(3))
for iteration, count, mode, processed in workloads:
    result = subprocess.run(['/tmp/jobs-benchmark', str(count), mode, str(processed)],
                            capture_output=True, text=True, check=True)
    runs.append(dict(iteration=iteration, result=json.loads(result.stdout)))
    Path('benchmark_results/jobs/runs.json').write_text(json.dumps(runs, indent=2) + '\n')
    print(count, mode, runs[-1]['result'], flush=True)
