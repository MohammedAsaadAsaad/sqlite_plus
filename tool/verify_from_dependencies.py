"""Pinned native ALTER checks for UPDATE FROM and joined-source dependencies."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def operations():
    statements = [
        'CREATE TABLE target(id INTEGER PRIMARY KEY,v INT,spare INT)',
        'CREATE TABLE source(id INTEGER PRIMARY KEY,amount INT,spare INT)',
        'CREATE TABLE events(id INT)',
        'INSERT INTO target VALUES(1,0,0),(2,0,0)',
        'INSERT INTO source VALUES(1,7,0),(2,11,0)',
        'CREATE TRIGGER changed AFTER INSERT ON events BEGIN '
        'UPDATE target SET v=s.amount+(SELECT r.amount FROM source r WHERE r.id=s.id) '
        'FROM main.source s WHERE target.id=s.id AND s.id=new.id; END',
        'ALTER TABLE source RENAME amount TO value',
        'ALTER TABLE target RENAME v TO result',
        'ALTER TABLE events RENAME id TO ident',
        'ALTER TABLE source DROP value','ALTER TABLE source DROP spare',
        'INSERT INTO events VALUES(1)',
        'SELECT id,result FROM target ORDER BY id',
        'ALTER TABLE source RENAME TO renamed',
        'ALTER TABLE target RENAME TO destination',
        'INSERT INTO events VALUES(2)',
        'SELECT id,result FROM destination ORDER BY id',
        'DROP TRIGGER changed',
        'CREATE TRIGGER changed AFTER INSERT ON events BEGIN '
        'UPDATE destination SET result=renamed.value FROM main.renamed '
        'WHERE destination.id=renamed.id AND renamed.id=new.ident; END',
        'ALTER TABLE renamed RENAME TO input',
        'ALTER TABLE destination RENAME TO output',
        'UPDATE output SET result=0','INSERT INTO events VALUES(1)',
        'SELECT id,result FROM output ORDER BY id',
        'CREATE TABLE extra(id INT,n INT)','INSERT INTO extra VALUES(1,100),(2,200)',
        'DROP TRIGGER changed',
        'CREATE TRIGGER changed AFTER INSERT ON events BEGIN '
        'UPDATE output SET result=s.value+e.n FROM input s JOIN extra e USING(id) '
        'WHERE output.id=s.id AND s.id=new.ident; END',
        'ALTER TABLE extra RENAME n TO number',
        'ALTER TABLE extra DROP number',
        'INSERT INTO events VALUES(2)',
        'SELECT id,result FROM output ORDER BY id',
        'DROP TRIGGER changed',
        'CREATE TRIGGER changed AFTER INSERT ON events BEGIN '
        'UPDATE output SET result=q.value FROM (input JOIN extra USING(id)) q '
        'WHERE output.id=q.id AND q.id=new.ident; END',
        'ALTER TABLE input RENAME value TO amount',
        'ALTER TABLE input RENAME TO incoming',
        'DROP TRIGGER changed',
    ]
    variants = [
        ('a.x,a.y,b.z', '(a JOIN b ON a.x=b.x)'),
        ('a.x,a.y,b.z', 'a JOIN (b JOIN c ON b.z=c.w) ON a.x=b.x'),
        ('q.x,q.y', '(a JOIN b ON a.x=b.x) q'),
        ('q."x:1"', '(a JOIN b ON a.x=b.x) q'),
        ('q."x:2"', '(a JOIN b USING(x)) q'),
        ('a.x', '(a JOIN b ON a.x=b.x) q'),
        ('a.*', '(a JOIN b USING(x)) q'),
        ('q.*', '(a JOIN b USING(x)) q'),
        ('*', 'a JOIN (b JOIN c ON b.z=c.w) USING(x)'),
        ('*', '(a NATURAL LEFT JOIN b)'),
    ]
    for i, (fields, sources) in enumerate(variants):
        a,b,c,v = f'a{i}',f'b{i}',f'c{i}',f'v{i}'
        def substitute(sql):
            import re
            return re.sub(r'\b(a|b|c)\b', lambda m: {'a':a,'b':b,'c':c}[m[0]], sql)
        statements += [f'CREATE TABLE {a}(x INT,y INT,spare INT)',
            f'CREATE TABLE {b}(x INT,z INT)',f'CREATE TABLE {c}(w INT)',
            f'INSERT INTO {a} VALUES(1,10,0),(2,20,0)',
            f'INSERT INTO {b} VALUES(1,100),(3,300)',f'INSERT INTO {c} VALUES(100),(300)',
            f'CREATE VIEW {v} AS SELECT {substitute(fields)} FROM {substitute(sources)}',
            f'ALTER TABLE {a} RENAME spare TO unused',
            f'ALTER TABLE {a} RENAME y TO label',
            f'ALTER TABLE {a} RENAME x TO key',
            f'ALTER TABLE {a} RENAME TO renamed_{a}',
            f'SELECT * FROM {v}',f'DROP VIEW {v}']
    statements += ['PRAGMA integrity_check']
    return statements


def probe_native_broken_trigger_quirk():
    # The pinned engine rewrites qualified fields in UPDATE FROM but does not
    # validate USING keys after ALTER. It accepts a schema with a broken trigger.
    # The engine deliberately rejects this alteration atomically; the focused
    # from_dependency_test.dart test verifies the unchanged image.
    with sqlite3.connect(':memory:') as reference:
        reference.executescript('CREATE TABLE a(id,v);CREATE TABLE b(id,n);'
            'CREATE TABLE c(id);CREATE TABLE events(id);'
            'CREATE TRIGGER t AFTER INSERT ON events BEGIN '
            'UPDATE c SET id=a.id FROM a JOIN b USING(id); END;')
        reference.execute('ALTER TABLE a RENAME id TO ident')
        assert 'USING(id)' in reference.execute(
            "SELECT sql FROM sqlite_schema WHERE name='t'").fetchone()[0]
        try:
            reference.execute('INSERT INTO events VALUES(1)')
        except sqlite3.Error as error:
            assert 'cannot join using column' in str(error)
        else:
            raise RuntimeError('Pinned broken-trigger behavior changed')


def main():
    manifest = json.loads((ROOT/'manifest.json').read_text())
    with sqlite3.connect(':memory:') as check:
        if check.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(r[0] for r in check.execute('PRAGMA compile_options')) != manifest['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    probe_native_broken_trigger_quirk()
    statements = operations()
    for encoding in [1,2,3]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'operations.json').write_text(json.dumps([{'sql':sql,'parameters':[],
                'query':sql.split()[0].upper() == 'SELECT' or sql.upper().startswith('PRAGMA')} for sql in statements]))
            subprocess.run(['dart','--suppress-analytics','run','tool/export_schema.dart',temporary,str(encoding)],
                cwd=ROOT.parents[1],check=True)
            with sqlite3.connect(root/'reference.db',isolation_level=None) as reference:
                reference.execute('PRAGMA page_size=512')
                reference.execute("PRAGMA encoding='"+{1:'UTF-8',2:'UTF-16le',3:'UTF-16be'}[encoding]+"'")
                for i,sql in enumerate(statements):
                    error,expected = None,None
                    try:
                        cursor = reference.execute(sql)
                        if cursor.description:
                            expected = {'columns':[c[0] for c in cursor.description],
                                'rows':[[encode(v) for v in row] for row in cursor.fetchall()]}
                    except sqlite3.Error as exception:
                        error = str(exception)
                    actual = json.loads((root/f'{i}.json').read_text())
                    if (error is None) != (actual['error'] is None):
                        raise RuntimeError(f'{encoding} {i} {sql}: SQLite={error}; Dart={actual}')
                    if actual['returning'] != expected:
                        raise RuntimeError(f'{encoding} {i} {sql}: SQLite={expected}; Dart={actual}')
                    if error is None and sql.split()[0].upper() in ['INSERT','UPDATE','DELETE'] and cursor.rowcount != actual['changes']:
                        raise RuntimeError(f'{encoding} {i} {sql}: change count mismatch')
                    with sqlite3.connect(f'file:{root/str(i)}.db?mode=ro',uri=True) as image:
                        integrity = image.execute('PRAGMA integrity_check').fetchall()
                        if integrity != [('ok',)]:
                            raise RuntimeError(f'{encoding} {i} {sql}: integrity={integrity}')
                        for (table,) in reference.execute("SELECT name FROM sqlite_schema WHERE type='table'").fetchall():
                            escaped = '"'+table.replace('"','""')+'"'
                            expected_rows = reference.execute(f'SELECT * FROM {escaped}').fetchall()
                            actual_rows = image.execute(f'SELECT * FROM {escaped}').fetchall()
                            if sorted(expected_rows,key=repr) != sorted(actual_rows,key=repr):
                                raise RuntimeError(f'{encoding} {i} {sql}: {table} rows SQLite={expected_rows}; Dart={actual_rows}')
            print(f'Pinned UPDATE FROM/group dependencies agree: {len(statements)} cross-open/integrity snapshots, encoding={encoding}')


if __name__ == '__main__':
    main()
