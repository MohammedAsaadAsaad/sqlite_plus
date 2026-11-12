"""From repository root after dart pub get: python3 benchmark_results/optimizer_item23/build.py"""
import hashlib,io,json,platform,subprocess,tarfile,tempfile
from pathlib import Path
root=Path.cwd();baseline='322c2b0dd5c867301858e67b42eba726e3dcbe4d'
work=Path(tempfile.mkdtemp(prefix='sqlite-item23-'));fixture=work/'baseline';fixture.mkdir()
data=subprocess.check_output(['git','archive',baseline,'packages/sqlite_plus/lib','packages/sqlite_plus/pubspec.yaml'])
with tarfile.open(fileobj=io.BytesIO(data)) as archive:archive.extractall(fixture,filter='data')
config=json.loads((root/'.dart_tool/package_config.json').read_text())
for package in config['packages']:
 if not package['rootUri'].startswith('file:'):package['rootUri']=(root/'.dart_tool'/package['rootUri']).resolve().as_uri()
 if package['name']=='sqlite_plus':package['rootUri']=(fixture/'packages/sqlite_plus').as_uri()
config_path=work/'before_packages.json';config_path.write_text(json.dumps(config))
driver='tool/optimizer_benchmark/indexed_join_probe.dart'
for variant in ['before','after']:
 command=['dart','compile','exe']
 if variant=='before':command+=['--packages='+str(config_path)]
 subprocess.run([*command,driver,'-o',str(work/variant)],check=True)
for name,count,layout in [('sparse',10000,'sparse'),('small',64,'sparse'),('dense',3000,'dense')]:
 subprocess.run([str(work/'before'),'seed',str(work/('item23-'+name+'.db')),str(count),layout],check=True)
manifest={'baseline_commit':baseline,'sdk':subprocess.check_output(['dart','--version'],text=True).strip(),
          'platform':platform.platform(),'workdir':str(work),
          'driver_sha256':hashlib.sha256((root/driver).read_bytes()).hexdigest()}
(root/'benchmark_results/optimizer_item23/rebuilt_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Run after other tests/compilers stop:')
print('python3 benchmark_results/optimizer_item23/run_aot.py',work/'before',work/'after',work)
