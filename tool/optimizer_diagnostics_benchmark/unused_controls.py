"""Same-source AOT applications that never call diagnosis: reads/writes/ORM."""
import json
import statistics
import subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics');runs=[];summary=[]
cases=[('ordinary',[mode,'1000']) for mode in ['read','insert','update','guarded']]+[('orm',[]),('update',[])]
for kind,args in cases:
    batch=[]
    for i in range(5):
        for label in (['before','after'] if i%2==0 else ['after','before']):
            result=json.loads(subprocess.check_output(['/tmp/diagnostic-'+kind+'-'+label,*args],text=True))
            row=dict(kind=kind,args=args,iteration=i,variant=label,result=result);runs.append(row);batch.append(row)
            (out/'unused_runs.json').write_text(json.dumps(runs,indent=2)+'\n');print(kind,args,i,label,result['duration_us'],flush=True)
    for key in (['logical_sha256','image_sha256','image_bytes'] if kind=='ordinary' else ['checksum','image_bytes']):
        assert len({json.dumps(r['result'][key]) for r in batch})==1,(kind,args,key)
    row={'kind':kind,'args':args}
    for label in ['before','after']:
        times=[r['result']['duration_us']/1000 for r in batch if r['variant']==label]
        row[label]={'median_ms':statistics.median(times),'min_ms':min(times),'max_ms':max(times)}
    row['after_over_before']=row['after']['median_ms']/row['before']['median_ms'];summary.append(row)
    (out/'unused_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
