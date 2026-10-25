"""Development-only parenthesized-join oracle pinned to official SQLite."""
import hashlib
import itertools
import json
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    setup="""
    CREATE TABLE a(x INT,y TEXT COLLATE NOCASE);
    CREATE TABLE b(x TEXT,z TEXT);
    CREATE TABLE c(x INT,k TEXT);
    CREATE TABLE d(v INT);
    CREATE TABLE keyed(k TEXT PRIMARY KEY,v INT) WITHOUT ROWID;
    INSERT INTO a VALUES(1,'a'),(2,'b'),(NULL,NULL);
    INSERT INTO b VALUES('1','A'),('3','C'),(NULL,NULL);
    INSERT INTO c VALUES(1,'c'),(4,'d'),(NULL,NULL);
    INSERT INTO d VALUES(1),(2),(NULL);
    INSERT INTO keyed VALUES('a',1),('b',2);
    """
    sources=['(a)','((a))','(a)q','((a))q','(a AS p)q','(a,b)','(a,b)q',
     '(a JOIN b ON a.x=b.x)','(a JOIN b ON a.x=b.x)q',
     '(a JOIN b USING(x))','(a JOIN b USING(x))q',
     '(a NATURAL JOIN b)','(a NATURAL JOIN b)q',
     '(a LEFT JOIN b USING(x))','(a LEFT JOIN b USING(x))q',
     '(a RIGHT JOIN b USING(x))','(a RIGHT JOIN b USING(x))q',
     '(a FULL JOIN b USING(x))','(a FULL JOIN b USING(x))q',
     '((a FULL JOIN b USING(x))q)r',
     '(a JOIN (b JOIN c USING(x)) USING(x))',
     '(a JOIN (b JOIN c USING(x)) USING(x))q',
     '(a FULL JOIN (b FULL JOIN c USING(x)) USING(x))',
     '(a FULL JOIN (b FULL JOIN c USING(x)) USING(x))q',
     '(keyed)','(keyed)q','(a JOIN keyed ON a.y=keyed.k)',
     '(SELECT x,y FROM a)q','((SELECT x,y FROM a))q',
     '(main.a JOIN main.b USING(x))',
     '(main.a JOIN main.b USING(x))q',
     '((VALUES(1),(2)))q']
    projections=['*','a.*','b.*','c.*','q.*','r.*','keyed.*','q.x','q."x:1"',
     'q."x:2"','q."x:3"','q."x:4"','q.y','q.z','q.k','q.v','q.rowid',
     'a.x','b.x','c.x','a.x,b.x','q.x,a.x,b.x','main.a.x','main.q.x',
     'a.rowid,b.rowid','q._rowid_','q."_ROWID_:1"','x','rowid',
     'typeof(x),x=1,x=\'1\'','typeof(q.x),q.x=1,q.x=\'1\'']
    queries=[]
    for source,projection in itertools.product(sources,projections):
     queries.append(f'SELECT {projection} FROM {source}')
    for direction, inner, alias, condition in itertools.product(
     ['JOIN','CROSS JOIN','LEFT JOIN','RIGHT JOIN','FULL JOIN'],
     ['b JOIN c ON b.x=c.x','b JOIN c USING(x)','b LEFT JOIN c USING(x)',
      'b RIGHT JOIN c USING(x)','b FULL JOIN c USING(x)',
      '(b FULL JOIN c USING(x)) r'], ['', ' q'],
     ['ON a.x=b.x','ON a.x=q.x','USING(x)','ON a.x=c.x','ON a.x=q."x:1"']):
     queries.append(f'SELECT a.x,b.x,c.x FROM a {direction} ({inner}){alias} {condition} ORDER BY 1,2,3')
    for cte,source in itertools.product(['WITH a(x,y) AS(VALUES(7,\'cte\')) ',
                                        'WITH q AS(SELECT * FROM a) ', ''],
     ['(main.a JOIN b USING(x))','(a JOIN main.b USING(x))q',
      '(q JOIN b USING(x))','((a))q']):
     queries.append(cte+f'SELECT * FROM {source}')
    # Syntax and scope negative boundaries.
    queries += ['SELECT * FROM ()','SELECT * FROM (a JOIN)','SELECT * FROM (a)q INDEXED BY missing',
                'SELECT * FROM (a JOIN b USING(x))q INDEXED BY missing',
                'SELECT * FROM (a JOIN b ON c.x=a.x) JOIN c',
                'SELECT * FROM a LEFT JOIN (b JOIN c ON a.x=b.x) ON a.x=b.x',
                'SELECT * FROM a JOIN (b JOIN c ON a.x=b.x) ON a.x=b.x']
    queries += [
     'SELECT a.x+1 AS q FROM (a JOIN b ON q=b.x) ORDER BY 1',
     'SELECT a.x+1 AS q FROM (a JOIN b ON q=b.x)p ORDER BY 1',
     'SELECT a.x FROM (a JOIN b ON c.x=a.x) JOIN c ORDER BY 1',
     'SELECT a.x FROM (a JOIN b ON c.x=a.x)p JOIN c ORDER BY 1',
     'SELECT a.x FROM a JOIN (b JOIN c ON a.x=b.x)',
     'SELECT b.*,c.* FROM a LEFT JOIN(b FULL JOIN c USING(x))USING(x)',
     'SELECT x FROM d,(b,c)',
     'SELECT x FROM a JOIN(b,c)USING(x)',
     'SELECT x FROM a LEFT JOIN(b,c)USING(x)',
     'SELECT x FROM a RIGHT JOIN(b,c)USING(x)',
     'SELECT x FROM a FULL JOIN(b,c)USING(x)',
     'SELECT a.*,b.* FROM (a,b)q,d',
     'SELECT q.* FROM d,(a,b)q',
     'SELECT q._rowid_ FROM(a JOIN(b JOIN c USING(x))q USING(x))r',
     'SELECT r._rowid_ FROM(a JOIN(b JOIN c USING(x))q USING(x))r',
     'SELECT r."_ROWID_:1" FROM(a JOIN(b JOIN c USING(x))q USING(x))r',
     'SELECT a.x FROM(a INDEXED BY missing JOIN b USING(x))',
     'SELECT a.x FROM(a NOT INDEXED JOIN b USING(x))',
     'SELECT q.x FROM(main.a NOT INDEXED JOIN b USING(x))q',
     'WITH RECURSIVE q(x)AS(VALUES(1) UNION ALL SELECT q.x+1 FROM(q)WHERE q.x<3) SELECT * FROM q',
     'WITH RECURSIVE q(x)AS(VALUES(1) UNION ALL SELECT q.x+1 FROM(q JOIN(SELECT 1)d)WHERE q.x<3) SELECT * FROM q',
     'WITH q AS(SELECT * FROM(a FULL JOIN b USING(x)))SELECT * FROM q',
     'WITH q AS(SELECT * FROM(a FULL JOIN b USING(x))g)SELECT * FROM q',
     'SELECT a.x FROM(a JOIN b ON EXISTS(SELECT 1 FROM c WHERE c.x=a.x)) ORDER BY 1',
     'SELECT a.x FROM a LEFT JOIN(b JOIN c USING(x))ON EXISTS(SELECT 1 FROM d WHERE d.v=b.x) ORDER BY 1',
     'SELECT a.x FROM a LEFT JOIN(b JOIN c USING(x))ON EXISTS(SELECT 1 FROM missing) ORDER BY 1',
    ]
    queries += [
        'SELECT main.x,b.x FROM(main.a AS main JOIN b USING(x))q',
        'SELECT q.x,main.x FROM(main.a AS main FULL JOIN b USING(x))q',
        'SELECT main.rowid,b.rowid FROM(main.a AS main JOIN b USING(x))q',
        'SELECT "main.a".x,b.x FROM(a AS "main.a" JOIN b USING(x))q',
        'SELECT "a.b".x,b.x FROM(a AS "a.b" JOIN b USING(x))q',
        'SELECT q.x,"a.b".x FROM(a AS "a.b" FULL JOIN b USING(x))q',
    ]
    for direction, inner, projection in itertools.product(
            ['RIGHT', 'FULL'], ['b JOIN c ON b.x=c.x',
            'b LEFT JOIN c', 'b FULL JOIN c ON b.x IS c.x'],
            ['*', 'a.*', 'a.x', 'b.x,c.x']):
        queries.append(f'SELECT {projection} FROM a {direction} JOIN({inner})q USING(x) ORDER BY 1')
    queries=list(dict.fromkeys(queries))
    suites = []
    for encoding in ['UTF-8', 'UTF-16le', 'UTF-16be']:
        with sqlite3.connect(':memory:') as reference:
            if reference.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
                raise RuntimeError('Wrong SQLite source ID')
            if sorted(r[0] for r in reference.execute('PRAGMA compile_options')) != manifest['compile_options']:
                raise RuntimeError('Wrong SQLite compile options')
            reference.execute(f"PRAGMA encoding='{encoding}'")
            reference.executescript(setup)
            cases = []
            for sql in queries:
                case = {'sql': sql}
                try:
                    cursor = reference.execute(sql)
                    case['columns'] = [column[0] for column in cursor.description]
                    case['rows'] = [[encode(value) for value in row] for row in cursor]
                except sqlite3.Error as error:
                    case['error'] = str(error)
                cases.append(case)
            suites.append({'encoding': encoding, 'cases': cases})
    output = {'source_id': PIN,
              'setup': [sql.strip() for sql in setup.split(';') if sql.strip()],
              'suites': suites}
    data = (json.dumps(output, indent=2) + '\n').encode()
    (ROOT / 'join_group_oracle.json').write_bytes(data)
    (ROOT / 'join_group_oracle.sha256').write_text(
        hashlib.sha256(data).hexdigest() + '  join_group_oracle.json\n')
    print(f'Generated {len(queries)} joined-source cases per encoding ({len(queries) * 3} total)')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        expected = (ROOT / 'join_group_oracle.sha256').read_text().split()[0]
        if hashlib.sha256((ROOT / 'join_group_oracle.json').read_bytes()).hexdigest() != expected:
            raise RuntimeError('Joined-source oracle checksum mismatch')
        print('Joined-source oracle checksum verified')
    else:
        main()
