"""Paired initial-ON/final-ON BLOB control; run after all compilers stop."""
import hashlib,json,os,statistics,subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics');cpu=min(os.sched_getaffinity(0));runs=[];summary=[]
for adapter in ['reader','mutable']:
    group=[]
    for trial in range(20):
        for label in (['initial','after'] if trial%2==0 else ['after','initial']):
            binary='/tmp/diagnostic-blob-'+label
            result=json.loads(subprocess.check_output(['taskset','-c',str(cpu),binary,adapter,'on'],text=True))
            row=dict(adapter=adapter,cpu=cpu,trial=trial,label=label,result=result);runs.append(row);group.append(row)
    row=dict(adapter=adapter,cpu=cpu,calls=20,blob_bytes=1048576)
    for label in ['initial','after']:
        values=[s['result']['duration_us']/1000 for s in group if s['label']==label]
        row[label]={'samples':20,'median_ms':statistics.median(values),'min_ms':min(values),'max_ms':max(values)}
    ratios=[]
    for trial in range(20):
        pair={s['label']:s['result']['duration_us'] for s in group if s['trial']==trial};ratios.append(pair['after']/pair['initial'])
    row['median_paired_ratio']=statistics.median(ratios);summary.append(row)
    print(json.dumps(row),flush=True)
    (out/'copy_runs.json').write_text(json.dumps(runs,indent=2)+'\n')
    (out/'copy_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
(out/'copy_binary_sha256.json').write_text(json.dumps({label:hashlib.sha256(Path('/tmp/diagnostic-blob-'+label).read_bytes()).hexdigest() for label in ['initial','after']},indent=2)+'\n')
