"""Longer pinned controls, separate from original short unpinned workloads."""
import json, os, statistics, subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics');cpu=min(os.sched_getaffinity(0));runs=[];summary=[]
cases=[('ordinary',[mode,'10000'],20) for mode in ['insert','update']]+[('orm',[],10),('update',[],20)]
for kind,args,pairs in cases:
    group=[]
    for trial in range(pairs):
        for label in (['before','after'] if trial%2==0 else ['after','before']):
            result=json.loads(subprocess.check_output(['taskset','-c',str(cpu),'/tmp/diagnostic-'+kind+'-'+label,*args],text=True))
            row=dict(kind=kind,args=args,cpu=cpu,trial=trial,label=label,result=result);runs.append(row);group.append(row)
    keys=['logical_sha256','image_sha256','image_bytes'] if kind=='ordinary' else ['checksum','image_bytes']
    for key in keys:assert len({json.dumps(s['result'][key]) for s in group})==1,(kind,args,key)
    row=dict(kind=kind,args=args,pairs=pairs,cpu=cpu)
    for label in ['before','after']:
        values=[s['result']['duration_us']/1000 for s in group if s['label']==label]
        row[label]={'samples':len(values),'median_ms':statistics.median(values),'min_ms':min(values),'max_ms':max(values)}
    ratios=[]
    for trial in range(pairs):
        pair={s['label']:s['result']['duration_us'] for s in group if s['trial']==trial};ratios.append(pair['after']/pair['before'])
    row['median_paired_ratio']=statistics.median(ratios);summary.append(row)
    print(json.dumps(row),flush=True)
    (out/'extended_runs.json').write_text(json.dumps(runs,indent=2)+'\n')
    (out/'extended_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
