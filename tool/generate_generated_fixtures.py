"""Pinned development-only SQLite fixtures for generated column storage."""
import hashlib
import json
import sqlite3
import sys
import tempfile
from pathlib import Path
from generate_fixtures import PIN, ROOT


def main():
    manifest_path = ROOT / 'generated_manifest.json'
    if '--verify' in sys.argv:
        for name, digest in json.loads(manifest_path.read_text()).items():
            if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != digest:
                raise RuntimeError('Generated fixture checksum mismatch: ' + name)
        print('Generated fixture checksums verified')
        return
    with sqlite3.connect(':memory:') as c:
        if c.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        options = sorted(r[0] for r in c.execute('pragma compile_options'))
        if options != json.loads((ROOT / 'manifest.json').read_text())['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    manifest = {}
    for encoding in ['UTF-8', 'UTF-16le', 'UTF-16be']:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture.db'
            with sqlite3.connect(path) as c:
                c.execute('pragma page_size=512')
                c.execute("pragma encoding='" + encoding + "'")
                c.execute('create table generated(id integer primary key,a text,b text as(lower(a)) stored,c int as(length(b)),r real as(c),kind text as(typeof(r)))')
                c.execute('create unique index generated_key on generated(b) where c>0')
                c.executemany('insert into generated(a) values(?)', [('λ😀A',), ('X'*3000,), (None,)])
                c.execute('create table generated_wr(k text primary key,a int,b int as(a+1) stored,c text as(b||k)) without rowid')
                c.executemany('insert into generated_wr values(?,?)', [('λ', 1), ('😀', 2)])
                c.commit()
                if c.execute('pragma integrity_check').fetchall() != [('ok',)]:
                    raise RuntimeError('Invalid generated fixture')
            data = path.read_bytes()
        name = 'generated-' + encoding + '.db'
        (ROOT / name).write_bytes(data)
        manifest[name] = hashlib.sha256(data).hexdigest()
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
