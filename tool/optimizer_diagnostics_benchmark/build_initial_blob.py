"""Reconstruct initial candidate to compare snapshot counts without time drift."""
import hashlib, json, shutil, subprocess, tempfile
from pathlib import Path
root=Path.cwd();base=root/'benchmark_results/optimizer_diagnostics'
stage=Path(tempfile.mkdtemp(prefix='diagnostics-initial-blob-'))
# Reconstruct main, then apply the archived initial candidate's exact patch.
for name in ['sqlite_plus','sqlite_plus_inspector','sqlite_plus_orm']:
    target=stage/'packages'/name;target.mkdir(parents=True)
    shutil.copytree(root/'packages'/name/'lib',target/'lib')
subprocess.run(['patch','--batch','-R','-p1','-d',str(stage),'-i',str(base/'baseline.patch')],check=True)
subprocess.run(['patch','--batch','-p1','-d',str(stage),'-i',str(base/'initial_candidate/baseline.patch')],check=True)
manifest=json.loads((base/'initial_candidate/after_manifest.json').read_text())
for key,h in manifest['source_sha256'].items():assert hashlib.sha256((stage/key).read_bytes()).hexdigest()==h,key
config=json.loads((root/'.dart_tool/package_config.json').read_text())
for package in config['packages']:
    if not package['rootUri'].startswith('file:'):package['rootUri']=(root/'.dart_tool'/package['rootUri']).resolve().as_uri()
    if package['name'] in ['sqlite_plus','sqlite_plus_inspector','sqlite_plus_orm']:package['rootUri']=(stage/'packages'/package['name']).as_uri()
p=stage/'package_config.json';p.write_text(json.dumps(config))
subprocess.run(['dart','compile','exe','--packages='+str(p),'tool/optimizer_diagnostics_benchmark/blob_after.dart','-o','/tmp/diagnostic-blob-initial'],check=True)
