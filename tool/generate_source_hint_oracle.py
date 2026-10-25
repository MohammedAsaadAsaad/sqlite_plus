"""Pinned development-only schema-qualified source and index-hint oracle."""
import hashlib
import json
import sqlite3
import sys
from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

PATH = ROOT / 'source_hint_oracle.json'
SETUP = [
    'CREATE TABLE main.t(id INTEGER PRIMARY KEY,x TEXT COLLATE NOCASE,n INT)',
    "INSERT INTO main.t VALUES(1,'B',2),(2,'a',3),(3,'c',NULL)",
    'CREATE INDEX main.ix ON t(x)',
    'CREATE INDEX main.ip ON t(n) WHERE n IS NOT NULL',
    'CREATE TABLE main.w(a TEXT COLLATE NOCASE,b INT,c,PRIMARY KEY(a,b)) WITHOUT ROWID',
    "INSERT INTO main.w VALUES('B',2,9),('a',3,8),('c',4,7)",
    'CREATE INDEX main.iw ON w(c DESC)',
    'CREATE INDEX main.iwp ON w(a COLLATE BINARY,c)',
    'CREATE VIEW main.v AS SELECT id,x,n FROM main.t',
]
QUERIES = [
    'SELECT * FROM main.t ORDER BY id', 'SELECT main.t.x FROM main.t ORDER BY id',
    'SELECT main.z.x FROM t AS z ORDER BY id', 'SELECT main.t.x FROM t AS z',
    'SELECT main.v.x FROM main.v ORDER BY id', 'SELECT main.z.x FROM v AS z ORDER BY id',
    'SELECT * FROM other.t', 'SELECT other.t.x FROM t',
    'SELECT main.t.* FROM main.t',
    'WITH t AS (SELECT 99 AS id) SELECT * FROM main.t ORDER BY id',
    'WITH t AS (SELECT * FROM main.t) SELECT * FROM t ORDER BY id',
    'WITH t AS (SELECT id FROM main.t UNION SELECT id FROM main.t) SELECT * FROM t ORDER BY id',
    'WITH RECURSIVE t(id) AS (SELECT id FROM main.t WHERE id=1 UNION ALL SELECT id+1 FROM t WHERE id<3) SELECT * FROM t',
    'WITH t AS (SELECT 99 AS id) SELECT main.t.id FROM t',
    'WITH t AS (SELECT 99 AS id) SELECT t.id,main.q.id FROM t,main.t AS q ORDER BY q.id',
    'WITH v AS (SELECT 99 AS id) SELECT * FROM main.v ORDER BY id',
    'SELECT id,x FROM main.t INDEXED BY ix ORDER BY id',
    'SELECT id FROM main.t AS q INDEXED BY ix WHERE q.x>=\'a\' ORDER BY id',
    'SELECT * FROM t INDEXED BY missing', 'SELECT * FROM t INDEXED BY iw',
    'SELECT * FROM t INDEXED BY main.ix', 'SELECT * FROM t INDEXED BY ix AS q',
    'SELECT * FROM t NOT INDEXED WHERE id=2',
    'SELECT * FROM t NOT INDEXED WHERE n>1 ORDER BY id',
    'SELECT * FROM t INDEXED BY ip',
    'SELECT * FROM t INDEXED BY ip WHERE n IS NOT NULL ORDER BY id',
    'SELECT * FROM t INDEXED BY ip WHERE n>1 ORDER BY id',
    'SELECT * FROM t AS q INDEXED BY ip WHERE q.n>1 ORDER BY id',
    'SELECT * FROM main.t AS q INDEXED BY ip WHERE main.q.n IS NOT NULL ORDER BY id',
    'SELECT q.id FROM t AS q INDEXED BY ip JOIN t AS r ON q.id=r.id WHERE r.n IS NOT NULL',
    'SELECT * FROM v INDEXED BY ix',
    'WITH t AS (SELECT 1 AS x) SELECT * FROM t INDEXED BY ix',
    'WITH t AS (SELECT 1 AS x) SELECT * FROM t NOT INDEXED',
    'SELECT * FROM t AS q INDEXED BY missing JOIN w ON q.id=w.b',
    'SELECT * FROM w INDEXED BY iw ORDER BY a,b',
    'SELECT * FROM w INDEXED BY iwp ORDER BY a,b',
    'SELECT * FROM w INDEXED BY sqlite_autoindex_w_1 ORDER BY a,b',
    'SELECT * FROM main.w NOT INDEXED ORDER BY a,b',
    'SELECT id FROM t INDEXED BY ix UNION ALL SELECT id FROM t NOT INDEXED ORDER BY id',
    'SELECT id FROM (SELECT * FROM main.t INDEXED BY ix) ORDER BY id',
]
STEPS = [
    'UPDATE main.t INDEXED BY ix SET x=upper(main.t.x) WHERE main.t.id=1',
    'UPDATE main.t AS q SET n=main.q.n WHERE main.q.id=2',
    'UPDATE main.t AS q SET n=main.t.n WHERE id=2',
    'UPDATE main.t SET n=n RETURNING main.t.n',
    'UPDATE main.t AS q SET n=n RETURNING q.n',
    'DELETE FROM main.t NOT INDEXED WHERE id=3',
    "INSERT INTO main.t(id,x,n) VALUES(4,'d',4)",
    'UPDATE main.t INDEXED BY missing SET n=0',
    'UPDATE main.t INDEXED BY ip SET n=5',
    'UPDATE main.t AS q INDEXED BY ip SET n=n+1 WHERE main.q.n IS NOT NULL',
    'DELETE FROM main.w INDEXED BY iw WHERE c=9',
    'ALTER TABLE main.t ADD COLUMN more INT DEFAULT 7',
    'CREATE TABLE main.extra(x)', 'CREATE VIEW main.ev AS SELECT * FROM main.extra',
    'CREATE INDEX main.ei ON extra(x)',
    'CREATE TRIGGER main.et AFTER INSERT ON main.extra BEGIN UPDATE extra SET x=x+1;END',
    'INSERT INTO main.extra VALUES(1)',
    'CREATE TRIGGER bad AFTER INSERT ON extra BEGIN UPDATE main.extra SET x=2;END',
    'CREATE TRIGGER bad AFTER INSERT ON extra BEGIN DELETE FROM extra NOT INDEXED;END',
    'CREATE INDEX bad ON main.extra(x)',
    'CREATE TABLE other.bad(x)', 'DROP VIEW main.ev', 'DROP INDEX main.ei',
    'DROP TRIGGER main.et', 'DROP TABLE main.extra',
    'ALTER TABLE main.t RENAME TO renamed',
]

