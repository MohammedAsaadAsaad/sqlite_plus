"""Paired current-existing binary versus Sync-linked disabled mixed workload.
Run without other tests/builds. Baseline binary predates this Sync task.
"""
import hashlib
import json
from pathlib import Path
import statistics
import subprocess

out=Path('benchmark_results/sync')
binaries={'before':'/tmp/changes-opt-new-disabled','disabled':'/tmp/sync-disabled'}
before_runtime=json.loads(Path('benchmark_results/changes_optimization/runtime.json').read_text())['after']
runtime={p:hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in before_runtime}
changed=[p for p in runtime if runtime[p]!=before_runtime[p]]
assert set(changed)=={'packages/sqlite_plus/lib/src/btree/rowid_page_patch.dart','packages/sqlite_plus/lib/src/sql/image_mutations.dart'}
workload=Path('tool/changes_benchmark/workload.dart')
old=json.loads(Path('benchmark_results/changes_optimization/workloads.json').read_text())
assert hashlib.sha256(workload.read_bytes()).hexdigest()==old[str(workload)]
manifest={'existing_runtime_unchanged':len(runtime)-len(changed),'changed_existing_runtime':changed,'before_runtime':before_runtime,'binaries':{label:{'bytes':Path(p).stat().st_size,'sha256':hashlib.sha256(Path(p).read_bytes()).hexdigest()} for label,p in binaries.items()},'runtime':runtime,
 'package_runtime':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for folder in ['packages/sqlite_plus_changes/lib','packages/sqlite_plus_sync/lib'] for p in sorted(Path(folder).rglob('*.dart'))},'baseline_package_runtime':{k:v for k,v in old.items() if k.startswith('packages/sqlite_plus_changes/lib/')},'workload_sha256':hashlib.sha256(workload.read_bytes()).hexdigest()}
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
records=[]
with (out/'disabled_pairs.jsonl').open('w') as stream:
 for rows in [1000,10000]:
  for pair in range(5):
   group={}
   for label in (['before','disabled'] if pair%2==0 else ['disabled','before']):
    result=subprocess.run([binaries[label],str(rows)],check=True,capture_output=True,text=True)
    record=json.loads(result.stdout);record.update(label=label,pair=pair)
    group[label]=record;records.append(record);stream.write(json.dumps(record)+'\n');stream.flush()
    print(f'{rows} pair {pair+1}: {label} complete',flush=True)
   assert group['before']['image_sha256']==group['disabled']['image_sha256']
summary={}
for rows in [1000,10000]:
 groups={label:[r for r in records if r['rows']==rows and r['label']==label] for label in binaries}
 def stats(v):return {'median':statistics.median(v),'min':min(v),'max':max(v)}
 summary[str(rows)]={'timings':{m:{label:stats([r['timings_us'][m] for r in rs]) for label,rs in groups.items()} for m in groups['before'][0]['timings_us']},'image_bytes':groups['before'][0]['image_bytes'],
  'all_images_equal':len({r['image_sha256'] for rs in groups.values() for r in rs})==1,
  'memory':{m:{label:stats([r[m] for r in rs]) for label,rs in groups.items()} for m in ['rss','peak_rss']}}
(out/'disabled_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('disabled complete; running enabled sample',flush=True)
result=subprocess.run(['/tmp/sync-enabled'],check=True,capture_output=True,text=True)
json.loads(result.stdout);(out/'enabled_100.json').write_text(result.stdout)
for p,h in {**runtime,**manifest['package_runtime']}.items():assert hashlib.sha256(Path(p).read_bytes()).hexdigest()==h,p
print('comparison complete',flush=True)
