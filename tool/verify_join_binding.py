"""Pinned SQLite comparison for JOIN ON aliases and forward source bindings."""
import itertools
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    queries = []
    directions = ['JOIN', 'CROSS JOIN', 'LEFT JOIN', 'RIGHT JOIN', 'FULL JOIN']
    for direction, projection, predicate in itertools.product(
            directions,
            ['a.x+1 AS q', 'a.x AS q', 'a.y AS q',
             'a.y COLLATE BINARY AS q', 'a.y COLLATE NOCASE AS q',
             'CAST(a.x AS TEXT) AS q', 'a.x+100 AS x',
             'a.x+100 AS y', 'sum(a.x) AS q',
             'row_number() OVER() AS q', 'a.x+1 AS q,q+1 AS r'],
            ['q=b.x', 'q=b.y', 'q IS NULL', 'q=b.x OR b.x IS NULL',
             '0 AND q=b.x', 'x=b.x', 'y=b.y', 'r=b.x']):
        width = 2 if ',q+1' in projection else 1
        queries.append(f'SELECT {projection} FROM a {direction} b ON {predicate} '
                       f'ORDER BY {",".join(str(i+1) for i in range(width))}')
    for first, second, predicate, second_on in itertools.product(
            directions, directions,
            ['c.x=a.x', 'c.x=b.x', 'c.x IS NULL',
             'c.y=a.y', 'q=c.x', 'EXISTS(SELECT 1 WHERE c.x=a.x)',
             'EXISTS(SELECT 1 FROM d WHERE d.x=c.x AND a.x=d.x)',
             'EXISTS(SELECT 1 FROM c WHERE c.x=a.x)',
             'EXISTS(SELECT a.x)', 'a.x=b.x', 'x=1'],
            ['', ' ON c.x=1', ' ON c.x=999', ' ON c.x=b.x']):
        queries.append(f'SELECT a.x+1 AS q,a.x,b.x,c.x FROM a {first} b '
                       f'ON {predicate} {second} c{second_on} ORDER BY 1,2,3,4')
    for source in ['a JOIN b USING(x)', 'a LEFT JOIN b USING(x)',
                   'a RIGHT JOIN b USING(x)', 'a FULL JOIN b USING(x)',
                   'a,b JOIN c USING(x)', 'a JOIN b USING(x),c']:
        for predicate in ['x=1', 'q=1', 'a.x=1', 'c.x=a.x']:
            queries.append(f'SELECT a.x AS q FROM {source} '
                           f'JOIN d ON {predicate} ORDER BY 1')
    total = 0
    for encoding in ['UTF-8', 'UTF-16le', 'UTF-16be']:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = root / 'reference.db'
            with sqlite3.connect(':memory:') as native:
                if native.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
                    raise RuntimeError('Wrong SQLite source ID')
                if sorted(r[0] for r in native.execute('PRAGMA compile_options')) != manifest['compile_options']:
                    raise RuntimeError('Wrong SQLite compile options')
                native.execute(f"PRAGMA encoding='{encoding}'")
                native.executescript("""
                    CREATE TABLE a(x INT,y TEXT COLLATE NOCASE);
                    CREATE TABLE b(x INT,y TEXT);
                    CREATE TABLE c(x INT,y TEXT);
                    CREATE TABLE d(x INT);
                    INSERT INTO a VALUES(1,'a'),(2,'b'),(NULL,NULL);
                    INSERT INTO b VALUES(2,'A'),(3,'B'),(NULL,NULL);
                    INSERT INTO c VALUES(1,'a'),(2,'b'),(NULL,NULL);
                    INSERT INTO d VALUES(1),(2),(NULL);
                """)
                image.write_bytes(native.serialize())
                expected = []
                for sql in queries:
                    try:
                        cursor = native.execute(sql)
                        expected.append({'columns': [d[0] for d in cursor.description],
                                         'rows': [[encode(v) for v in row] for row in cursor]})
                    except sqlite3.Error:
                        expected.append({'error': True})
            request = root / 'request.json'
            request.write_text(json.dumps({'image': str(image), 'queries': queries}))
            process = subprocess.run(['dart', '--suppress-analytics', 'run',
                'tool/join_binding_differential.dart', str(request)],
                cwd=Path(__file__).resolve().parents[1] / 'packages/sqlite_plus',
                text=True, capture_output=True, check=True)
            actual = json.loads(process.stdout)
            failures = [(sql, want, got) for sql, want, got in zip(queries, expected, actual)
                        if want != got]
            if failures:
                for sql, want, got in failures[:12]:
                    print(sql, '\n expected:', want, '\n actual:', got)
                raise AssertionError(f'{len(failures)} / {len(queries)} JOIN cases differ for {encoding}')
            total += len(queries)
            print(f'Pinned SQLite JOIN binding comparisons: {len(queries)}; encoding={encoding}')
    print(f'All {total} JOIN binding comparisons passed')


if __name__ == '__main__':
    main()
