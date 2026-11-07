"""Compare trigger snapshot optimization using prebuilt before/after AOT binaries.

Run from repository root. No builds/tests should run concurrently with this.
Arguments: old-enabled new-enabled old-disabled new-disabled.
Enabled executable accepts positional rows, samples, updates (enabled.dart).
"""
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys

out = Path('benchmark_results/changes_optimization')
out.mkdir(parents=True, exist_ok=True)
old_enabled, new_enabled, old_disabled, new_disabled = sys.argv[1:]
binaries = dict(old_enabled=old_enabled, new_enabled=new_enabled,
                old_disabled=old_disabled, new_disabled=new_disabled)
metadata = {name: {'path': path, 'bytes': Path(path).stat().st_size,
                  'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest()}
            for name, path in binaries.items()}
(out / 'binaries.json').write_text(json.dumps(metadata, indent=2) + '\n')
sources = json.loads((out / 'workloads.json').read_text())
for name, digest in sources.items():
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest, name
runtime = json.loads((out / 'runtime.json').read_text())['after']
for name, digest in runtime.items():
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest, name
records = []
with (out / 'pairs.jsonl').open('w') as stream:
    for rows in [1000, 10000]:
        for workload in ['disabled', 'enabled']:
            for pair in range(5):
                order = ['old', 'new'] if pair % 2 == 0 else ['new', 'old']
                paired = {}
                for label in order:
                    args = [binaries[f'{label}_{workload}'], str(rows)]
                    if workload == 'enabled':
                        args += ['1', '100' if rows == 1000 else '10']
                    result = subprocess.run(args, check=True, capture_output=True, text=True)
                    record = json.loads(result.stdout)
                    if workload == 'enabled':
                        assert len(record['samples']) == 2
                    record.update(label=label, workload=workload, pair=pair)
                    paired[label] = record
                    records.append(record)
                    stream.write(json.dumps(record) + '\n')
                    stream.flush()
                    print(f'{rows} {workload} pair {pair+1}: {label} complete', flush=True)
                if workload == 'disabled':
                    assert paired['old']['image_sha256'] == paired['new']['image_sha256']
                    assert paired['old']['image_bytes'] == paired['new']['image_bytes']
                else:
                    for mode in [False, True]:
                        left = next(r for r in paired['old']['samples'] if r['enabled'] == mode)
                        right = next(r for r in paired['new']['samples'] if r['enabled'] == mode)
                        for metric in ['source_bytes', 'ready_bytes', 'logged_bytes', 'after_prune_bytes']:
                            assert left[metric] == right[metric]
summary = {}
for rows in [1000, 10000]:
    entry = {'updates': 100 if rows == 1000 else 10}
    def stats(values):
        return dict(median=statistics.median(values), min=min(values), max=max(values))
    disabled = {label: [r for r in records if r['rows'] == rows and r['workload'] == 'disabled' and r['label'] == label]
                for label in ['old', 'new']}
    entry['disabled'] = {metric: {label: stats([r['timings_us'][metric] for r in rs]) for label, rs in disabled.items()}
                         for metric in disabled['old'][0]['timings_us']}
    entry['disabled_images_equal'] = len({r['image_sha256'] for rs in disabled.values() for r in rs}) == 1
    entry['image_bytes'] = disabled['old'][0]['image_bytes']
    entry['memory'] = {metric: {label: stats([r[metric] for r in rs]) for label, rs in disabled.items()}
                       for metric in ['rss', 'peak_rss']}
    enabled = {label: [s for r in records if r['rows'] == rows and r['workload'] == 'enabled' and r['label'] == label for s in r['samples']]
               for label in ['old', 'new']}
    entry['enabled'] = {metric: {label: {str(mode): stats([r[metric] for r in rs if r['enabled'] == mode]) for mode in [False, True]}
                                for label, rs in enabled.items()}
                        for metric in ['activation_us','update_us','read_us','source_bytes','ready_bytes','logged_bytes','after_prune_bytes','rss']}
    summary[str(rows)] = entry
(out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
for name, digest in {**sources, **runtime}.items():
    assert hashlib.sha256(Path(name).read_bytes()).hexdigest() == digest, name
print('comparison complete', flush=True)
