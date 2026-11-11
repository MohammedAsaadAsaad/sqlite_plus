"""Unprepared ordinary reads/writes and default ORM cache-off comparison."""
import json
import statistics
import subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer')
runs=[]
cases=[('ordinary',[mode,'1000']) for mode in ['read','insert','update','guarded']]+[('orm',[])]
summary=[]
for kind,args in cases:
    group=[]
    for i in range(5):
        for variant in (['before','after'] if i%2==0 else ['after','before']):
            r=json.loads(subprocess.check_output(['/tmp/optimizer-'+kind+'-'+variant,*args],text=True));entry=dict(kind=kind,args=args,iteration=i,variant=variant,result=r);runs.append(entry);group.append(entry)
            (out/'regression_runs.json').write_text(json.dumps(runs,indent=2)+'\n')
            print(kind,args,variant,r['duration_us'],flush=True)
    for key in (['logical_sha256','image_sha256','image_bytes'] if kind=='ordinary' else ['checksum','image_bytes']):
        assert len({r['result'][key] for r in group})==1,(kind,args,key)
    result=dict(kind=kind,args=args)
    for variant in ['before','after']:
        times=[r['result']['duration_us']/1000 for r in group if r['variant']==variant]
        result[variant]={'median_ms':statistics.median(times),'min_ms':min(times),'max_ms':max(times)}
    result['after_over_before']=result['after']['median_ms']/result['before']['median_ms'];summary.append(result)
    (out/'regression_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
