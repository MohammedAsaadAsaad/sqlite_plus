"""Build final-source/baseline diagnostic AOT drivers; no original /tmp needed."""
import hashlib
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
root=Path.cwd();evidence=root/'benchmark_results/optimizer_diagnostics'
stage=Path(tempfile.mkdtemp(prefix='diagnostics-before-'))
for name in ['sqlite_plus','sqlite_plus_inspector','sqlite_plus_orm']:
    target=stage/'packages'/name;target.mkdir(parents=True)
    shutil.copytree(root/'packages'/name/'lib',target/'lib')
subprocess.run(['patch','--batch','-R','-p1','-d',str(stage),'-i',str(evidence/'baseline.patch')],check=True)
manifest=json.loads((evidence/'before_manifest.json').read_text())
for name,expected in manifest['source_sha256'].items():
    assert hashlib.sha256((stage/name).read_bytes()).hexdigest()==expected,name
config=json.loads((root/'.dart_tool/package_config.json').read_text())
for package in config['packages']:
    if not package['rootUri'].startswith('file:'):
        package['rootUri']=(root/'.dart_tool'/package['rootUri']).resolve().as_uri()
    if package['name'] in ['sqlite_plus','sqlite_plus_inspector','sqlite_plus_orm']:
        package['rootUri']=(stage/'packages'/package['name']).as_uri()
config_path=stage/'package_config.json';config_path.write_text(json.dumps(config))
for label in ['before','after']:
    command=['dart','compile','exe']
    if label=='before':command+=['--packages='+str(config_path)]
    subprocess.run([*command,'tool/optimizer_diagnostics_benchmark/'+label+'.dart','-o','/tmp/diagnostic-'+label],check=True)
    for source,suffix in [('tool/prepared_benchmark/ordinary.dart','ordinary'),('tool/prepared_benchmark/orm_ordinary.dart','orm'),('tool/optimizer_benchmark/update_probe.dart','update')]:
        subprocess.run([*command,source,'-o','/tmp/diagnostic-'+suffix+'-'+label],check=True)
images=[]
for rows,indexes in [(1000,0),(10000,0),(100000,0),(1000,32)]:
    path=f'/tmp/diagnostic-{rows}-{indexes}.db'
    result=json.loads(subprocess.check_output(['/tmp/diagnostic-after','seed',path,str(rows),str(indexes)],text=True));images.append(result)
(evidence/'seed_images.json').write_text(json.dumps(images,indent=2)+'\n')
print('Build/seed completed; stop all tests/compilers before run.py.')
