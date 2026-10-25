"""Pinned native comparison for the supported metadata-PRAGMA subset.

The engine has one unnamed main image, no ATTACH/TEMP schema, and advertises
only its implemented function/PRAGMA signatures. Native's additional functions,
PRAGMAs, empty temp-schema placeholder and file path are not engine claims.
"""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


class Aggregate:
    def step(self, *args):
        pass

    def finalize(self):
        return 0


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    queries = [
        'PRAGMA table_list', 'PRAGMA main.table_list',
        "PRAGMA table_list='SaMpLe'", 'PRAGMA table_list(missing)',
        'PRAGMA table_list(sqlite_master)', 'PRAGMA table_list(sqlite_schema)',
        'PRAGMA table_list(visible)', 'PRAGMA table_list(infinite)',
        'PRAGMA database_list', 'PRAGMA collation_list',
        'PRAGMA main.collation_list(ignored)',
        'PRAGMA function_list', 'PRAGMA pragma_list',
    ]
    for name in ['sample', 'keyed', 'strict_t', 'visible', 'renamed', 'joined',
                 'derived', 'infinite', 'dangerous', 'nested', 'sqlite_schema',
                 'sqlite_master', 'missing', 'scalar_metadata', 'cte_metadata',
                 'derived_metadata', 'rowid_metadata', 'full_metadata',
                 'right_metadata',
                 'nested_scalar', 'compound_scalar', 'main_metadata']:
        for pragma in ['table_info', 'table_xinfo']:
            queries.append(f'PRAGMA {pragma}("{name}")')
    queries += ['PRAGMA main.table_info=sample', 'PRAGMA main.index_list(sample)',
                'PRAGMA main.foreign_key_list(sample)']
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
                calls = []

                def probe():
                    calls.append(True)
                    raise RuntimeError('Metadata invoked a callback')

                native.create_function('metadata_probe', 0, probe)
                native.create_function('custom_scalar', 1, lambda x: 0, deterministic=True)
                native.create_function('custom_scalar', -1, lambda *x: 0)
                native.create_aggregate('custom_aggregate', 2, Aggregate)
                native.execute(f"PRAGMA encoding='{encoding}'")
                native.executescript("""
                    CREATE TABLE sample(id INTEGER PRIMARY KEY,a TEXT NOT NULL DEFAULT 'x',
                      b REAL,c,d INT AS(id+1),e INT AS(id+2) STORED);
                    CREATE TABLE keyed(a TEXT PRIMARY KEY,b INT) WITHOUT ROWID;
                    CREATE TABLE strict_t(a INT PRIMARY KEY,b TEXT) STRICT;
                    CREATE VIEW visible AS SELECT *,CAST(a AS INTEGER) AS int_value,
                      CAST(a AS FLOAT) AS real_value,CAST(a AS VARCHAR(8)) AS text_value,
                      CAST(a AS BLOB) AS blob_value,CAST(a AS NUMERIC) AS numeric_value,
                      a+1 AS expr,id AS id FROM sample;
                    CREATE VIEW renamed(ident,label) AS SELECT id,a FROM sample;
                    CREATE VIEW joined AS SELECT * FROM sample LEFT JOIN keyed USING(a);
                    CREATE VIEW derived AS SELECT * FROM (SELECT id,a FROM sample);
                    CREATE VIEW infinite AS WITH RECURSIVE q(x) AS
                      (VALUES(1) UNION ALL SELECT x+1 FROM q) SELECT x FROM q;
                    CREATE VIEW dangerous AS WITH q AS (SELECT metadata_probe() AS x)
                      SELECT metadata_probe() AS x FROM q WHERE metadata_probe()
                      LIMIT metadata_probe();
                    CREATE VIEW nested AS SELECT * FROM dangerous;
                    CREATE VIEW scalar_metadata AS SELECT
                      (SELECT a FROM sample) AS a,
                      (SELECT CAST(b AS INTEGER) FROM sample) AS b,
                      (SELECT CAST(a AS VARCHAR(8)) FROM sample) AS text_value,
                      (SELECT (SELECT c FROM sample)) AS untyped,
                      (SELECT sample.b WHERE metadata_probe()) AS correlated,
                      EXISTS(SELECT b FROM sample) AS present,
                      +(SELECT b FROM sample) AS unary,
                      (WITH q AS (SELECT b FROM sample) SELECT b FROM q) AS cte_value
                      FROM sample WHERE metadata_probe() LIMIT metadata_probe();
                    CREATE VIEW cte_metadata AS WITH q(x,x) AS
                      (SELECT a,b FROM sample) SELECT x,"x:1" FROM q;
                    CREATE VIEW derived_metadata AS SELECT a,"a:1"
                      FROM (SELECT a,b AS a FROM sample);
                    CREATE TABLE rowid_source(rowid TEXT);
                    CREATE VIEW rowid_metadata AS SELECT rowid
                      FROM sample,rowid_source;
                    CREATE VIEW full_metadata AS SELECT *
                      FROM sample FULL JOIN keyed USING(a);
                    CREATE VIEW right_metadata AS SELECT *
                      FROM sample RIGHT JOIN keyed USING(a);
                    CREATE VIEW nested_scalar AS SELECT
                      (SELECT value FROM (SELECT CAST(a AS FLOAT) AS value
                        FROM sample)) AS real_value,
                      (SELECT rowid FROM sample) AS row_id FROM sample;
                    CREATE VIEW compound_scalar AS SELECT
                      (SELECT a FROM sample UNION ALL SELECT b FROM sample)
                        AS value FROM sample;
                    CREATE VIEW main_metadata AS WITH sample(a) AS (VALUES(1))
                      SELECT main.physical.a,main.physical.b
                      FROM main.sample AS physical;
                """)
                with sqlite3.connect(image) as destination:
                    native.backup(destination)
                input_path = root / 'input.json'
                input_path.write_text(json.dumps({'image': str(image), 'queries': queries}))
                result = subprocess.run(
                    ['dart', '--suppress-analytics', 'run', 'tool/metadata_pragma_differential.dart', str(input_path)],
                    cwd=ROOT.parents[1], capture_output=True, text=True)
                if result.returncode:
                    raise RuntimeError(result.stderr)
                actual = json.loads(result.stdout)
                for sql, value in zip(queries, actual, strict=True):
                    try:
                        cursor = native.execute(sql)
                        expected = {'columns': [c[0] for c in cursor.description],
                                    'rows': [[encode(v) for v in row] for row in cursor.fetchall()]}
                    except sqlite3.Error:
                        expected = {'error': True}
                    if 'error' in expected or 'error' in value:
                        if value != expected:
                            raise RuntimeError(f'{encoding}: {sql}\nDart: {value}\nSQLite: {expected}')
                        total += 1
                        continue
                    if 'table_list' in sql:
                        expected['rows'] = [row for row in expected['rows'] if row[0] == 'main']
                    if 'function_list' in sql:
                        signatures = {(r[0], json.dumps(r[1])) for r in value['rows']}
                        expected['rows'] = [row for row in expected['rows']
                                            if (row[0], json.dumps(row[1])) in signatures]
                    if 'pragma_list' in sql:
                        supported = {row[0] for row in value['rows']}
                        expected['rows'] = [row for row in expected['rows'] if row[0] in supported]
                    if any(name in sql for name in ['table_list', 'function_list', 'pragma_list']):
                        value['rows'].sort(key=lambda r: json.dumps(r, sort_keys=True))
                        expected['rows'].sort(key=lambda r: json.dumps(r, sort_keys=True))
                    if value != expected:
                        raise RuntimeError(f'{encoding}: {sql}\nDart: {value}\nSQLite: {expected}')
                    total += 1
                if calls:
                    raise RuntimeError('Native metadata invoked callbacks')
    print(f'Pinned metadata PRAGMAs agree: {total} comparisons across three encodings; '
          'supported main-image/signature subset only')


if __name__ == '__main__':
    main()
