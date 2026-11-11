"""Verify portable accepted checkpoints, or explicitly inspect an unaccepted candidate.
Never change historical hashes to accommodate new runtime source.
"""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--allow-unaccepted-diagnostics',action='store_true',
                    help='Verify candidate baseline reconstruction only; does NOT accept item 3')
args=parser.parse_args()
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def reverse(stage,path):
    result=subprocess.run(['patch','--batch','-R','-p1','-d',str(stage),'-i',str(ROOT/path)],capture_output=True,text=True)
    if result.returncode:raise SystemExit(f'Cannot reconstruct {path}:\n{result.stdout}\n{result.stderr}')
ledger=(ROOT/'docs/plans/OPTIMIZER.md').read_text()
assert [int(x) for x in re.findall(r'^\|\s*(\d+)\s*\|',ledger,re.M)]==list(range(1,43))
diag=ROOT/'benchmark_results/optimizer_diagnostics'
has_diag=(diag/'baseline.patch').exists()
accepted=False
if has_diag:
    validation=json.loads((diag/'validation.json').read_text()) if (diag/'validation.json').exists() else {}
    accepted=validation.get('accepted',False)
    if not accepted and not args.allow_unaccepted_diagnostics:
        raise SystemExit('Item 3 is unaccepted. Inspect docs/AI_HANDOFF.md; use --allow-unaccepted-diagnostics to verify its candidate baseline without claiming acceptance.')
    if accepted:
        manifest=json.loads((diag/'after_manifest.json').read_text())
        for path,h in manifest['source_sha256'].items():assert digest(ROOT/path)==h,path
with tempfile.TemporaryDirectory(prefix='sqlite-plus-handoff-') as directory:
    stage=Path(directory)
    for name in ['sqlite_plus','sqlite_plus_orm','sqlite_plus_inspector']:
        target=stage/'packages'/name;target.mkdir(parents=True)
        shutil.copytree(ROOT/'packages'/name/'lib',target/'lib')
    if has_diag:
        reverse(stage,'benchmark_results/optimizer_diagnostics/baseline.patch')
        before=json.loads((diag/'before_manifest.json').read_text())
        for path,h in before['source_sha256'].items():assert digest(stage/path)==h,path
        actual={str(p.relative_to(stage)) for p in (stage/'packages').rglob('*.dart')}
        assert actual==set(before['source_sha256'])
    top=json.loads((ROOT/'benchmark_results/optimizer/after_manifest.json').read_text())
    for path,h in top['source_sha256'].items():assert digest(stage/path)==h,path
    reverse(stage,'benchmark_results/optimizer/baseline.patch')
    before=json.loads((ROOT/'benchmark_results/optimizer/before_manifest.json').read_text())
    for path,h in before['libraries'].items():assert digest(stage/path)==h,path
    actual={str(p.relative_to(stage)) for name in ['sqlite_plus','sqlite_plus_orm'] for p in (stage/'packages'/name).rglob('*.dart')}
    assert actual==set(before['libraries'])
    reverse(stage,'benchmark_results/prepared/baseline.patch')
    prepared=json.loads((ROOT/'benchmark_results/prepared/before_manifest.json').read_text())
    for path,h in prepared['source_sha256'].items():assert digest(stage/path)==h,path
summary=json.loads((ROOT/'benchmark_results/optimizer/summary.json').read_text())
runs=json.loads((ROOT/'benchmark_results/optimizer/runs.json').read_text())
assert {r['case'] for r in summary}==set(range(27)) and len(runs)==270
for case in range(27):
    rows=[r for r in runs if r['case']==case]
    for label in ['before','after']:assert len([r for r in rows if r['variant']==label])==5
    for key in ['hashes','result_rows','image_bytes','reads','read_bytes','callback_trace_sha256','callback_count','visits','access']:
        assert len({json.dumps(r['result'][key]) for r in rows})==1,(case,key)
print('Portable handoff verified: 42 IDs; current/candidate baseline chain; optimizer/prepared hashes; 27 cases / 270 samples.')
if has_diag and not accepted:print('Item 3 remains UNACCEPTED: baseline reconstruction is not performance/cost approval.')
