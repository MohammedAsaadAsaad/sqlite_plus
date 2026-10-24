"""Development-only oracle. Requires exactly the pinned SQLite build."""
import hashlib
import json
import sys
from pathlib import Path
import sqlite3
import tempfile

ROOT = Path(__file__).resolve().parents[1] / 'packages/sqlite_plus/test/fixtures'
PIN = '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9'


def generate():
    with sqlite3.connect(':memory:') as connection:
        assert connection.execute('select sqlite_source_id()').fetchone()[0] == PIN
        options = sorted(row[0] for row in connection.execute('pragma compile_options'))
    pinned_manifest = ROOT / 'manifest.json'
    if pinned_manifest.exists():
        expected = json.loads(pinned_manifest.read_text())
        if options != expected['compile_options']:
            raise RuntimeError('SQLite compile options differ from pinned oracle')
    manifest = {'sqlite_version': sqlite3.sqlite_version, 'source_id': PIN,
                'compile_options': options, 'fixtures': []}
    ROOT.mkdir(parents=True, exist_ok=True)
    for size, encoding in [(512, 'UTF-8'), (4096, 'UTF-16le'), (65536, 'UTF-16be')]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.db'
            with sqlite3.connect(path) as connection:
                connection.execute(f'pragma page_size={size}')
                connection.execute(f"pragma encoding='{encoding}'")
                connection.execute('pragma journal_mode=delete')
                connection.execute('pragma auto_vacuum=none')
                connection.execute('pragma user_version=42')
                connection.execute('pragma application_id=1397836884')
                connection.execute('create table sample(id integer primary key, value text)')
                connection.execute('create index sample_value on sample(value)')
                connection.executemany('insert into sample(value) values (?)',
                                       [(f'row-{i:04d}-λ',) for i in range(200)])
                connection.commit()
                assert connection.execute('pragma integrity_check').fetchone() == ('ok',)
                pages = [dict(zip(('name', 'pageno', 'pagetype', 'ncell'), row))
                         for row in connection.execute(
                             'select name,pageno,pagetype,ncell from dbstat order by pageno')]
            content = path.read_bytes()
        name = f'sqlite-{size}.db'
        (ROOT / name).write_bytes(content)
        manifest['fixtures'].append({'file': name, 'page_size': size, 'encoding': encoding,
                                    'sha256': hashlib.sha256(content).hexdigest(),
                                    'pages': pages})
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        manifest = json.loads((ROOT / 'manifest.json').read_text())
        for fixture in manifest['fixtures']:
            actual = hashlib.sha256((ROOT / fixture['file']).read_bytes()).hexdigest()
            if actual != fixture['sha256']:
                raise RuntimeError(f"Checksum mismatch: {fixture['file']}")
        print('All fixture checksums verified')
    else:
        generate()
