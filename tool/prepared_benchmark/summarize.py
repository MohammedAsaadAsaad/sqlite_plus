"""Validate sample equivalence and produce median/range summaries."""
import collections
import json
import statistics
from pathlib import Path

runs=json.loads(Path('benchmark_results/prepared/runs.json').read_text())
groups=collections.defaultdict(list)
for run in runs:
    groups[(run['binary'],tuple(run['args']))].append(run['result'])
summary=[]
for (binary,args),results in groups.items():
    times=[r['duration_us']/1000 for r in results]
    summary.append(dict(binary=binary,args=args,samples=len(times),median_ms=statistics.median(times),min_ms=min(times),max_ms=max(times)))
for mode in ['read','update','orm']:
    records=[r['result'] for r in runs if r['binary']=='/tmp/prepared-benchmark' and r['args'][0]==mode]
    for key in ['checksum','logical_sha256','image_bytes']:
        assert len({r[key] for r in records})==1,(mode,key)
for mode in ['read','insert','update','guarded']:
    records=[r['result'] for r in runs if r['binary'].startswith('/tmp/prepared-ordinary-') and r['args'][0]==mode]
    for key in ['logical_sha256','image_sha256','image_bytes']:
        assert len({r[key] for r in records})==1,(mode,key)
for prefix in ['/tmp/prepared-orm-ordinary-','/tmp/prepared-syntax']:
    records=[r['result'] for r in runs if r['binary'].startswith(prefix)]
    assert len({str(r['checksum']) for r in records})==1,prefix
Path('benchmark_results/prepared/summary.json').write_text(json.dumps(summary,indent=2)+'\n')
for r in summary:
    print(r)
