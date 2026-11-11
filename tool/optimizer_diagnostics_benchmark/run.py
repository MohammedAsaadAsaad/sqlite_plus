"""Sequential fresh-process OFF/ON cost matrix; run only after tests/compilers."""
import json
import subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics');runs=[]
cases=[
    (1000,0,'point',500,64,'reader'),
    (1000,0,'scan',20,64,'reader'),
    (1000,0,'early',50,64,'reader'),
    (10000,0,'sort',3,64,'reader'),
    (100000,0,'sort',1,64,'reader'),
    (1000,32,'index',30,64,'reader'),
    (1000,32,'index',30,0,'reader'),
    (1000,0,'point',30,64,'mutable'),
    (1000,0,'scan',10,64,'mutable'),
    (1000,0,'point',100,64,'inspected'),
    (1000,32,'index',20,64,'inspected'),
]
variants=[('baseline-off','before','off'),('linked-off','after','off'),('diagnostic-on','after','on')]
for case,(rows,indexes,mode,repeats,capacity,adapter) in enumerate(cases):
    args=[f'/tmp/diagnostic-{rows}-{indexes}.db',mode,'off',str(repeats),str(capacity),str(rows),adapter]
    for iteration in range(5):
        order=variants[iteration%3:]+variants[:iteration%3]
        for label,binary,enabled in order:
            actual=args.copy();actual[2]=enabled
            result=json.loads(subprocess.check_output(['/tmp/diagnostic-'+binary,*actual],text=True))
            runs.append(dict(case=case,iteration=iteration,variant=label,args=actual,result=result))
            (out/'runs.json').write_text(json.dumps(runs,indent=2)+'\n')
            print(case,iteration,label,result['duration_us'],flush=True)
