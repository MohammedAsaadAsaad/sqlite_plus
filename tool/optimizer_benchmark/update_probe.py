"""Twenty paired processes, 100k ordinary updates each; no concurrent jobs."""
import json
import statistics
import subprocess
from pathlib import Path
out=Path('benchmark_results/optimizer')
runs=[]
for i in range(20):
    for label in (['before','after'] if i%2==0 else ['after','before']):
        result=json.loads(subprocess.check_output(['/tmp/optimizer-update-probe-'+label],text=True))
        assert result['checksum']=='600500'
        runs.append(dict(iteration=i,variant=label,result=result))
        (out/'update_probe_runs.json').write_text(json.dumps(runs,indent=2)+'\n')
summary={}
for label in ['before','after']:
    values=[r['result']['duration_us']/1000 for r in runs if r['variant']==label]
    summary[label]={'samples':len(values),'median_ms':statistics.median(values),'min_ms':min(values),'max_ms':max(values)}
summary['after_over_before']=summary['after']['median_ms']/summary['before']['median_ms']
(out/'update_probe_combined_summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
