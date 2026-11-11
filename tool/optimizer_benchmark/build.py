"""Build current/baseline AOT drivers from the reversible library fixture."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
root=Path.cwd()
baseline=Path(tempfile.mkdtemp(prefix='optimizer-reconstructed-'))
for name in ['sqlite_plus','sqlite_plus_orm']:
    dst=baseline/'packages'/name
    dst.mkdir(parents=True)
    shutil.copytree(root/'packages'/name/'lib',dst/'lib')
subprocess.run(['patch','--batch','-R','-p1','-d',str(baseline),'-i',str(root/'benchmark_results/optimizer/baseline.patch')],check=True)
config=json.loads((root/'.dart_tool/package_config.json').read_text())
for p in config['packages']:
    if not p['rootUri'].startswith('file:'):
        p['rootUri']=(root/'.dart_tool'/p['rootUri']).resolve().as_uri()
    if p['name'] in ['sqlite_plus','sqlite_plus_orm']:
        p['rootUri']=(baseline/'packages'/p['name']).as_uri()
config_path=baseline/'package_config.json'
config_path.write_text(json.dumps(config))
for label in ['before','after']:
    cmd=['dart','compile','exe']
    if label=='before':cmd+=['--packages='+str(config_path)]
    subprocess.run([*cmd,'tool/optimizer_benchmark/main.dart','-o','/tmp/optimizer-'+label],check=True)
    for driver,kind in [('ordinary','ordinary'),('orm_ordinary','orm')]:
        subprocess.run([*cmd,'tool/prepared_benchmark/'+driver+'.dart','-o','/tmp/optimizer-'+kind+'-'+label],check=True)
    subprocess.run([*cmd,'tool/optimizer_benchmark/update_probe.dart','-o','/tmp/optimizer-update-probe-'+label],check=True)
for rows,layout in [(33,'random'),(64,'random'),(1000,'random'),(10000,'random'),(100000,'random'),(10000,'ascending'),(10000,'descending'),(10000,'ties')]:
    subprocess.run(['/tmp/optimizer-after','seed',f'/tmp/optimizer-{rows}-{layout}.db',str(rows),layout],check=True)
