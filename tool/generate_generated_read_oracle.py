"""Pinned development-only VIRTUAL/STORED generated-column read oracle."""
import hashlib
import json
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

OUTPUT = ROOT / 'generated_read_oracle.json'


def cases():
    result = []
    for suffix in ['', ' WITHOUT ROWID', ' STRICT']:
        setup = [
            'CREATE TABLE t(a INTEGER PRIMARY KEY, '
            'v INTEGER AS(visit(a)) VIRTUAL, '
            's INTEGER AS(visit(a)) STORED, '
            'w INTEGER AS(visit(v+10)) VIRTUAL)' + suffix,
            'INSERT INTO t(a)VALUES(1),(2),(3)',
        ]
        for sql in [
            'SELECT a FROM t',
            'SELECT v FROM t',
            'SELECT v,v FROM t',
            'SELECT s,s FROM t',
            'SELECT a FROM t LIMIT 1',
            'SELECT v FROM t LIMIT 1',
            'SELECT v FROM t LIMIT 0',
            'SELECT count(*) FROM t',
            'SELECT v FROM t WHERE v>1',
            'SELECT v FROM t WHERE a=2',
            'SELECT v FROM t ORDER BY a DESC LIMIT 1',
            'SELECT v FROM t ORDER BY v DESC LIMIT 1',
            'SELECT w,w FROM t WHERE a=2',
            'SELECT v,s FROM t WHERE a=2',
            'SELECT t.v,x.v FROM t JOIN t x ON x.a=t.a WHERE t.a=2',
            'SELECT * FROM t WHERE a=2',
            'SELECT a FROM t WHERE 0 AND v',
            'SELECT 0 AND v, v AND 0, 1 OR v, v OR 2 FROM t',
            'SELECT 0_0 AND v, 1_0 OR v, +0 AND v, -0 AND v FROM t',
            'SELECT 0.0 AND v, 2147483648 OR v, 0x0 AND v FROM t',
            'SELECT 0 AND missing, missing OR 1 FROM t',
            'SELECT 0 AND sum(v) FROM t',
            'SELECT 0 AND row_number() OVER(ORDER BY a) FROM t',
            'SELECT CASE WHEN a=2 THEN v ELSE s END FROM t',
            'SELECT (SELECT v FROM t WHERE a=x.a) FROM t x',
            'SELECT v,v FROM(SELECT v FROM t) WHERE v>1 LIMIT 1',
            'WITH c AS MATERIALIZED(SELECT v FROM t) SELECT v,v FROM c',
        ]:
            result.append(dict(name=suffix.strip() + ' ' + sql,
                               setup=setup, sql=sql, fail=False))
        for sql in [
            'SELECT a,s FROM t',
            'SELECT count(*) FROM t',
            'SELECT a FROM t WHERE a=99',
            'SELECT CASE WHEN 0 THEN v ELSE s END FROM t',
            'SELECT v FROM t LIMIT 0',
            'SELECT v FROM t',
            'SELECT w FROM t WHERE a=2',
        ]:
            result.append(dict(name=suffix.strip() + ' error guard ' + sql,
                               setup=setup, sql=sql, fail=True))
    return result


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    suites = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        observed = []
        for case in cases():
            with sqlite3.connect(':memory:', isolation_level=None) as db:
                assert db.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
                assert sorted(r[0] for r in db.execute('PRAGMA compile_options')) == manifest['compile_options']
                db.execute(f"PRAGMA encoding='{label}'")
                trace = []
                fail = False

                def visit(value):
                    trace.append(encode(value))
                    if fail:
                        raise ValueError('requested generated expression error')
                    return value

                db.create_function('visit', 1, visit, deterministic=True)
                for sql in case['setup']:
                    db.execute(sql)
                trace.clear()
                fail = case['fail']
                entry = dict(case)
                try:
                    cursor = db.execute(case['sql'])
                    entry['columns'] = [c[0] for c in cursor.description]
                    entry['rows'] = [[encode(v) for v in row] for row in cursor]
                except sqlite3.Error:
                    entry['error'] = True
                    entry.pop('columns', None)
                entry['trace'] = trace
                observed.append(entry)
        suites.append(dict(encoding=encoding, cases=observed))
    OUTPUT.write_text(json.dumps(dict(source_id=PIN, suites=suites), indent=2) + '\n')
    OUTPUT.with_suffix('.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest() + '\n')
    print(f'Generated {sum(len(s["cases"]) for s in suites)} generated-column read cases')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('Generated-column read oracle checksum passed')
    else:
        generate()
