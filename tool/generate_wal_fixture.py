"""Capture real SQLite WAL transactions while the pinned writer stays open."""
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
from generate_fixtures import PIN, ROOT


def main():
    with sqlite3.connect(':memory:') as c:
        if c.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(r[0] for r in c.execute('pragma compile_options')) != json.loads((ROOT/'manifest.json').read_text())['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory)/'wal.db'
        shutil.copyfile(ROOT/'write.db', path)
        with sqlite3.connect(path) as c:
            c.execute('pragma journal_mode=wal')
            c.execute('pragma wal_autocheckpoint=0')
            c.execute("update notes set value='wal-one' where id=1")
            c.commit()
            first = Path(str(path)+'-wal').read_bytes()
            c.execute("update notes set value='wal-two' where id=2")
            c.commit()
            base = path.read_bytes()
            wal = Path(str(path)+'-wal').read_bytes()
            expected = c.execute('select id,value from notes where id<=2 order by id').fetchall()
    (ROOT/'wal-base.db').write_bytes(base)
    (ROOT/'wal-first.log').write_bytes(first)
    (ROOT/'wal-final.log').write_bytes(wal)
    metadata = {'source_id': PIN, 'expected': expected, 'hashes': {}}
    for name in ['wal-base.db', 'wal-first.log', 'wal-final.log']:
        metadata['hashes'][name] = hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
    (ROOT/'wal.json').write_text(json.dumps(metadata, indent=2)+'\n')


if __name__ == '__main__':
    import sys
    if '--verify' in sys.argv:
        for name, expected in json.loads((ROOT/'wal.json').read_text())['hashes'].items():
            if hashlib.sha256((ROOT/name).read_bytes()).hexdigest() != expected:
                raise RuntimeError(f'WAL fixture checksum mismatch: {name}')
        print('WAL fixture checksums verified')
    else:
        main()
