"""Build AOT drivers and reconstruct the pre-feature libraries in /tmp.
Run from the workspace root with Dart 3.13.7 on PATH. Never changes working libs.
"""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path.cwd()
baseline = Path(tempfile.mkdtemp(prefix='prepared-reconstructed-'))
for name in ['sqlite_plus', 'sqlite_plus_orm']:
    target = baseline/'packages'/name
    target.mkdir(parents=True)
    shutil.copytree(root/'packages'/name/'lib', target/'lib')
subprocess.run(['patch', '--batch', '-R', '-p1', '-d', str(baseline), '-i',
                str(root/'benchmark_results/prepared/baseline.patch')], check=True)
config = json.loads((root/'.dart_tool/package_config.json').read_text())
for package in config['packages']:
    uri = package['rootUri']
    if not uri.startswith('file:'):
        package['rootUri'] = (root/'.dart_tool'/uri).resolve().as_uri()
    if package['name'] in ['sqlite_plus', 'sqlite_plus_orm']:
        package['rootUri'] = (baseline/'packages'/package['name']).as_uri()
config_path = baseline/'package_config.json'
config_path.write_text(json.dumps(config))
for driver, output, before in [
    ('main', 'benchmark', False), ('syntax', 'syntax', False),
    ('ordinary', 'ordinary-after', False), ('ordinary', 'ordinary-before', True),
    ('orm_ordinary', 'orm-ordinary-after', False), ('orm_ordinary', 'orm-ordinary-before', True),
]:
    cmd = ['dart', 'compile', 'exe']
    if before:
        cmd.append('--packages='+str(config_path))
    cmd += ['tool/prepared_benchmark/'+driver+'.dart', '-o', '/tmp/prepared-'+output]
    subprocess.run(cmd, check=True)
