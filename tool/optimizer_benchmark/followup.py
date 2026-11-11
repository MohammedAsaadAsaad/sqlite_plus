"""Extra samples for initially slower controls; retain initial results too."""
import json
import statistics
import subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer')
runs=[]
cases=[('ordinary-read','/tmp/optimizer-ordinary-',['read','1000']),('ordinary-update','/tmp/optimizer-ordinary-',['update','1000']),('almost-full-tiny','/tmp/optimizer-',['/tmp/optimizer-64-random.db','63','0','50','sort','memory'])]
initial_reg=json.loads((out/'regression_runs.json').read_text())
initial_main=json.loads((out/'runs.json').read_text())
summary=[]
for name,prefix,args in cases:
    for i in range(15):
        for label in (['after','before'] if i%2==0 else ['before','after']):
            r=json.loads(subprocess.check_output([prefix+label,*args],text=True));runs.append(dict(name=name,args=args,iteration=i,variant=label,result=r));(out/'followup_runs.json').write_text(json.dumps(runs,indent=2)+'\n')
            print(name,i,label,r['duration_us'],flush=True)
    original=[dict(name=name,variant=r['variant'],result=r['result']) for r in (initial_main if name=='almost-full-tiny' else initial_reg) if (r['case']==25 if name=='almost-full-tiny' else r['kind']=='ordinary' and r['args']==args)]
    combined=original+[r for r in runs if r['name']==name]
    keys=['hashes','reads','read_bytes','callback_trace_sha256'] if name=='almost-full-tiny' else ['logical_sha256','image_sha256']
    for key in keys:assert len({json.dumps(r['result'][key]) for r in combined})==1,(name,key)
    row={'name':name,'samples_per_variant':20}
    for label in ['before','after']:
        times=[r['result']['duration_us']/1000 for r in combined if r['variant']==label]
        assert len(times)==20
        row[label]={'median_ms':statistics.median(times),'min_ms':min(times),'max_ms':max(times)}
    row['after_over_before']=row['after']['median_ms']/row['before']['median_ms'];summary.append(row)
    (out/'followup_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
