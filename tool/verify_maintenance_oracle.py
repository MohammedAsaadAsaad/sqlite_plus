"""Development-only maintenance snapshots and index repair against pinned SQLite."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as connection:
        assert connection.execute('select sqlite_source_id()').fetchone()[0] == PIN
        assert sorted(row[0] for row in connection.execute('pragma compile_options')) == manifest['compile_options']
    statements = [
        'ANALYZE missing', 'REINDEX missing', 'REINDEX main',
        'REINDEX main.NOCASE', 'ANALYZE other.t', 'REINDEX other.t',
        'ANALYZE sqlite_master',
        'CREATE TABLE t(a TEXT COLLATE NOCASE,b INT,c)',
        'CREATE INDEX i ON t(a,b DESC)',
        'CREATE INDEX p ON t(c) WHERE b>1',
        'CREATE INDEX e ON t(lower(a),abs(b))',
        "INSERT INTO t VALUES('A',1,'x'),('a',2,'y'),('B',2,'y'),(NULL,3,NULL),(NULL,3,NULL)",
        'ANALYZE t', 'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        "INSERT INTO t VALUES('C',4,'z')", 'ANALYZE main.i',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'REINDEX i', 'REINDEX main.t', 'REINDEX binary', 'REINDEX NOCASE',
        'REINDEX rtrim', 'REINDEX sqlite_schema', 'REINDEX main.sqlite_master',
        'REINDEX', 'ANALYZE main.t',
        'CREATE TABLE wr(a TEXT,b,c,PRIMARY KEY(a COLLATE NOCASE DESC,b DESC)) WITHOUT ROWID',
        'CREATE INDEX wi ON wr(c)',
        "INSERT INTO wr VALUES('A',1,9),('a',2,9),('B',1,9)",
        'CREATE TABLE partial(a)', 'CREATE INDEX zero ON partial(a) WHERE 0',
        'INSERT INTO partial VALUES(NULL),(1),(2)',
        'CREATE TABLE empty(a UNIQUE)',
        'CREATE TABLE duplicate(a UNIQUE)',
        'INSERT INTO duplicate VALUES(NULL),(NULL),(1)',
        'CREATE TABLE plain(a)',
        'CREATE TABLE indexed(a UNIQUE)',
        'CREATE TABLE aliased(id INTEGER PRIMARY KEY,a)',
        'INSERT INTO plain(rowid,a) VALUES(-10,1),(40,2),(50,3)',
        'INSERT INTO indexed(rowid,a) VALUES(-10,1),(40,2),(50,3)',
        'INSERT INTO aliased VALUES(-10,1),(40,2),(50,3)',
        'ANALYZE main',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'ANALYZE wi', 'REINDEX wr', 'REINDEX main.wi',
        'VACUUM main', 'SELECT rowid,a FROM plain', 'SELECT rowid,a FROM indexed',
        'SELECT rowid,a FROM aliased',
        'BEGIN', 'DELETE FROM t', 'ANALYZE t',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'VACUUM', 'ROLLBACK',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'SAVEPOINT s', 'DROP INDEX p', 'ANALYZE partial', 'VACUUM',
        'ROLLBACK TO s', 'RELEASE s',
        'CREATE VIEW v AS SELECT * FROM t', 'ANALYZE v', 'REINDEX v',
        "UPDATE sqlite_stat1 SET stat='manually supplied' WHERE idx='wi'",
        'ANALYZE main.sqlite_schema', 'ANALYZE sqlite_stat1',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'ANALYZE', 'DROP INDEX e', 'DROP TABLE partial',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'ALTER TABLE duplicate RENAME TO renamed',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'DROP TABLE renamed',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'ANALYZE', 'VACUUM', 'PRAGMA integrity_check',
        'DROP TABLE sqlite_stat1', 'BEGIN', 'ANALYZE', 'ROLLBACK',
        'SELECT name FROM sqlite_schema WHERE name LIKE \'sqlite_stat%\'',
        'ANALYZE empty', 'ANALYZE main.empty',
        'SELECT tbl,idx,stat FROM sqlite_stat1 ORDER BY tbl,idx',
        'VACUUM other', 'VACUUM main.t', 'ANALYZE t extra',
        'REINDEX t extra', 'ANALYZE t.t.t', 'ANALYZE ?',
    ]
    operations = [dict(sql=sql, parameters=[], query=sql.startswith(('SELECT', 'PRAGMA')))
                  for sql in statements]
    for encoding in [1, 2, 3]:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'operations.json').write_text(json.dumps(operations))
            subprocess.run(['dart', '--suppress-analytics', 'run', 'tool/export_schema.dart', str(directory), str(encoding)],
                           cwd=ROOT.parents[1], check=True)
            with sqlite3.connect(':memory:', isolation_level=None) as reference:
                reference.execute(f'pragma encoding="{["UTF-8", "UTF-16le", "UTF-16be"][encoding-1]}"')
                for i, operation in enumerate(operations):
                    expected_error = None
                    rows = None
                    changes = 0
                    try:
                        cursor = reference.execute(operation['sql'])
                        if cursor.description:
                            rows = dict(columns=[col[0] for col in cursor.description],
                                        rows=[[encode(value) for value in row] for row in cursor.fetchall()])
                        if not operation['query']:
                            changes = max(0, cursor.rowcount)
                    except sqlite3.DatabaseError as error:
                        expected_error = str(error)
                    actual = json.loads((directory / f'{i}.json').read_text())
                    context = f'encoding {encoding}, step {i}: {operation["sql"]}'
                    assert bool(actual['error']) == bool(expected_error), (context, actual, expected_error)
                    assert actual['changes'] == changes, (context, actual, changes)
                    assert actual['returning'] == rows, (context, actual, rows)
                    with sqlite3.connect(f'file:{directory / str(i)}.db?mode=ro', uri=True) as opened:
                        assert opened.execute('pragma integrity_check').fetchall() == [('ok',)], context
                        expected_names = reference.execute("select name from sqlite_schema where type='table' order by name").fetchall()
                        assert opened.execute("select name from sqlite_schema where type='table' order by name").fetchall() == expected_names, context
                        for (name,) in expected_names:
                            quoted = '"' + name.replace('"', '""') + '"'
                            sql = reference.execute('select sql from sqlite_schema where name=?', (name,)).fetchone()[0]
                            if name == 'sqlite_stat1':
                                query = f'SELECT * FROM {quoted} ORDER BY tbl,idx,stat'
                            elif 'WITHOUT ROWID' in sql.upper():
                                width = len(reference.execute(f'pragma table_info({quoted})').fetchall())
                                query = f'SELECT * FROM {quoted} ORDER BY ' + ','.join(str(n+1) for n in range(width))
                            else:
                                query = f'SELECT rowid,* FROM {quoted} ORDER BY rowid'
                            expected = reference.execute(query).fetchall()
                            observed = opened.execute(query).fetchall()
                            assert observed == expected, (context, name, observed, expected)
            # An index created using a temporarily overridden deterministic
            # builtin contains stale keys under the normal builtin definition.
            stale = directory / 'stale.db'
            with sqlite3.connect(stale) as native:
                native.execute(f'pragma encoding="{["UTF-8", "UTF-16le", "UTF-16be"][encoding-1]}"')
                native.create_function('abs', 1, lambda value: 100-value, deterministic=True)
                native.executescript('CREATE TABLE repair(a);CREATE INDEX ri ON repair(abs(a));INSERT INTO repair VALUES(-3),(1),(5);')
            repaired = directory / 'repaired.db'
            subprocess.run(['dart', '--suppress-analytics', 'run', 'tool/repair_index_image.dart', str(stale), str(repaired)],
                           cwd=ROOT.parents[1], check=True)
            with sqlite3.connect(repaired) as native:
                assert native.execute('pragma integrity_check').fetchall() == [('ok',)]
                assert native.execute('select abs(a) from repair indexed by ri order by abs(a)').fetchall() == [(1,), (3,), (5,)]
    print(f'Pinned SQLite maintenance checks passed: {len(operations)} snapshots per encoding ({3*len(operations)} total), plus three stale expression-index repairs')


if __name__ == '__main__':
    main()
