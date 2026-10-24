"""Pinned SQLite cross-opens Dart WAL commits and checkpoints, and resumes writing."""
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import struct
from generate_fixtures import PIN, ROOT


def main():
    with sqlite3.connect(':memory:') as c:
        if c.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(r[0] for r in c.execute('pragma compile_options')) != json.loads((ROOT/'manifest.json').read_text())['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(['dart', '--suppress-analytics', 'run', 'tool/export_wal.dart', directory],
                       cwd=ROOT.parents[1], check=True)
        # Independent Python checksum implementation exercises big-endian WAL
        # append, then asks official SQLite to validate the resulting format.
        big = Path(directory)/'big.db'
        big.write_bytes((Path(directory)/'2.db').read_bytes())
        log = bytearray((Path(directory)/'2.db-wal').read_bytes())
        struct.pack_into('>I', log, 0, 0x377f0683)
        def checksum(data, state):
            a, b = state
            words = struct.unpack('>'+'I'*(len(data)//4), data)
            for x, y in zip(words[::2], words[1::2]):
                a = (a+x+b) & 0xffffffff
                b = (b+y+a) & 0xffffffff
            return a,b
        state = checksum(log[:24], (0,0))
        struct.pack_into('>II', log, 24, *state)
        size = struct.unpack_from('>I', log, 8)[0]
        for offset in range(32, len(log), size+24):
            state = checksum(log[offset:offset+8], state)
            state = checksum(log[offset+24:offset+24+size], state)
            struct.pack_into('>II', log, offset+16, *state)
        Path(str(big)+'-wal').write_bytes(log)
        subprocess.run(['dart', '--suppress-analytics', 'run', 'tool/append_wal.dart', str(big)],
                       cwd=ROOT.parents[1], check=True)
        with sqlite3.connect(big) as c:
            if c.execute('select value from notes where id=1').fetchone() != ('big-endian-append',):
                raise RuntimeError('Big-endian WAL append differs')
            if c.execute('pragma integrity_check').fetchone() != ('ok',):
                raise RuntimeError('Big-endian WAL integrity failure')
        for i in range(3):
            path = Path(directory)/f'{i}.db'
            if not Path(str(path)+'-wal').stat().st_size:
                raise RuntimeError('Dart export did not retain WAL')
            with sqlite3.connect(path) as c:
                if c.execute('select value,n from notes where id=1').fetchone() != (f'dart-wal-{i}', -999+i+1):
                    raise RuntimeError(f'WAL commit {i} differs')
                if c.execute('select count(*) from notes').fetchone() != (2001+i,):
                    raise RuntimeError('Inserted rows missing')
                if c.execute('pragma integrity_check').fetchone() != ('ok',):
                    raise RuntimeError('WAL integrity failure')
                c.execute("insert into notes(value,n) values('native-after-dart',99)")
                c.commit()
                if c.execute('pragma integrity_check').fetchone() != ('ok',):
                    raise RuntimeError('SQLite cannot continue writing after Dart')
        with sqlite3.connect(Path(directory)/'checkpoint.db') as c:
            if c.execute('select value,n from notes where id=1').fetchone() != ('dart-wal-2', -996):
                raise RuntimeError('Checkpoint differs')
            if c.execute('pragma integrity_check').fetchone() != ('ok',):
                raise RuntimeError('Checkpoint integrity failure')
        with sqlite3.connect(Path(directory)/'owned.db') as c:
            if c.execute('select value from notes where id=1').fetchone() != ('owned',):
                raise RuntimeError('Owner handoff to SQLite failed')
        print('Pinned SQLite verified 3 Dart WAL commits, both checksum endians, checkpoint, native write continuation, and exclusive owner handoff')


if __name__ == '__main__':
    main()
