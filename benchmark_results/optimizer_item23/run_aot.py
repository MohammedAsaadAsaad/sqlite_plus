"""Run only after tests/compilers stop. Args: baseline-exe current-exe image-dir."""
import hashlib,json,statistics,subprocess,sys
from pathlib import Path
before,after,image_dir=map(Path,sys.argv[1:]);out=Path(__file__).parent
samples=[];summaries={}
for case,image,mode in [('sparse','sparse','index'),('small','small','index'),
                        ('dense_fallback','dense','index'),('scan_control','sparse','scan'),
                        ('empty','sparse','empty'),('callback_control','sparse','callbacks')]:
 group=[]
 for pair in range(5):
  variants=[('before',before),('after',after)]
  if pair%2:variants.reverse()
  for label,exe in variants:
   result=json.loads(subprocess.check_output([str(exe),str(image_dir/('item23-'+image+'.db')),mode],text=True))
   row=dict(case=case,pair=pair,variant=label,result=result);samples.append(row);group.append(row)
 for key in ['hash','rows','columns','callback_count','callback_trace_sha256','image_bytes']:
  assert len({json.dumps(r['result'][key],sort_keys=True) for r in group})==1,(case,key)
 summary={}
 for label in ['before','after']:
  rows=[r['result'] for r in group if r['variant']==label]
  summary[label]={k:statistics.median(r[k] for r in rows)
                  for k in ['duration_us','explain_us','reads','read_bytes','peak_rss']}
  summary[label]['duration_range_us']=[min(r['duration_us'] for r in rows),max(r['duration_us'] for r in rows)]
  summary[label]['plans']=list({tuple(r['plan']) for r in rows})
 summary['ratio_after_before']=summary['after']['duration_us']/summary['before']['duration_us']
 summaries[case]=summary;print(case,summary,flush=True)
report=dict(baseline_commit='322c2b0dd5c867301858e67b42eba726e3dcbe4d',samples=len(samples),
            binary_sha256={k:hashlib.sha256(v.read_bytes()).hexdigest() for k,v in [('before',before),('after',after)]},
            image_sha256={name:hashlib.sha256((image_dir/('item23-'+name+'.db')).read_bytes()).hexdigest() for name in ['sparse','small','dense']},
            summary=summaries,limitations='Linux x64 Dart 3.13.7 AOT, five alternating fresh-process pairs per case, memory-backed image. Query timer includes planning/evaluation; explain_us times the public explain separately and is not isolated internal planning. RSS is whole-process peak. No universal zero-overhead or full-roadmap acceptance claim.')
(out/'aot_report.json').write_text(json.dumps(report,indent=2)+'\n')
(out/'aot_samples.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in samples))
