"""Development-only callback/empty-input checks against the pinned SQLite."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    statements = [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,x)',
        'CREATE TABLE pair(a,b)',
        'CREATE VIEW v AS SELECT tick() AS x',
        'UPDATE t SET x=(SELECT * FROM pair)',
        'UPDATE t SET x=CASE WHEN 0 THEN (SELECT * FROM pair) ELSE 1 END',
        'DELETE FROM t WHERE x IN (SELECT * FROM pair)',
        'DELETE FROM t WHERE (x,x) IN (SELECT a FROM pair)',
        'INSERT INTO t(x) VALUES(CASE WHEN 0 THEN (SELECT * FROM pair) ELSE 1 END)',
        'UPDATE t SET x=(SELECT a FROM pair)',
        'SELECT CASE WHEN 0 THEN (SELECT x FROM v) ELSE 7 END',
        'UPDATE t SET x=(SELECT x FROM v)',
        'DELETE FROM t WHERE x IN (SELECT x FROM v)',
        'INSERT INTO t(x) VALUES(CASE WHEN 0 THEN (SELECT x FROM v) ELSE 7 END)',
        'UPDATE t SET x=CASE WHEN 0 THEN (SELECT x FROM v) ELSE x END',
        'SELECT (SELECT x FROM v)',
        'UPDATE t SET x=(SELECT x FROM v) RETURNING x',
        'SELECT x FROM t',
        'INSERT INTO t VALUES(2,2)',
        'CREATE VIEW used AS SELECT tick() AS x',
        'CREATE VIEW unused AS SELECT tick() AS x',
        'UPDATE t SET x=(SELECT CASE WHEN t.id>0 THEN (SELECT x FROM used) ELSE (SELECT x FROM unused) END) RETURNING x',
        'CREATE VIEW middle_view AS SELECT x FROM v',
        'CREATE VIEW outer_view AS SELECT x FROM middle_view',
        'UPDATE t SET x=(SELECT x FROM outer_view) RETURNING x',
        'SELECT CASE WHEN 0 THEN (SELECT x FROM outer_view) ELSE 42 END',
        'CREATE VIEW forbidden AS SELECT abs(-9223372036854775808) AS x',
        'UPDATE t SET x=CASE WHEN 0 THEN (SELECT x FROM forbidden) ELSE x END',
        'SELECT (SELECT x FROM forbidden)',
        'SELECT CASE WHEN 0 THEN (SELECT x FROM forbidden) ELSE 43 END',
        'SELECT x FROM t ORDER BY id',
        'CREATE TABLE defaults(x DEFAULT(tick()),y DEFAULT(tick()))',
        'INSERT INTO defaults(x,y) VALUES(1,2),(3,4)',
        'INSERT INTO defaults(x) VALUES(5),(6)',
        'INSERT INTO defaults(y) VALUES(tick()),(tick())',
        'INSERT INTO defaults DEFAULT VALUES',
        'SELECT * FROM defaults',
        'CREATE TABLE defaults_log(x)',
        'CREATE TRIGGER defaults_ins AFTER INSERT ON defaults BEGIN INSERT INTO defaults_log VALUES(new.x); END',
        'INSERT INTO defaults(y) VALUES(tick()),(tick())',
        'SELECT * FROM defaults',
        'CREATE TABLE rowid_defaults(id INTEGER PRIMARY KEY DEFAULT(tick()),v)',
        'INSERT INTO rowid_defaults(v) VALUES(1),(2)',
        'INSERT INTO rowid_defaults(rowid,v) VALUES(10,3)',
        'SELECT * FROM rowid_defaults',
        'CREATE TABLE error_default(x DEFAULT(abs(-9223372036854775808)))',
        'INSERT INTO error_default VALUES(1),(2)',
        'INSERT INTO error_default DEFAULT VALUES',
        'SELECT * FROM error_default',
        'CREATE TABLE upsert_default(id PRIMARY KEY,x DEFAULT(tick()))',
        'INSERT INTO upsert_default VALUES(1,100)',
        'INSERT INTO upsert_default(id) VALUES(1) ON CONFLICT DO NOTHING',
        'INSERT INTO upsert_default VALUES(1,101) ON CONFLICT DO NOTHING',
        'INSERT INTO upsert_default(id) VALUES(1) ON CONFLICT DO UPDATE SET x=excluded.x RETURNING *',
        'INSERT INTO upsert_default VALUES(1,200) ON CONFLICT DO UPDATE SET x=excluded.x RETURNING *',
        'SELECT * FROM upsert_default',

    ]
    operations = [dict(sql=sql, query=sql.startswith('SELECT')) for sql in statements]
    for encoding in [1, 2, 3]:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'operations.json'
            path.write_text(json.dumps(operations))
            process = subprocess.run(['dart', '--suppress-analytics', 'run',
                                      'tool/lazy_view_differential.dart', str(path), str(encoding)],
                                     cwd=ROOT.parents[1], capture_output=True, text=True, check=True)
            observed = json.loads(process.stdout)
        calls = 0
        def tick():
            nonlocal calls
            calls += 1
            return calls
        with sqlite3.connect(':memory:', isolation_level=None) as reference:
            assert reference.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
            assert sorted(row[0] for row in reference.execute('PRAGMA compile_options')) == manifest['compile_options']
            reference.execute(f'PRAGMA encoding="{["UTF-8", "UTF-16le", "UTF-16be"][encoding-1]}"')
            reference.create_function('tick', 0, tick)
            for index, operation in enumerate(operations):
                error, rows, changes = False, None, 0
                try:
                    cursor = reference.execute(operation['sql'])
                    if cursor.description:
                        rows = [[encode(value) for value in row] for row in cursor.fetchall()]
                    if not operation['query']:
                        changes = max(0, cursor.rowcount)
                except sqlite3.DatabaseError:
                    error = True
                expected = dict(error=error, changes=changes, calls=calls, rows=rows)
                assert observed[index] == expected, (encoding, operation['sql'], observed[index], expected)
    print(f'Pinned SQLite lazy-view/preparation checks passed: {len(operations)} operations per encoding ({3*len(operations)} total)')


if __name__ == '__main__':
    main()