def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    connection = sqlite3.connect(':memory:')
    assert connection.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
    assert sorted(row[0] for row in connection.execute('PRAGMA compile_options')) == manifest['compile_options']
    for sql in SETUP:
        connection.execute(sql)
    cases = []
    for mode, sql in [('query', sql) for sql in QUERIES] + [('execute', sql) for sql in STEPS] + [
        ('query', 'SELECT * FROM renamed ORDER BY id'),
        ('query', "SELECT type,name,tbl_name,sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"),
        ('query', 'SELECT * FROM v ORDER BY id'),
    ]:
        entry = {'mode': mode, 'sql': sql}
        try:
            cursor = connection.execute(sql)
            if cursor.description:
                entry['columns'] = [column[0] for column in cursor.description]
                entry['rows'] = [[encode(value) for value in row] for row in cursor]
        except sqlite3.Error as error:
            entry['error'] = str(error)
        cases.append(entry)
    data = (json.dumps({'source_id':PIN, 'setup':SETUP, 'cases':cases},indent=2)+'\n').encode()
    PATH.write_bytes(data)
    PATH.with_suffix('.sha256').write_text(hashlib.sha256(data).hexdigest()+'  '+PATH.name+'\n')
    print('Generated', len(cases), 'qualified source/hint cases')

if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(PATH.read_bytes()).hexdigest() == PATH.with_suffix('.sha256').read_text().split()[0]
        print('Source/hint oracle checksum verified')
    else:
        generate()
