"""Sequential AOT comparison. Run from repository root after compiling binaries."""
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

out = Path('benchmark_results/changes')
before = json.loads((out / 'runtime_before.json').read_text())
current = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
           for folder in ['packages/sqlite_plus/lib', 'packages/sqlite_plus_search/lib']
           for p in sorted(Path(folder).rglob('*.dart'))}
assert current == before, 'Existing runtime changed; baseline needs recapturing'
(out / 'runtime_after.json').write_text(json.dumps(current, indent=2) + '\n')
samples = []
with (out / 'disabled_pairs.jsonl').open('w') as stream:
    for rows in [1000, 10000]:
        for pair in range(5):
            results = {}
            order = ['before', 'disabled'] if pair % 2 == 0 else ['disabled', 'before']
            for label in order:
                binary = '/tmp/changes-before' if label == 'before' else '/tmp/changes-after'
                result = subprocess.run([binary, str(rows)], check=True, capture_output=True, text=True)
                record = json.loads(result.stdout)
                record.update(label=label, pair=pair)
                samples.append(record)
                results[label] = record
                stream.write(json.dumps(record) + '\n')
                stream.flush()
                print(f'{rows} pair {pair + 1}/5 {label} complete', flush=True)
            assert results['before']['image_sha256'] == results['disabled']['image_sha256']
            assert results['before']['image_bytes'] == results['disabled']['image_bytes']
summary = {}
for rows in [1000, 10000]:
    groups = {label: [r for r in samples if r['rows'] == rows and r['label'] == label]
              for label in ['before', 'disabled']}
    metrics = {}
    for metric in groups['before'][0]['timings_us']:
        values = {label: [r['timings_us'][metric] for r in records] for label, records in groups.items()}
        entry = {label: {'median_us': statistics.median(v), 'min_us': min(v), 'max_us': max(v)}
                 for label, v in values.items()}
        entry['median_delta_percent'] = 100 * (entry['disabled']['median_us'] / entry['before']['median_us'] - 1)
        metrics[metric] = entry
    summary[str(rows)] = {
        'timings': metrics, 'image_bytes': groups['before'][0]['image_bytes'],
        'all_image_hashes_equal': len({r['image_sha256'] for r in samples if r['rows'] == rows}) == 1,
        'rss_medians': {label: statistics.median(r['rss'] for r in records) for label, records in groups.items()},
        'peak_rss_medians': {label: statistics.median(r['peak_rss'] for r in records) for label, records in groups.items()}}
(out / 'disabled_summary.json').write_text(json.dumps(summary, indent=2) + '\n')
metadata = {'runtime_files_unchanged': len(current),
            'workload_sha256': hashlib.sha256(Path('tool/changes_benchmark/workload.dart').read_bytes()).hexdigest(),
            'binaries': {label: {'bytes': Path(binary).stat().st_size,
                               'sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest()}
                        for label, binary in [('before', '/tmp/changes-before'), ('disabled', '/tmp/changes-after')]}}
(out / 'measurement.json').write_text(json.dumps(metadata, indent=2) + '\n')
print('disabled comparison complete; running enabled sample', flush=True)
result = subprocess.run(['/tmp/changes-enabled'], check=True, capture_output=True, text=True)
json.loads(result.stdout)
(out / 'enabled_1000.json').write_text(result.stdout)
print('enabled comparison complete', flush=True)
