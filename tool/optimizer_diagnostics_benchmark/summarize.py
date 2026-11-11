"""Check all OFF/ON result/IO/counter gates; summarize timing and metadata cost."""
import collections
import json
import statistics
from pathlib import Path
out=Path('benchmark_results/optimizer_diagnostics')
runs=json.loads((out/'runs.json').read_text());groups=collections.defaultdict(list)
for r in runs:groups[r['case']].append(r)
assert set(groups)==set(range(11)),sorted(groups)
summary=[]
labels=['baseline-off','linked-off','diagnostic-on']
for case,rows in sorted(groups.items()):
    for key in ['hash','result_rows','page_reads','image_bytes']:
        assert len({json.dumps(r['result'][key]) for r in rows})==1,(case,key)
    entry={'case':case,'args':rows[0]['args'],'variants':{}}
    for label in labels:
        values=[r['result'] for r in rows if r['variant']==label]
        assert len(values)==5,(case,label,len(values))
        times=[r['duration_us']/1000 for r in values]
        entry['variants'][label]={'samples':len(times),'median_ms':statistics.median(times),'min_ms':min(times),'max_ms':max(times),'median_rss':statistics.median(r['rss'] for r in values),'median_peak_rss':statistics.median(r['peak_rss'] for r in values)}
        if label=='diagnostic-on':
            for r in values:
                m=r['last_report'];assert m is not None
                assert len(m['decisions'])<=r['max_candidates']
                assert m['enumeratedCandidates']>=len(m['decisions'])
                assert m['decisionsTruncated']==(m['enumeratedCandidates']>len(m['decisions']))
                assert m['rowsVisited']>=m['rowsMatched']>=m['rowsReturned']
                assert m['sortComparisons'] is None and m['allocatedBytes'] is None
                assert 'sql' not in m and 'parameters' not in m
            entry['last_report']=values[-1]['last_report']
            entry['metadata_json_bytes']=statistics.median(len(json.dumps(r['last_report']).encode()) for r in values)
    entry['linked_off_over_before']=entry['variants']['linked-off']['median_ms']/entry['variants']['baseline-off']['median_ms']
    entry['on_over_linked_off']=entry['variants']['diagnostic-on']['median_ms']/entry['variants']['linked-off']['median_ms']
    summary.append(entry)
(out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for r in summary:
    print(r['case'],r['args'][1:],*[round(r['variants'][v]['median_ms'],3) for v in labels], 'off_ratio',round(r['linked_off_over_before'],3),'on/off',round(r['on_over_linked_off'],3))
