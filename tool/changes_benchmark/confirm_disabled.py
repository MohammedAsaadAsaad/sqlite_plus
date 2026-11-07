"""Additional 1k paired runs to investigate positive disabled timing medians."""
import json
from pathlib import Path
import resource
import statistics
import subprocess
import time

out = Path('benchmark_results/changes_optimization')
records = []
with (out / 'disabled_confirmation.jsonl').open('w') as stream:
    for pair in range(10):
        group = {}
        for label in (['old', 'new'] if pair % 2 == 0 else ['new', 'old']):
            usage_before = resource.getrusage(resource.RUSAGE_CHILDREN)
            start = time.monotonic()
            result = subprocess.run([f'/tmp/changes-opt-{label}-disabled', '1000'], check=True, capture_output=True, text=True)
            wall = time.monotonic() - start
            usage_after = resource.getrusage(resource.RUSAGE_CHILDREN)
            record = json.loads(result.stdout)
            record.update(pair=pair, label=label, wall_seconds=wall,
                          cpu_seconds=usage_after.ru_utime+usage_after.ru_stime-usage_before.ru_utime-usage_before.ru_stime)
            records.append(record)
            group[label] = record
            stream.write(json.dumps(record) + '\n')
            stream.flush()
        assert group['old']['image_sha256'] == group['new']['image_sha256']
        print(f'confirmation pair {pair+1} complete', flush=True)
summary = {}
for metric in [*records[0]['timings_us'], 'cpu_seconds', 'wall_seconds']:
    groups = {label: [(r[metric] if metric.endswith('seconds') else r['timings_us'][metric]) for r in records if r['label'] == label] for label in ['old','new']}
    summary[metric] = {label: dict(median=statistics.median(values), min=min(values), max=max(values)) for label, values in groups.items()}
(out / 'disabled_confirmation_summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print('confirmation complete', flush=True)
