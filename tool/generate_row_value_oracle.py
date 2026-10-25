"""Development-only row-value oracle, pinned to the repository SQLite build."""
import itertools
import hashlib
import json
import random
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as reference:
        if reference.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(row[0] for row in reference.execute('PRAGMA compile_options')) != manifest['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    setup = [
        'CREATE TABLE pairs(id INTEGER PRIMARY KEY,t TEXT COLLATE NOCASE,n NUMERIC,b BLOB,r TEXT COLLATE RTRIM)',
        "INSERT INTO pairs VALUES(1,'A',2,'2','a '),(2,'b',NULL,2,'b'),(3,NULL,3,NULL,NULL)",
        'CREATE TABLE empty(a,b)',
        'CREATE TABLE affinity(a TEXT,b NUMERIC,c BLOB,d TEXT COLLATE NOCASE,e TEXT COLLATE RTRIM)',
        "INSERT INTO affinity VALUES('1',1,'1','A','a '),(NULL,NULL,NULL,NULL,NULL),('x','x',2,'b','b')",
    ]
    queries = []
    operators = ['=', '==', '!=', '<>', '<', '<=', '>', '>=', 'IS', 'IS NOT']
    for fields in itertools.product(['NULL', '0', '1'], repeat=4):
        left = f'({fields[0]},{fields[1]})'
        right = f'({fields[2]},{fields[3]})'
        queries.extend(f'SELECT {left} {op} {right} AS result' for op in operators)
    rng = random.Random(6318)
    leaves = ['NULL', '-1', '1', '1.0', "'1'", "'a'", "'A'", "X'31'", '9223372036854775807']
    for _ in range(100):
        a, b, c, d = [rng.choice(leaves) for _ in range(4)]
        op = rng.choice(operators)
        queries.append(f'SELECT ({a},{b}) {op} ({c},{d}) AS result')
    expressions = [
        '(1,2,3)=(1,2,3)', '(1,NULL,3)<(1,2,0)',
        '(1,NULL,3)=(1,2,4)', '(NULL,NULL) IS (NULL,NULL)',
        '(1,2) IS DISTINCT FROM (1,NULL)',
        '(1,2) IS NOT DISTINCT FROM (1,2)',
        '(1,2)=(SELECT 1,2)', '(SELECT 1,2)=(1,2)',
        '(SELECT 1,2)=(SELECT 1,2)', '(1,2)=(SELECT 1,2 WHERE 0)',
        '(1,2)=(VALUES(1,2),(3,4))', '(SELECT 1,2 WHERE 0) IS (NULL,NULL)',
        '(1,2) IN ((1,2),(3,4))', '(1,2) NOT IN ((1,NULL),(3,4))',
        '(1,2) IN ((NULL,3),(2,NULL))', '(NULL,2) IN ((1,3),(2,3))',
        '(NULL,2) IN ((1,2),(2,3))', '(NULL,NULL) IN ()',
        '(NULL,NULL) NOT IN ()', '(1,2) IN ((SELECT 1,2))',
        '(1,2) IN (SELECT 1,2)', '(1,2) NOT IN (SELECT 1,NULL)',
        '(NULL,2) IN (SELECT 1,3)', '(NULL,2) IN (SELECT 1,2)',
        '(NULL,2) IN (SELECT 1,2 WHERE 0)',
        '(1,2) IN (VALUES(3,4),(1,2))',
        '(1,2) IN (WITH c(a,b) AS(VALUES(1,2)) SELECT * FROM c)',
        '(1,2) BETWEEN (1,0) AND (1,3)',
        '(1,NULL) BETWEEN (0,0) AND (2,0)',
        '(1,NULL) NOT BETWEEN (1,0) AND (1,3)',
        '(1,2) BETWEEN (1,0) AND (SELECT 1,3)',
        'CASE (1,2) WHEN (1,3) THEN 0 WHEN (1,2) THEN 1 ELSE 2 END',
        'CASE (NULL,2) WHEN (NULL,2) THEN 1 ELSE 0 END',
        'CASE (SELECT 1,2) WHEN (1,2) THEN 1 ELSE 0 END',
        '(1,abs(-9223372036854775808))<(2,2)',
        '(1,abs(-9223372036854775808))=(2,2)',
        '(1,abs(-9223372036854775808))!=(2,2)',
        '(NULL,abs(-9223372036854775808))<(2,2)',
        '(1,2) BETWEEN (3,abs(-9223372036854775808)) AND (4,5)',
        '(abs(-9223372036854775808),2) IN ()',
        '(1,(2,3)) IN ()', '(missing,2) IN ()',
        "('A' COLLATE NOCASE,'a ' COLLATE RTRIM)=('a','a')",
        "('A','b')=('a' COLLATE NOCASE,'B' COLLATE NOCASE)",
        "('A' COLLATE BINARY,'b')=('a' COLLATE NOCASE,'b')",
    ]
    for expression in expressions:
        queries.append('SELECT ' + expression + ' AS result')
    expressions = [
        "(t,n)=('a','2')", "(t,n) IN (('a','2'),('x',0))",
        "(t,n) IN (SELECT 'a','2')", "('a','2') IN (SELECT t,n FROM pairs)",
        "(t,b)=('a',2)", "(t,b) IN (('a',2))", "(t,b) IN (SELECT 'a',2)",
        "(t,n)=(SELECT t,n FROM pairs WHERE id=1)",
        "(t,n)=(SELECT * FROM (SELECT t,n FROM pairs WHERE id=1))",
        "(t,n) IN (SELECT p.t,p.n FROM pairs p WHERE p.id=pairs.id)",
        "(t,n) BETWEEN ('a','1') AND ('c','3')",
        "(t,r)=('a','a')", "('a','a') IN (SELECT t,r FROM pairs)",
        "(t COLLATE BINARY,n)=('a','2')",
        "(t,n)=('a' COLLATE BINARY,'2')",
        "(t,n) IN (('a' COLLATE BINARY,'2'))",
        "(t,n) IN (SELECT 'a' COLLATE BINARY,'2')",
        "(t,n)=(SELECT 'a' COLLATE BINARY,'2')",
        "(t,n) IN ((t,n))", "(t,n) IN (SELECT t,n FROM pairs WHERE 0)",
        "(t,n) IN (SELECT t,n FROM pairs WHERE id<3)",
        "(t,n) NOT IN (SELECT t,n FROM pairs WHERE id<3)",
    ]
    queries.extend('SELECT id,' + expression + ' AS result FROM pairs ORDER BY id'
                   for expression in expressions)
    row_forms = ['(1,1)', "('1',1)", "(1,'1')", '(a,b)', '(b,a)', '(a,c)', '(c,b)']
    for left, right in itertools.product(row_forms, repeat=2):
        for comparison in [f'{left}={right}', f'{left} IN ({right})',
                           f'{left} IN ({right},(NULL,NULL))',
                           f'{left} IN (SELECT {right[1:-1]})']:
            queries.append('SELECT ' + comparison + ' AS result FROM affinity ORDER BY rowid')
    collation_rows = ["('a','a')", "(d,e)",
                      "('a' COLLATE BINARY,'a' COLLATE BINARY)",
                      "('a' COLLATE NOCASE,'a' COLLATE RTRIM)"]
    for left, right in itertools.product(collation_rows, repeat=2):
        for comparison in [f'{left}={right}', f'{left} IN ({right})',
                           f'{left} IN ({right},(NULL,NULL))',
                           f'{left} IN (SELECT {right[1:-1]})',
                           f'{left}=(SELECT {right[1:-1]})']:
            queries.append('SELECT ' + comparison + ' AS result FROM affinity ORDER BY rowid')
    queries.extend([
        'SELECT id FROM pairs WHERE (t,n) IN (SELECT t,n FROM pairs WHERE id<3) ORDER BY id',
        'SELECT (SELECT t FROM pairs WHERE id=1)=\'a\' AS result',
        'SELECT (SELECT n FROM pairs WHERE id=1)=\'2\' AS result',
        'SELECT (SELECT b FROM pairs WHERE id=1)=2 AS result',
        'SELECT id FROM pairs GROUP BY id HAVING (id,max(n))>=(1,2) ORDER BY id',
        'SELECT (1,2)', 'SELECT (1,2) FROM empty',
        'SELECT (SELECT 1,2)', 'SELECT (SELECT 1,2) FROM empty',
        'SELECT (1,2)=1 FROM empty', 'SELECT (1,2)=(1,2,3) FROM empty',
        'SELECT (1,(2,3))=(1,(2,3))', 'SELECT abs((1,2)) FROM empty',
        'SELECT (1,2)+1 FROM empty', 'SELECT NOT (1,2) FROM empty',
        'SELECT (1,2) IS NULL FROM empty', 'SELECT (1,2) IS TRUE FROM empty',
        'SELECT ((1,2) COLLATE NOCASE)=(1,2) FROM empty',
        'SELECT (1,2) IN (1,2) FROM empty', 'SELECT 1 IN ((1,2)) FROM empty',
        'SELECT (1,2) IN ((1,2,3)) FROM empty',
        'SELECT (1,2) IN (SELECT 1) FROM empty',
        'SELECT (1,2) IN ((SELECT 1,2),(SELECT 3,4))',
        'SELECT (1,2) BETWEEN (1,0) AND 3 FROM empty',
        'SELECT CASE (1,2) WHEN 1 THEN 1 END FROM empty',
        'SELECT CASE WHEN 1 THEN (1,2) END FROM empty',
        'SELECT 1 FROM empty ORDER BY (1,2)',
        'SELECT 1 FROM empty GROUP BY (1,2)',
        'SELECT 1 FROM empty WHERE (1,2)',
        'SELECT (1,2) LIMIT 0',
        'SELECT (1,2) IN ((3,abs(-9223372036854775808)))',
        'SELECT (1,2) IN ((1,2),(3,abs(-9223372036854775808)))',
        'SELECT (1,2) IN (SELECT 1,2 WHERE 0)',
        'SELECT (abs(-9223372036854775808),2) IN (SELECT 1,2 WHERE 0)',
    ])
    queries.extend('SELECT ' + expression + ' AS result' for expression in [
        '(row_counter(),row_counter())<(2,0)',
        '(row_counter(),row_counter())=(2,0)',
        '(row_counter(),row_counter())=(1,2)',
        '(row_counter(),row_counter())!=(2,0)',
        '(row_counter(),row_counter()) BETWEEN (1,0) AND (1,3)',
        '(row_counter(),row_counter()) IN ((1,2),(3,row_counter()))',
        '(row_counter(),row_counter()) IN ((1,row_counter()))',
        '(SELECT 1,row_counter())<(0,0)',
        '(row_counter(),row_counter()) IN ()',
        '(row_counter(),row_counter()) IN (SELECT 1,2 WHERE 0)',
        '(row_counter(),row_counter()) IN (SELECT 1,row_counter())',
        'CASE (row_counter(),row_counter()) WHEN (1,3) THEN 0 WHEN (1,2) THEN 1 END',
    ])
    cases = []
    with sqlite3.connect(':memory:') as connection:
        callback_count = 0
        def row_counter():
            nonlocal callback_count
            callback_count += 1
            return callback_count
        connection.create_function('row_counter', 0, row_counter)
        if connection.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(row[0] for row in connection.execute('PRAGMA compile_options')) != manifest['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
        for sql in setup:
            connection.execute(sql)
        for sql in dict.fromkeys(queries):
            case = {'sql': sql}
            callback_count = 0
            try:
                cursor = connection.execute(sql)
                case['columns'] = [column[0] for column in cursor.description]
                case['rows'] = [[encode(value) for value in row] for row in cursor]
            except sqlite3.Error as error:
                case['error'] = str(error)
            if 'row_counter' in sql:
                case['callback_count'] = callback_count
            cases.append(case)
    output = {'source_id': PIN, 'setup': setup, 'cases': cases}
    data = (json.dumps(output, indent=2) + '\n').encode()
    (ROOT / 'row_value_oracle.json').write_bytes(data)
    (ROOT / 'row_value_oracle.sha256').write_text(
        hashlib.sha256(data).hexdigest() + '  row_value_oracle.json\n')
    print(f'Generated {len(cases)} pinned row-value cases')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        expected = (ROOT / 'row_value_oracle.sha256').read_text().split()[0]
        if hashlib.sha256((ROOT / 'row_value_oracle.json').read_bytes()).hexdigest() != expected:
            raise RuntimeError('Row-value oracle checksum mismatch')
        print('Row-value oracle checksum verified')
    else:
        main()
