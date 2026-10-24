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
        if connection.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('SQLite source ID differs from pinned oracle')
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
                connection.execute('create table types(i, r, t, b, n)')
                connection.executemany('insert into types(rowid,i,r,t,b,n) values (?,?,?,?,?,?)', [
                    (-9223372036854775808, -9223372036854775808, -1.25, '', b'', None),
                    (-1, -8388609, 3.5, 'λ😀', bytes(range(256)) * 24, None),
                    (0, 0, 0.0, 'a' * 5000 + '😀', b'\x00\xff', None),
                    (1, 1, 1.0, 'x', b'abc', None),
                    (127, 127, 1e100, 'y', b'z' * 12000, None),
                    (128, 128, -1e-100, 'z', b'k' * 477, None),
                    (9223372036854775807, 9223372036854775807, 42.25, 'end', b'last', None),
                ])
                connection.execute('create index types_blob on types(b)')
                connection.execute('create table boundary(v blob)')
                min_local = ((size - 12) * 32 // 255) - 23
                index_max = ((size - 12) * 64 // 255) - 23
                table_max = size - 35
                targets = {2}
                for threshold in [min_local, index_max, table_max,
                                  min_local + size - 4]:
                    targets.update([threshold - 1, threshold, threshold + 1])

                def varint_length(value):
                    length = 1
                    while value >= 128:
                        length += 1
                        value >>= 7
                    return length

                for target in sorted(targets):
                    length = next(n for n in range(max(0, target - 12), target)
                                  if n + 1 + varint_length(12 + 2 * n) == target)
                    connection.execute('insert into boundary values (?)',
                                       (bytes((i % 251 for i in range(length))),))
                connection.execute('create index boundary_blob on boundary(v)')
                connection.execute('create table empty(value)')
                connection.execute('create table keyed(k text primary key, v integer) without rowid')
                connection.executemany('insert into keyed values (?,?)',
                                       [(f"key-{i:04d}", i - 150) for i in range(300)])
                connection.commit()
                if connection.execute('pragma integrity_check').fetchone() != ('ok',):
                    raise RuntimeError('SQLite fixture integrity check failed')
                def value(v):
                    if isinstance(v, bytes):
                        return {'blob': v.hex()}
                    if isinstance(v, int):
                        return {'integer': str(v)}
                    return v

                trees = []
                for table in ['sample', 'types', 'empty', 'boundary']:
                    root = connection.execute(
                        'select rootpage from sqlite_schema where name=?', (table,)).fetchone()[0]
                    rows = connection.execute(f'select rowid,* from {table} order by rowid').fetchall()
                    trees.append({'name': table, 'root': root, 'kind': 'table',
                                  'records': [{'rowid': str(row[0]),
                                               'values': [value(v) for v in ((None,) + row[2:] if table == 'sample' else row[1:])]}
                                              for row in rows]})
                for name, query in [
                    ('sample_value', 'select value,rowid from sample order by value,rowid'),
                    ('types_blob', 'select b,rowid from types order by b,rowid'),
                    ('boundary_blob', 'select v,rowid from boundary order by v,rowid'),
                    ('keyed', 'select k,v from keyed order by k')]:
                    root = connection.execute(
                        'select rootpage from sqlite_schema where name=?', (name,)).fetchone()[0]
                    trees.append({'name': name, 'root': root, 'kind': 'index',
                                  'records': [{'rowid': None, 'values': [value(v) for v in row]}
                                              for row in connection.execute(query)]})
                schema_rows = connection.execute(
                    'select rowid,* from sqlite_schema order by rowid').fetchall()
                trees.append({'name': 'sqlite_schema', 'root': 1, 'kind': 'table',
                              'records': [{'rowid': str(row[0]), 'values': [value(v) for v in row[1:]]}
                                          for row in schema_rows]})
                pages = [dict(zip(('name', 'pageno', 'pagetype', 'ncell'), row))
                         for row in connection.execute(
                             'select name,pageno,pagetype,ncell from dbstat order by pageno')]
            content = path.read_bytes()
        name = f'sqlite-{size}.db'
        (ROOT / name).write_bytes(content)
        manifest['fixtures'].append({'file': name, 'page_size': size, 'encoding': encoding,
                                    'sha256': hashlib.sha256(content).hexdigest(),
                                    'pages': pages, 'trees': trees})
    records = [{'file': f['file'], 'trees': f.pop('trees')} for f in manifest['fixtures']]
    (ROOT / 'records.json').write_text(json.dumps(records, indent=2, ensure_ascii=False) + '\n')
    manifest['records_sha256'] = hashlib.sha256((ROOT / 'records.json').read_bytes()).hexdigest()
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        manifest = json.loads((ROOT / 'manifest.json').read_text())
        for fixture in manifest['fixtures']:
            actual = hashlib.sha256((ROOT / fixture['file']).read_bytes()).hexdigest()
            if actual != fixture['sha256']:
                raise RuntimeError(f"Checksum mismatch: {fixture['file']}")
        actual = hashlib.sha256((ROOT / 'records.json').read_bytes()).hexdigest()
        if actual != manifest['records_sha256']:
            raise RuntimeError('Record oracle checksum mismatch')
        print('All fixture and record oracle checksums verified')
    else:
        generate()
