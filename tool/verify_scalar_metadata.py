"""Pinned scalar-subquery metadata, affinity, CTAS and callback comparison."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def operations():
    result = [
        {'sql': 'CREATE TABLE t(a TEXT COLLATE NOCASE,b INT,c REAL,d)'},
        {'sql': "INSERT INTO t VALUES('01',1,1,'A')"},
    ]
    expressions = [
        '(SELECT a FROM t)', '(SELECT b FROM t)', '(SELECT c FROM t)',
        '(SELECT d FROM t)', '(SELECT t.b)', '(SELECT (SELECT t.b))',
        '(SELECT CAST(b AS INTEGER) FROM t)',
        '(SELECT CAST(a AS TEXT) FROM t)',
        '(SELECT CAST(a AS BLOB) FROM t)',
        '(SELECT a FROM t UNION ALL SELECT b FROM t)',
        '(SELECT b FROM t UNION ALL SELECT a FROM t)',
        '(SELECT b FROM t UNION ALL SELECT c FROM t)',
        '(SELECT a FROM t UNION SELECT b FROM t)',
        '(SELECT a FROM t WHERE 0)', '(SELECT b FROM t WHERE 0)',
        '(WITH q AS (SELECT b FROM t) SELECT b FROM q)',
        '(SELECT * FROM (SELECT b FROM t))',
        '(SELECT gb.b FROM (t AS ga JOIN t AS gb USING(a)) AS q)',
    ]
    for i, expression in enumerate(expressions):
        result.extend([
            {'sql': f'SELECT {expression}=1,{expression}=\'01\' FROM t', 'query': True},
            {'sql': f'SELECT value=1,value=\'01\' FROM (SELECT {expression} AS value FROM t)', 'query': True},
            {'sql': f'CREATE TABLE copied_{i} AS SELECT {expression} AS value FROM t'},
            {'sql': f'PRAGMA table_info(copied_{i})', 'query': True},
            {'sql': f'SELECT typeof(value),value FROM copied_{i}', 'query': True},
        ])
    result += [
        {'sql': 'CREATE TABLE unexecuted AS SELECT (SELECT CAST(tick() AS INTEGER)) AS value LIMIT 0'},
        {'sql': 'PRAGMA table_info(unexecuted)', 'query': True},
        {'sql': 'SELECT (SELECT tick())', 'query': True},
        {'sql': 'SELECT value FROM (SELECT (SELECT tick()) AS value) LIMIT 0', 'query': True},
        {'sql': 'SELECT (SELECT missing FROM t) FROM t WHERE 0', 'query': True},
        {'sql': 'SELECT (SELECT * FROM t) FROM t WHERE 0', 'query': True},
    ]
    return result


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    total = 0
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        with sqlite3.connect(':memory:', isolation_level=None) as native:
            if native.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
                raise RuntimeError('Wrong SQLite source ID')
            if sorted(r[0] for r in native.execute('PRAGMA compile_options')) != manifest['compile_options']:
                raise RuntimeError('Wrong SQLite compile options')
            native.execute(f"PRAGMA encoding='{label}'")
            calls = 0

            def tick():
                nonlocal calls
                calls += 1
                return calls

            native.create_function('tick', 0, tick)
            steps = operations()
            expected = []
            for step in steps:
                error = False
                rows = None
                changes = 0
                try:
                    cursor = native.execute(step['sql'])
                    if cursor.description is not None:
                        rows = [[encode(v) for v in row] for row in cursor]
                    if not step.get('query'):
                        changes = max(cursor.rowcount, 0)
                except sqlite3.Error:
                    error = True
                expected.append({'error': error, 'changes': changes,
                                 'calls': calls, 'rows': rows})
            with tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / 'operations.json'
                source.write_text(json.dumps(steps))
                process = subprocess.run(
                    ['dart', '--suppress-analytics', 'run',
                     'tool/lazy_view_differential.dart', str(source), str(encoding)],
                    cwd=ROOT.parents[1], capture_output=True, text=True)
                if process.returncode:
                    raise RuntimeError(process.stderr)
                actual = json.loads(process.stdout)
                for step, got, want in zip(steps, actual, expected, strict=True):
                    if got != want:
                        raise RuntimeError(f'{label}: {step["sql"]}\nDart: {got}\nSQLite: {want}')
                    total += 1
    print(f'Pinned scalar metadata agrees: {total} operations across three encodings')


if __name__ == '__main__':
    main()
