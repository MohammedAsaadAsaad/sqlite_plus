"""A small unindexed database for M4 mutation tests; pinned native dev oracle."""
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile
from generate_fixtures import PIN, ROOT


def main():
    with sqlite3.connect(':memory:') as c:
        if c.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        options = sorted(r[0] for r in c.execute('pragma compile_options'))
        if options != json.loads((ROOT / 'manifest.json').read_text())['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'write.db'
        with sqlite3.connect(path) as c:
            c.execute('pragma page_size=512')
            c.execute('create table notes(id integer primary key, value text, n integer)')
            c.execute('create table guarded(x text not null)')
            c.executemany('insert into notes values (?,?,?)',
                          [(i, f'value-{i}', i - 1000) for i in range(1, 2001)])
            c.commit()
            if c.execute('pragma integrity_check').fetchone() != ('ok',):
                raise RuntimeError('Invalid write fixture')
        data = path.read_bytes()
    (ROOT / 'write.db').write_bytes(data)
    (ROOT / 'write.sha256').write_text(hashlib.sha256(data).hexdigest() + '\n')


if __name__ == '__main__':
    import sys
    if '--verify' in sys.argv:
        if hashlib.sha256((ROOT / 'write.db').read_bytes()).hexdigest() != (ROOT / 'write.sha256').read_text().strip():
            raise RuntimeError('Write fixture checksum mismatch')
        print('Write fixture checksum verified')
    else:
        main()
