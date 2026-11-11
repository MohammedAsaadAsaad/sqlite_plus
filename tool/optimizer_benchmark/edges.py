"""Supplementary tiny/almost-full K cases; run after the main/regression suite."""
import json
import subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer')
runs=json.loads((out/'runs.json').read_text())
next_case=max(r['case'] for r in runs)+1
for rows in [33,64]:
    subprocess.run(['/tmp/optimizer-after','seed',f'/tmp/optimizer-{rows}-random.db',str(rows),'random'],check=True)
for case,(rows,k,repeats) in enumerate([(33,32,100),(64,31,50),(64,32,50),(64,63,50),(1000,999,5)],start=next_case):
    args=[f'/tmp/optimizer-{rows}-random.db',str(k),'0',str(repeats),'sort','memory']
    for i in range(5):
        for variant in (['before','after'] if i%2==0 else ['after','before']):
            result=json.loads(subprocess.check_output(['/tmp/optimizer-'+variant,*args],text=True))
            runs.append(dict(case=case,iteration=i,variant=variant,args=args,result=result))
            (out/'runs.json').write_text(json.dumps(runs,indent=2)+'\n')
            print(case,i,variant,result['duration_us'],flush=True)
