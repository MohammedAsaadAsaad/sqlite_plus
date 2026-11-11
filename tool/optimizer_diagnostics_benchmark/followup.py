"""Keep initial samples; investigate slower OFF controls with 15 extra pairs."""
import json
import statistics
import subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics');runs=[];summary=[]
initial_main=json.loads((out/'runs.json').read_text());initial_unused=json.loads((out/'unused_runs.json').read_text())
cases=[('unused-read',None),('linked-point-reader',0),('linked-point-mutable',7),('linked-large-sort',4)]
for name,case in cases:
    if case is None:
        prefix='/tmp/diagnostic-ordinary-';args=['read','1000']
        original=[r for r in initial_unused if r['kind']=='ordinary' and r['args']==args]
        labels=['before','after']
    else:
        sample=next(r for r in initial_main if r['case']==case)
        args=sample['args'].copy();args[2]='off';prefix='/tmp/diagnostic-'
        original=[r for r in initial_main if r['case']==case and r['variant'] in ['baseline-off','linked-off']]
        labels=['baseline-off','linked-off']
    group=[]
    for i in range(15):
        for label in (labels if i%2==0 else labels[::-1]):
            binary=label if case is None else 'before' if label=='baseline-off' else 'after'
            result=json.loads(subprocess.check_output([prefix+binary,*args],text=True))
            row=dict(name=name,iteration=i,variant=label,args=args,result=result);runs.append(row);group.append(row)
            (out/'followup_runs.json').write_text(json.dumps(runs,indent=2)+'\n');print(name,i,label,result['duration_us'],flush=True)
    combined=original+group
    for key in (['logical_sha256','image_sha256'] if case is None else ['hash','result_rows','page_reads']):
        assert len({json.dumps(r['result'][key]) for r in combined})==1,(name,key)
    row={'name':name}
    for label in labels:
        times=[r['result']['duration_us']/1000 for r in combined if r['variant']==label];assert len(times)==20
        row[label]={'samples':20,'median_ms':statistics.median(times),'min_ms':min(times),'max_ms':max(times)}
    row['after_over_before']=row[labels[1]]['median_ms']/row[labels[0]]['median_ms'];summary.append(row)
    (out/'followup_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
