"""Fresh-process sequential AOT comparisons. Run after stopping tests/compilers."""
import json
import subprocess
from pathlib import Path

out=Path('benchmark_results/optimizer')
runs=[]
cases=[]
def case(rows, k, offset=0, repeats=3, mode='sort', backend='memory', layout='random'):
    cases.append([f'/tmp/optimizer-{rows}-{layout}.db',str(k),str(offset),str(repeats),mode,backend])
for k in [1,20,31,32,33,100,1000,10010,-1]:
    case(10000,k)
case(1000,32,repeats=10)
case(10000,32,offset=1000)
for k in [32,1000]:
    case(100000,k,repeats=1)
for layout in ['ascending','descending','ties']:
    case(10000,1000,layout=layout)
case(10000,1000,backend='file')
for mode in ['point','unordered','distinct']:
    case(1000 if mode=='distinct' else 10000,100,repeats=1 if mode=='distinct' else 5,mode=mode)
for mode in ['callbacks','count']:
    case(1000,100,repeats=1,mode=mode)
for index,args in enumerate(cases):
    for iteration in range(5):
        labels=['before','after'] if iteration%2==0 else ['after','before']
        for label in labels:
            result=json.loads(subprocess.check_output(['/tmp/optimizer-'+label,*args],text=True))
            runs.append(dict(case=index,iteration=iteration,variant=label,args=args,result=result))
            (out/'runs.json').write_text(json.dumps(runs,indent=2)+'\n')
            print(index,iteration,label,result['duration_us'],flush=True)
