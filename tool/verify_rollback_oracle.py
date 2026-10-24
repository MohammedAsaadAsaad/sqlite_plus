"""Verify a Dart-produced hot journal using the pinned development SQLite."""
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
from generate_fixtures import PIN, ROOT


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as connection:
        if connection.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(r[0] for r in connection.execute('pragma compile_options')) != manifest['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    with tempfile.TemporaryDirectory() as directory:
        subprocess.run(['dart', '--suppress-analytics', 'run',
                        'tool/export_hot_journal.dart', directory],
                       cwd=ROOT.parents[1], check=True)
        database = Path(directory) / 'snapshot.db'
        # SQLite must perform rollback, rather than merely reading old bytes.
        raw = database.read_bytes()
        if int.from_bytes(raw[60:64], 'big') != 99:
            raise RuntimeError('Export did not contain uncommitted bytes')
        with sqlite3.connect(database) as connection:
            if connection.execute('pragma user_version').fetchone() != (42,):
                raise RuntimeError('SQLite did not recover the old image')
            if connection.execute('pragma integrity_check').fetchone() != ('ok',):
                raise RuntimeError('Recovered image failed integrity_check')
        if database.read_bytes() != (ROOT / 'sqlite-512.db').read_bytes():
            raise RuntimeError('SQLite recovery did not restore exact original image')
        print('Pinned SQLite recovered the Dart hot journal byte-for-byte')


if __name__ == '__main__':
    main()
