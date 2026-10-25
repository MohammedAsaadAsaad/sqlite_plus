"""Pinned, callback-free view metadata for parenthesized joined sources."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def statements():
    for join in ['JOIN gb USING(x)', 'LEFT JOIN gb USING(x)',
                 'RIGHT JOIN gb USING(x)', 'FULL JOIN gb USING(x)',
                 'NATURAL JOIN gb', 'NATURAL LEFT JOIN gb',
                 'CROSS JOIN gb', 'JOIN gb ON ga.x=gb.x']:
        for shape in [f'(ga {join})', f'(ga {join}) AS q',
                      f'((ga {join})) AS q']:
            for projection in ['*', 'ga.x,gb.x', 'ga.y,gb.y',
                               'q.x,q."x:1"', 'q.y,q."y:1"']:
                yield f'SELECT {projection} FROM {shape}'
    for outer in ['JOIN', 'LEFT JOIN', 'RIGHT JOIN', 'FULL JOIN', 'CROSS JOIN']:
        for inner in ['JOIN', 'LEFT JOIN', 'RIGHT JOIN', 'FULL JOIN']:
            for alias in ['', ' AS q']:
                tail = '' if outer == 'CROSS JOIN' else ' USING(x)'
                yield (f'SELECT * FROM ga {outer} '
                       f'(gb {inner} gc USING(x)){alias}{tail}')
                yield (f'SELECT ga.x,gb.x,gc.x,gb.y,gc.w FROM ga {outer} '
                       f'(gb {inner} gc USING(x)){alias}{tail}')
    yield ('WITH c(x,y) AS (SELECT x,y FROM ga) '
           'SELECT * FROM ga LEFT JOIN (c JOIN gc USING(x)) USING(x)')
    yield ('SELECT q.x,q.label FROM ga LEFT JOIN '
           '((SELECT x,CAST(y AS TEXT) AS label FROM gb) AS d '
           'JOIN gc USING(x)) AS q USING(x)')
    yield ('SELECT (SELECT q.y) AS field FROM '
           '(ga JOIN gb USING(x)) AS q WHERE metadata_probe() '
           'LIMIT metadata_probe()')
    yield ('SELECT * FROM ga LEFT JOIN '
           '(gb JOIN gc ON metadata_probe()) AS q ON metadata_probe() '
           'WHERE metadata_probe() LIMIT metadata_probe()')


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    total = 0
    errors = 0
    for encoding in ['UTF-8', 'UTF-16le', 'UTF-16be']:
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            image = temporary / 'reference.db'
            with sqlite3.connect(':memory:') as native:
                if native.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
                    raise RuntimeError('Wrong SQLite source ID')
                if sorted(r[0] for r in native.execute('PRAGMA compile_options')) != manifest['compile_options']:
                    raise RuntimeError('Wrong SQLite compile options')
                calls = []

                def probe():
                    calls.append(True)
                    raise RuntimeError('Metadata evaluated a callback')

                native.create_function('metadata_probe', 0, probe)
                native.execute(f"PRAGMA encoding='{encoding}'")
                native.executescript('''
                    CREATE TABLE ga(x INT,y TEXT COLLATE NOCASE);
                    CREATE TABLE gb(x TEXT,y REAL,z BLOB);
                    CREATE TABLE gc(x INT,w TEXT);
                ''')
                queries = []
                labels = {}
                for i, sql in enumerate(statements()):
                    name = f'joined_{i}'
                    native.execute(f'CREATE VIEW {name} AS {sql}')
                    for pragma in ['table_info', 'table_xinfo']:
                        query = f'PRAGMA {pragma}({name})'
                        queries.append(query)
                        labels[query] = sql
                with sqlite3.connect(image) as target:
                    native.backup(target)
                input_path = temporary / 'input.json'
                input_path.write_text(json.dumps({'image': str(image), 'queries': queries}))
                result = subprocess.run(
                    ['dart', '--suppress-analytics', 'run',
                     'tool/metadata_pragma_differential.dart', str(input_path)],
                    cwd=ROOT.parents[1], capture_output=True, text=True)
                if result.returncode:
                    raise RuntimeError(result.stderr)
                for sql, actual in zip(queries, json.loads(result.stdout), strict=True):
                    try:
                        cursor = native.execute(sql)
                        expected = {'columns': [c[0] for c in cursor.description],
                                    'rows': [[encode(v) for v in row] for row in cursor]}
                    except sqlite3.Error:
                        expected = {'error': True}
                        errors += 1
                    if actual != expected:
                        raise RuntimeError(f'{encoding}: {sql}: {labels[sql]}\n'
                                           f'Dart: {actual}\nSQLite: {expected}')
                    total += 1
                if calls:
                    raise RuntimeError('Native metadata evaluated callbacks')
    print(f'Pinned joined-source metadata agrees: {total} comparisons, '
          f'including {errors} preparation errors, across three encodings')


if __name__ == '__main__':
    main()
