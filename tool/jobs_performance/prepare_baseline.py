"""Copy packages to /tmp and reverse only this milestone's production patches."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urljoin

root = Path.cwd()
stage = Path(tempfile.mkdtemp(prefix='jobs-performance-before-'))
for name in ['sqlite_plus', 'sqlite_plus_jobs']:
    shutil.copytree(root / 'packages' / name, stage / 'packages' / name)
for patch in ['core.patch', 'queue.patch']:
    subprocess.run(['patch', '--batch', '-R', '-p1', '-i',
                    str(root / 'benchmark_results/jobs_performance' / patch)],
                   cwd=stage, check=True, capture_output=True)
config_path = root / '.dart_tool/package_config.json'
config = json.loads(config_path.read_text())
for package in config['packages']:
    package['rootUri'] = urljoin(config_path.as_uri(), package['rootUri'])
    if package['name'] in ['sqlite_plus', 'sqlite_plus_jobs']:
        package['rootUri'] = (stage / 'packages' / package['name']).as_uri() + '/'
output = stage / 'package_config.json'
output.write_text(json.dumps(config, indent=2) + '\n')
print(output)
