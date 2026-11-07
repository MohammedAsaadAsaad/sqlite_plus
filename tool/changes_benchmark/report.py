"""Refresh measured tables after compare.py; keeps explanatory contract text."""
import json
from pathlib import Path
import re
import statistics

root = Path('benchmark_results/changes')
summary = json.loads((root / 'disabled_summary.json').read_text())
enabled = json.loads((root / 'enabled_1000.json').read_text())
measurement = json.loads((root / 'measurement.json').read_text())
path = Path('packages/sqlite_plus_changes/benchmark/RESULTS.md')
text = path.read_text()
rows = []
for count, result in summary.items():
    for name, values in result['timings'].items():
        rows.append(f"| {count} | {name} | {values['before']['median_us']/1000:.3f} | {values['disabled']['median_us']/1000:.3f} | {values['median_delta_percent']:+.2f}% |")
text = re.sub(r'(?m)^\| 1000 \| insert \|.*?(?=\n\n)', '\n'.join(rows), text, count=1, flags=re.S)
rows = [f"| {count} | {r['rss_medians']['before']:,} / {r['rss_medians']['disabled']:,} | {r['peak_rss_medians']['before']:,} / {r['peak_rss_medians']['disabled']:,} |" for count, r in summary.items()]
text = re.sub(r'(?m)^\| 1000 \| [0-9,]+ /.*?(?=\n\n)', '\n'.join(rows), text, count=1, flags=re.S)
metrics = [('activation_us','Open + track + consumer',1000,' ms'),('update_100_us','100 UPDATE statements',1000,' ms'),('read_us','Read 100 events',1000,' ms'),('source_bytes','Source image',1,' bytes'),('ready_bytes','Ready image',1,' bytes'),('logged_bytes','Image after writes',1,' bytes'),('after_prune_bytes','Image after prune',1,' bytes')]
rows = []
for key, label, divisor, suffix in metrics:
    values = [statistics.median(r[key] for r in enabled['samples'] if r['enabled'] == mode)/divisor for mode in [False, True]]
    formatted = [f'{v:,.3f}{suffix}' if divisor != 1 else f'{v:,.0f}{suffix}' for v in values]
    rows.append(f'| {label} | {formatted[0]} | {formatted[1]} |')
text = re.sub(r'(?m)^\| Open \+ track \+ consumer \|.*?(?=\n\n)', '\n'.join(rows), text, count=1, flags=re.S)
binary_delta = measurement['binaries']['disabled']['bytes'] - measurement['binaries']['before']['bytes']
text = re.sub(r'The linked disabled binary is [0-9,]+ bytes', f'The linked disabled binary is {binary_delta:,} bytes', text)
baseline = statistics.median(r['update_100_us'] for r in enabled['samples'] if not r['enabled'])
tracked = statistics.median(r['update_100_us'] for r in enabled['samples'] if r['enabled'])
text = re.sub(r'is about [0-9.]+x slower', f'is about {tracked/baseline:.1f}x slower', text)
path.write_text(text)
readme = Path('packages/sqlite_plus_changes/README.md')
text = readme.read_text()
text = re.sub(r'[0-9.]+ s without tracking versus [0-9.]+ s with tracking', f'{baseline/1e6:.3f} s without tracking versus {tracked/1e6:.3f} s with tracking', text)
text = text.replace('34 tests including', '35 tests including')
readme.write_text(text)
