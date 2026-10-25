"""Development-only row-assignment and evaluation-order oracle."""
import hashlib
import json
import sqlite3
import sys
from generate_fixtures import ROOT, PIN
from generate_sql_oracle import encode

OUTPUT = ROOT / 'assignment_oracle.json'


def statements():
    result = ['CREATE TABLE t(id INTEGER PRIMARY KEY,a,b,c)',
              'CREATE TABLE src(k,a,b)', 'INSERT INTO src VALUES(1,7,8),(2,9,10)']
    clauses = [
        '(a,b)=(b,a)', '(a,b)=(tick(),tick())', '(b,a)=(tick(),tick())',
        'b=tick(),a=tick()', '(a,b)=(tick(),tick()),a=99',
        '(a,a)=(tick(),tick())', '(a,b)=(tick(),tick()),a=99,b=98',
        '(a,b)=(SELECT tick(),tick())', '(a,b)=(SELECT tick(),tick()),a=99',
        '(b,a)=(SELECT tick(),tick())', '(a,b)=(VALUES(tick(),tick()))',
        '(a,b)=(SELECT s.a,s.b FROM src s WHERE s.k=t.id)',
        '(a,b)=(SELECT s.a,s.b FROM src s WHERE 0)',
        '(a,b)=(SELECT count(*),max(k) FROM src)',
        '(a,b)=(SELECT 1,2 UNION ALL SELECT 3,4)', '(a)=(tick())',
        '(id,a)=(tick(),tick()),b=tick()', 'a=tick(),id=tick(),b=tick()',
        '(a,b)=1', '(a,b)=(1,2,3)', '(a,b)=(SELECT 1)',
        '(a,b)=(SELECT * FROM src)', '(a,b)=(SELECT missing,1 FROM src)',
        '(a,missing)=(1,2)', '(a,b)=(sum(a),1)', '(t.a,b)=(1,2)',
    ]
    for clause in clauses:
        result += ['DELETE FROM t', 'INSERT INTO t VALUES(1,10,20,30),(2,40,50,60)',
                   'UPDATE t SET '+clause+' RETURNING id,a,b,c', 'SELECT * FROM t ORDER BY id']
    result += ['DELETE FROM t']
    for clause in ['(a,b)=(SELECT 1)', '(a,b)=(SELECT * FROM src)', '(a,b)=1']:
        result.append('UPDATE t SET '+clause)
    result += ['INSERT INTO t VALUES(1,10,20,30),(2,40,50,60)']
    for clause in ['(a,b)=(excluded.b,excluded.a)', '(b,a)=(tick(),tick())',
                   '(a,b)=(SELECT tick(),tick())', '(a,b)=(1,2),a=3',
                   '(a,b)=(1,2,3)']:
        result += ['INSERT INTO t VALUES(1,70,80,90) ON CONFLICT(id) DO UPDATE SET '+clause+' RETURNING *',
                   'SELECT * FROM t ORDER BY id']
    result += [
        'UPDATE t SET (a,b)=(s.a,s.b) FROM src s WHERE t.id=s.k RETURNING *',
        'UPDATE t SET (a,b)=(SELECT tick(),s.b) FROM src s WHERE t.id=s.k RETURNING *',
        'WITH q AS(SELECT k,a,b FROM src) UPDATE t SET (a,b)=(SELECT q.a,q.b FROM q WHERE q.k=t.id) RETURNING *',
        'CREATE TABLE events(id)',
        'CREATE TRIGGER changed AFTER INSERT ON events BEGIN UPDATE t SET (a,b)=(b,a) WHERE id=new.id; END',
        'INSERT INTO events VALUES(1)', 'SELECT * FROM t ORDER BY id',
        'ALTER TABLE t RENAME a TO amount', 'ALTER TABLE t RENAME TO renamed',
        'INSERT INTO events VALUES(2)', 'SELECT * FROM renamed ORDER BY id',
        'CREATE VIEW v AS SELECT id,amount,b FROM renamed',
        'CREATE TRIGGER view_update INSTEAD OF UPDATE ON v BEGIN UPDATE renamed SET (amount,b)=(new.amount,new.b) WHERE id=old.id; END',
        'UPDATE v SET (amount,b)=(b,amount) WHERE id=1', 'SELECT * FROM v ORDER BY id',
        'CREATE TABLE wr(a,b,k PRIMARY KEY) WITHOUT ROWID', 'INSERT INTO wr VALUES(10,20,30)',
        'UPDATE wr SET b=tick(),a=tick(),k=tick() RETURNING *',
        'UPDATE wr SET (a,b)=(b,a) RETURNING *',
        'CREATE TABLE dotted("a.b",c)', 'INSERT INTO dotted VALUES(1,2)',
        'UPDATE dotted SET ("a.b",c)=(c,"a.b") RETURNING *',
        'CREATE UNIQUE INDEX dotted_key ON dotted(c)',
        'INSERT INTO dotted VALUES(5,1) ON CONFLICT(c) DO UPDATE SET ("a.b",c)=(excluded.c,excluded."a.b") RETURNING *',
        'CREATE TABLE generated_aliases(x,rowid AS(x+1),_rowid_ AS(x+2),oid AS(x+3))',
        'INSERT INTO generated_aliases(x) VALUES(1)',
        'UPDATE generated_aliases SET (rowid,x)=(8,3)',
        'INSERT INTO generated_aliases(rowid,x) VALUES(8,3)',
        'UPDATE generated_aliases SET (_rowid_,oid)=(8,9)',
        'SELECT * FROM generated_aliases',
        'PRAGMA integrity_check',
    ]
    return result


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    suites = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        with sqlite3.connect(':memory:', isolation_level=None) as db:
            assert db.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
            assert sorted(row[0] for row in db.execute('PRAGMA compile_options')) == manifest['compile_options']
            db.execute(f"PRAGMA encoding='{label}'")
            calls = 0
            def tick():
                nonlocal calls
                calls += 1
                return calls
            db.create_function('tick', 0, tick)
            steps = []
            for sql in statements():
                step = {'sql': sql, 'query': sql.startswith(('SELECT', 'PRAGMA'))}
                try:
                    cursor = db.execute(sql)
                    step['rows'] = [[encode(value) for value in row] for row in cursor] if cursor.description else []
                    # Python reports -1 for WITH DML; the SQL counter is authoritative.
                    step['changes'] = db.execute('SELECT changes()').fetchone()[0] if sql.startswith(('INSERT', 'REPLACE', 'UPDATE', 'DELETE', 'WITH')) else 0
                except sqlite3.Error as error:
                    step['error'] = str(error)
                step['calls'] = calls
                steps.append(step)
            suites.append({'encoding': encoding, 'steps': steps})
    OUTPUT.write_text(json.dumps({'source_id': PIN, 'suites': suites}, indent=2)+'\n')
    OUTPUT.with_suffix('.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest()+'\n')
    print(f'Generated {sum(len(s["steps"]) for s in suites)} pinned assignment operations')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('Assignment oracle checksum verified')
    else:
        generate()
