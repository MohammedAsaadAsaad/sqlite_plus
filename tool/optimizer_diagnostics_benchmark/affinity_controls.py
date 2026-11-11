"""Separate CPU-affinity investigation; never pool with unpinned measurements."""
import json, os, statistics, subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics')
cpu=min(os.sched_getaffinity(0));samples=[];summary=[]
original=json.loads((out/'runs.json').read_text())
args=next(r['args'] for r in original if r['case']==7).copy();args[2]='off'
# Longer point workload avoids inferring a percentage from four milliseconds.
args[3]='1000'
cases=[('unused-read','/tmp/diagnostic-ordinary-',['read','1000']),('mutable-point-1000','/tmp/diagnostic-',args)]
for name,prefix,args in cases:
    group=[]
    for trial in range(30):
        for label in (['before','after'] if trial%2==0 else ['after','before']):
            result=json.loads(subprocess.check_output(['taskset','-c',str(cpu),prefix+label,*args],text=True))
            row=dict(name=name,cpu=cpu,trial=trial,label=label,args=args,result=result);samples.append(row);group.append(row)
    keys=['logical_sha256','image_sha256'] if name=='unused-read' else ['hash','result_rows','page_reads']
    for key in keys:
        assert len({json.dumps(s['result'][key]) for s in group})==1,(name,key)
    row={'name':name,'cpu':cpu,'affinity':'separate pinned investigation; not pooled'}
    for label in ['before','after']:
        values=[s['result']['duration_us']/1000 for s in group if s['label']==label]
        row[label]={'samples':len(values),'median_ms':statistics.median(values),'min_ms':min(values),'max_ms':max(values)}
    ratios=[]
    for trial in range(30):
        pair={s['label']:s['result']['duration_us'] for s in group if s['trial']==trial}
        ratios.append(pair['after']/pair['before'])
    row['median_paired_ratio']=statistics.median(ratios)
    summary.append(row)
    print(json.dumps(row),flush=True)
    (out/'affinity_runs.json').write_text(json.dumps(samples,indent=2)+'\n')
    (out/'affinity_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
