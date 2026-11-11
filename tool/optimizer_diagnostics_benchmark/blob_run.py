"""Separate BLOB copy cost probe; run after all compilers/tests stop."""
import json, statistics, subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics')
samples=[]
labels=['baseline-off','linked-off','diagnostic-on']
for adapter in ['reader','mutable']:
    for trial in range(5):
        order=labels[trial%3:]+labels[:trial%3]
        for label in order:
            binary='/tmp/diagnostic-blob-'+('before' if label=='baseline-off' else 'after')
            result=json.loads(subprocess.check_output([binary,adapter,'on' if label=='diagnostic-on' else 'off'],text=True))
            result.update(label=label,trial=trial)
            samples.append(result)
            print(adapter,label,result['duration_us'],flush=True)
summary=[]
for adapter in ['reader','mutable']:
    row={'adapter':adapter,'calls':20,'blob_bytes':1048576}
    for label in labels:
        values=[s['duration_us']/1000 for s in samples if s['adapter']==adapter and s['label']==label]
        row[label]={'samples':len(values),'median_ms':statistics.median(values),'min_ms':min(values),'max_ms':max(values)}
    summary.append(row)
(out/'blob_runs.json').write_text(json.dumps(samples,indent=2)+'\n')
(out/'blob_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
