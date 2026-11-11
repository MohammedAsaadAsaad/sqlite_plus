"""Verify this checkpoint from a fresh checkout, without the original /tmp files.

Run before changing runtime source. A later milestone needs its own evidence;
do not edit historical hashes just to make this checkpoint pass.
"""
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def reverse(stage, relative):
    result = subprocess.run(
        ['patch', '--batch', '-R', '-p1', '-d', str(stage), '-i', str(ROOT/relative)],
        capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f'Cannot reconstruct {relative}:\n{result.stdout}\n{result.stderr}')

ledger = (ROOT/'docs/plans/OPTIMIZER.md').read_text()
ids = [int(x) for x in re.findall(r'^\|\s*(\d+)\s*\|', ledger, re.M)]
assert ids == list(range(1, 43)), 'Roadmap must retain all 42 stable IDs'
manifest = json.loads((ROOT/'benchmark_results/optimizer/after_manifest.json').read_text())
for relative, expected in manifest['source_sha256'].items():
    assert digest(ROOT/relative) == expected, f'Runtime differs from measured checkpoint: {relative}'
with tempfile.TemporaryDirectory(prefix='sqlite-plus-handoff-') as directory:
    stage = Path(directory)
    for name in ['sqlite_plus', 'sqlite_plus_orm']:
        target = stage/'packages'/name
        target.mkdir(parents=True)
        shutil.copytree(ROOT/'packages'/name/'lib', target/'lib')
    reverse(stage, 'benchmark_results/optimizer/baseline.patch')
    before = json.loads((ROOT/'benchmark_results/optimizer/before_manifest.json').read_text())
    for relative, expected in before['libraries'].items():
        assert digest(stage/relative) == expected, f'Optimizer baseline mismatch: {relative}'
    actual = {str(p.relative_to(stage)) for p in (stage/'packages').rglob('*.dart')}
    assert actual == set(before['libraries']), 'Unexpected reconstructed baseline files'
    # Prepared measurements precede the optimizer: undo milestones in reverse
    # chronological order rather than retaining newer sorting code in a baseline.
    reverse(stage, 'benchmark_results/prepared/baseline.patch')
    prepared = json.loads((ROOT/'benchmark_results/prepared/before_manifest.json').read_text())
    for relative, expected in prepared['source_sha256'].items():
        assert digest(stage/relative) == expected, f'Prepared baseline mismatch: {relative}'
summary = json.loads((ROOT/'benchmark_results/optimizer/summary.json').read_text())
runs = json.loads((ROOT/'benchmark_results/optimizer/runs.json').read_text())
assert {row['case'] for row in summary} == set(range(27))
assert len(runs) == 270
for case in range(27):
    rows = [row for row in runs if row['case'] == case]
    for variant in ['before', 'after']:
        assert len([row for row in rows if row['variant'] == variant]) == 5
    for key in ['hashes', 'result_rows', 'image_bytes', 'reads', 'read_bytes',
                'callback_trace_sha256', 'callback_count', 'visits', 'access']:
        assert len({json.dumps(row['result'][key]) for row in rows}) == 1, (case, key)
print('Handoff verified: 42 items; measured runtime hashes; reconstructed optimizer/prepared baselines; 27 cases / 270 samples and equivalence gates.')
