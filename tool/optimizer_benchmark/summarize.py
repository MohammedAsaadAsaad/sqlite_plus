"""Check equivalent results/IO/callbacks and summarize before/after samples."""
import collections
import json
import statistics
from pathlib import Path
out=Path('benchmark_results/optimizer')
runs=json.loads((out/'runs.json').read_text())
groups=collections.defaultdict(list)
for row in runs:
    groups[row['case']].append(row)
summary=[]
for case,rows in sorted(groups.items()):
    assert {r['variant'] for r in rows}=={'before','after'}
    for key in ['hashes','result_rows','image_bytes','reads','read_bytes','callback_trace_sha256','callback_count','visits','access']:
        assert len({json.dumps(r['result'][key]) for r in rows})==1,(case,key)
    stats={}
    for variant in ['before','after']:
        results=[r['result'] for r in rows if r['variant']==variant]
        assert len(results)==5,(case,variant,len(results))
        times=[r['duration_us']/1000 for r in results]
        stats[variant]={'median_ms':statistics.median(times),'min_ms':min(times),'max_ms':max(times),'median_rss':statistics.median(r['rss'] for r in results),'median_peak_rss':statistics.median(r['peak_rss'] for r in results),'median_explain_us':statistics.median(r['explain_us'] for r in results),'comparisons':sorted({r['comparisons'] for r in results})}
    ratio=stats['after']['median_ms']/stats['before']['median_ms']
    summary.append(dict(case=case,args=rows[0]['args'],before=stats['before'],after=stats['after'],after_over_before=ratio,reads=rows[0]['result']['reads'],result_rows=rows[0]['result']['result_rows']))
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for row in summary:
    print(row['case'],row['args'][1:],round(row['before']['median_ms'],3),round(row['after']['median_ms'],3),'ratio',round(row['after_over_before'],3),flush=True)
