"""Run after tests/compilers stop; arguments: baseline-exe repaired-exe image."""
import hashlib
import json
import statistics
import subprocess
import sys
from pathlib import Path

baseline, repaired, image = map(Path, sys.argv[1:])
out = Path(__file__).parent
samples = []
summary = {}
for case, k, offset, mode in [
    ('small_k', 20, 0, 'ordered'),
    ('large_k', 1000, 0, 'ordered'),
    ('unlimited', -1, 0, 'ordered'),
    ('point', 9999, 0, 'point'),
    ('callbacks', 32, 0, 'callbacks'),
]:
    group = []
    for pair in range(5):
        variants = [('baseline', baseline), ('repaired', repaired)]
        if pair % 2:
            variants.reverse()
        for variant, binary in variants:
            result = json.loads(subprocess.check_output(
                [str(binary), str(image), str(k), str(offset), '1', mode, 'memory'], text=True))
            row = dict(case=case, pair=pair, variant=variant, result=result)
            samples.append(row)
            group.append(row)
    for key in ['hashes', 'result_rows', 'reads', 'read_bytes',
                'callback_trace_sha256', 'callback_count', 'visits', 'image_bytes']:
        assert len({json.dumps(row['result'][key], sort_keys=True) for row in group}) == 1, (case, key)
    def times(variant):
        return [r['result']['duration_us'] for r in group if r['variant'] == variant]
    before, after = times('baseline'), times('repaired')
    summary[case] = dict(baseline_median_us=statistics.median(before),
                         repaired_median_us=statistics.median(after),
                         ratio=statistics.median(after) / statistics.median(before),
                         baseline_range_us=[min(before), max(before)],
                         repaired_range_us=[min(after), max(after)])
    for metric in ['peak_rss', 'explain_us']:
        for variant in ['baseline', 'repaired']:
            summary[case][variant + '_' + metric + '_median'] = statistics.median(
                r['result'][metric] for r in group if r['variant'] == variant)
    print(case, summary[case], flush=True)
report = dict(baseline_commit='91a85454354e4610919688de82221086edd86b35',
              samples=len(samples), summary=summary,
              binary_sha256={name: hashlib.sha256(path.read_bytes()).hexdigest()
                             for name, path in [('baseline', baseline), ('repaired', repaired)]},
              image_sha256=hashlib.sha256(image.read_bytes()).hexdigest(),
              limitation='Linux x64 AOT, five alternating fresh-process pairs per case; timing includes query planning. Scoped controls only, not acceptance of every roadmap optimization or a universal no-overhead claim.')
(out / 'aot_controls.json').write_text(json.dumps(report, indent=2) + '\n')
(out / 'aot_samples.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in samples))
