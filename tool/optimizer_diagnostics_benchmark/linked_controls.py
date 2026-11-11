"""Pinned paired follow-up for remaining linked-OFF cases with noisy short runs."""
import json, os, statistics, subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics');cpu=min(os.sched_getaffinity(0));runs=[];summary=[]
original=json.loads((out/'runs.json').read_text())
for case in [1,6,9]:
    args=next(r['args'] for r in original if r['case']==case).copy();args[2]='off'
    if case==9:args[3]='1000'
    group=[]
    for trial in range(20):
        for label in (['before','after'] if trial%2==0 else ['after','before']):
            result=json.loads(subprocess.check_output(['taskset','-c',str(cpu),'/tmp/diagnostic-'+label,*args],text=True))
            row=dict(case=case,args=args,cpu=cpu,trial=trial,label=label,result=result);runs.append(row);group.append(row)
    for key in ['hash','result_rows','page_reads','image_bytes']:
        assert len({json.dumps(s['result'][key]) for s in group})==1,(case,key)
    row=dict(case=case,args=args,pairs=20,cpu=cpu)
    for label in ['before','after']:
        values=[s['result']['duration_us']/1000 for s in group if s['label']==label]
        row[label]={'samples':20,'median_ms':statistics.median(values),'min_ms':min(values),'max_ms':max(values)}
    ratios=[]
    for trial in range(20):
        pair={s['label']:s['result']['duration_us'] for s in group if s['trial']==trial};ratios.append(pair['after']/pair['before'])
    row['median_paired_ratio']=statistics.median(ratios);summary.append(row)
    print(json.dumps(row),flush=True)
    (out/'linked_runs.json').write_text(json.dumps(runs,indent=2)+'\n')
    (out/'linked_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
