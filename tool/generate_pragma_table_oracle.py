"""Pinned development-only read-only metadata PRAGMA table-source oracle."""
import hashlib
import json
import sqlite3
import sys
from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

PATH = ROOT / 'pragma_table_oracle.json'
SETUP = [
    'CREATE TABLE parent(a TEXT COLLATE NOCASE,b INT,PRIMARY KEY(a,b)) WITHOUT ROWID',
    "CREATE TABLE sample(id INTEGER PRIMARY KEY,a TEXT NOT NULL DEFAULT 'x',b REAL,c,d INT AS(id+1),e INT AS(id+2) STORED,FOREIGN KEY(a,c) REFERENCES parent(a,b) ON DELETE CASCADE)",
    'CREATE INDEX ix ON sample(a COLLATE RTRIM DESC,b)',
    'CREATE INDEX ie ON sample(lower(a)) WHERE b IS NOT NULL',
    'CREATE VIEW visible AS SELECT id,a,CAST(b AS INTEGER) AS integral FROM sample',
    'CREATE TABLE "表 odd"("quoted name" TEXT,"α" INT)',
    "CREATE TABLE names(n TEXT);",
    "INSERT INTO names VALUES('sample'),('parent'),('missing'),('表 odd')",
    'CREATE TABLE empty(n)',
]

QUERIES = []
for pragma, arguments in [
    ('table_info', ['sample', 'parent', 'visible', '表 odd', 'missing', 'sqlite_schema']),
    ('table_xinfo', ['sample', 'visible', 'missing']),
    ('index_list', ['sample', 'parent', 'missing']),
    ('index_info', ['ix', 'ie', 'parent', 'missing']),
    ('index_xinfo', ['ix', 'ie', 'parent', 'missing']),
    ('foreign_key_list', ['sample', 'parent', 'missing']),
]:
    for argument in arguments:
        for schema in ['', ", 'main'", ', NULL']:
            QUERIES.append((f"SELECT * FROM pragma_{pragma}('{argument}'{schema})", []))
    QUERIES += [(f'SELECT * FROM pragma_{pragma}()', []),
                (f'SELECT * FROM pragma_{pragma}', []),
                (f'SELECT * FROM pragma_{pragma}(NULL)', []),
                (f"SELECT * FROM pragma_{pragma}('sample','other')", []),
                (f"SELECT * FROM pragma_{pragma}('sample','')", []),
                (f"SELECT * FROM pragma_{pragma}('sample','main',3)", [])]
QUERIES += [
    ('SELECT * FROM pragma_database_list()', []),
    ('SELECT * FROM pragma_collation_list()', []),
    ("SELECT * FROM pragma_function_list() WHERE name='lower' AND builtin=1 AND narg=1", []),
    ("SELECT * FROM pragma_pragma_list() WHERE name IN ('table_info','table_xinfo','index_info','index_xinfo','index_list','foreign_key_list') ORDER BY name", []),
    ("SELECT * FROM pragma_database_list('main')", []),
    ("SELECT * FROM pragma_collation_list(NULL)", []),
    ("SELECT * FROM pragma_function_list(1)", []),
    ("SELECT * FROM pragma_pragma_list('main')", []),
    ('SELECT * FROM pragma_table_info(?,?)', ['sample', 'main']),
    ('SELECT name FROM pragma_table_info(:table,@schema) ORDER BY cid', ['表 odd', 'MAIN']),
    ("SELECT * FROM main.pragma_table_info('sample')", []),
    ("SELECT main.p.name,p.cid FROM main.pragma_table_info('sample') AS p ORDER BY cid", []),
    ("SELECT p.* FROM (pragma_table_info('sample') AS p)", []),
    ("SELECT * FROM pragma_table_info('main.sample')", []),
    ("SELECT * FROM pragma_table_info('sample') INDEXED BY ix", []),
    ("SELECT * FROM pragma_table_info('sample') NOT INDEXED", []),
    ("SELECT * FROM pragma_table_info('sample') AS p NOT INDEXED", []),
    ("SELECT * FROM pragma_table_info(unknown)", []),
    ("SELECT * FROM pragma_table_info((1,2))", []),
    ("SELECT * FROM pragma_table_info(count(*))", []),
    ("SELECT * FROM pragma_table_info(row_number() OVER ())", []),
    ("SELECT arg,schema,rowid,_rowid_,oid,name FROM pragma_table_info('sample','MAIN') ORDER BY cid", []),
    ("SELECT * FROM pragma_table_info WHERE arg='sample'", []),
    ("SELECT arg,schema,name FROM pragma_table_info WHERE arg='sample' AND schema='main' ORDER BY cid", []),
    ("SELECT * FROM pragma_table_info('sample') WHERE schema='main'", []),
    ("SELECT * FROM pragma_table_info('sample') WHERE arg='parent'", []),
    ("SELECT * FROM pragma_table_info('sample','main') WHERE schema='other'", []),
    ("SELECT * FROM pragma_table_info WHERE schema='other'", []),
    ("SELECT * FROM pragma_table_info((SELECT 'sample'))", []),
    ("SELECT * FROM pragma_table_info(upper('sample'))", []),
    ("SELECT n,p.cid,p.name FROM names CROSS JOIN pragma_table_info(names.n) AS p ORDER BY n='表 odd',n,p.cid", []),
    ("SELECT n,p.cid,p.name FROM names LEFT JOIN pragma_table_info(names.n) AS p ON p.cid=0 ORDER BY n='表 odd',n", []),
    ("SELECT n,p.name FROM names JOIN pragma_table_info(names.n) AS p ON p.cid=0 WHERE n<>'missing' ORDER BY n='表 odd',n", []),
    ("SELECT n,(SELECT count(*) FROM pragma_table_info(names.n)) AS width FROM names ORDER BY n='表 odd',n", []),
    ("SELECT * FROM empty,pragma_table_info(empty.n)", []),
    ("SELECT * FROM pragma_table_info('sample') p JOIN pragma_index_list('sample') i ON p.cid=i.seq ORDER BY p.cid", []),
    ("SELECT * FROM pragma_table_info('missing') p FULL JOIN (SELECT 1 x) q ON 0", []),
    ("WITH p AS (SELECT name,cid FROM pragma_table_info('sample')) SELECT * FROM p WHERE cid<2 ORDER BY cid", []),
    ("SELECT * FROM (SELECT * FROM pragma_table_info('sample')) WHERE cid<2 ORDER BY cid", []),
    ("WITH pragma_table_info(x) AS (VALUES(42)) SELECT * FROM pragma_table_info", []),
    ("WITH pragma_table_info(x) AS (VALUES(42)) SELECT * FROM main.pragma_table_info('sample')", []),
    ("WITH pragma_table_info(x) AS (VALUES(42)) SELECT * FROM pragma_table_info('sample')", []),
    ("SELECT * FROM (pragma_table_info('sample') p JOIN pragma_index_list('sample') i ON p.cid=i.seq) LIMIT 0", []),
    ("SELECT * FROM pragma_table_info('sample') LIMIT 0", []),
    ("SELECT * FROM pragma_table_info('missing') UNION ALL SELECT * FROM pragma_table_info('sample') ORDER BY cid", []),
    ("SELECT * FROM pragma_table_info('pragma_table_info')", []),
    ("SELECT * FROM pragma_table_xinfo('pragma_table_info')", []),
    ("SELECT * FROM pragma_table_info('sample','temp')", []),
]

CALLBACK_QUERIES = [
    "SELECT name FROM pragma_table_info WHERE arg=probe('sample')",
    "SELECT name FROM pragma_table_info WHERE probe('sample')=arg",
    "SELECT name FROM pragma_table_info WHERE arg=probe('sample') AND schema=probe('main')",
    "SELECT name FROM pragma_table_info WHERE schema=probe('main') AND arg=probe('sample')",
    "SELECT name FROM pragma_table_info WHERE arg=probe('sample') AND arg=probe('sample')",
    "SELECT name FROM pragma_table_info('sample') WHERE arg=probe('sample')",
    "SELECT name FROM pragma_table_info('sample') WHERE schema=probe('main')",
    "SELECT name FROM pragma_table_info WHERE arg=probe(NULL)",
    "SELECT arg,name FROM pragma_table_info WHERE arg=probe('sample') OR arg='parent'",
    "SELECT arg,name FROM pragma_table_info WHERE arg=probe('sample') OR arg='sample'",
    "SELECT arg,name FROM pragma_table_info WHERE arg IN (probe('sample'),probe('parent'),probe('sample'),NULL)",
    "SELECT arg,schema,name FROM pragma_table_info WHERE arg IN ('sample','parent') AND schema IN (probe('temp'),probe('main'))",
    "SELECT n,p.name FROM names LEFT JOIN pragma_table_info p ON p.arg=probe(n) AND p.cid=0 ORDER BY n='表 odd',n",
    "SELECT name FROM pragma_table_info WHERE arg=probe('sample') LIMIT 0",
    "SELECT * FROM empty,pragma_table_info WHERE arg=probe('sample')",
    "SELECT name FROM pragma_table_info WHERE arg=probe('sample') AND schema=probe('other')",
]
QUERIES += [(sql, []) for sql in CALLBACK_QUERIES]
QUERIES += [(sql, []) for sql in [
    "SELECT arg,name FROM pragma_table_info WHERE arg IN ('sample','parent')",
    "SELECT arg,name FROM pragma_table_info WHERE arg IN ('sample','parent','sample',NULL)",
    "SELECT arg,schema,name FROM pragma_table_info('sample') WHERE schema IN ('temp','main')",
    "SELECT arg,name FROM pragma_table_info WHERE arg IS 'sample'",
    "SELECT arg,name FROM pragma_table_info WHERE arg IS NULL",
    "SELECT arg,name FROM pragma_table_info WHERE arg=arg",
    "SELECT arg,name FROM pragma_table_info p WHERE p.arg=p.arg",
    "SELECT arg,name FROM pragma_table_info WHERE arg=name",
]]

SCHEMA_OPERATIONS = [
    ('CREATE VIEW source_view AS SELECT names.n,p.name,p.arg,p.schema,p.rowid FROM names,pragma_table_info(names.n) p WHERE p.cid=0', False),
    ("CREATE VIEW hidden_view AS SELECT arg,schema,rowid FROM pragma_table_info WHERE arg='sample'", False),
    ("PRAGMA table_info('hidden_view')", True),
    ('ALTER TABLE names RENAME COLUMN n TO label', False),
    ("SELECT * FROM source_view ORDER BY label='表 odd',label", True),
    ('ALTER TABLE names RENAME TO renamed_names', False),
    ("SELECT * FROM source_view ORDER BY label='表 odd',label", True),
    ("SELECT sql FROM sqlite_schema WHERE name='source_view'", True),
    ('ALTER TABLE sample RENAME COLUMN a TO renamed_a', False),
    ("SELECT * FROM hidden_view", True),
    ('CREATE TRIGGER pragma_use AFTER UPDATE ON renamed_names BEGIN SELECT p.name FROM pragma_table_info(NEW.label) AS p; END', False),
    ('ALTER TABLE renamed_names RENAME COLUMN label TO value', False),
    ("SELECT sql FROM sqlite_schema WHERE name='pragma_use'", True),
    ("UPDATE renamed_names SET value='parent' WHERE value='sample'", False),
    ("SELECT * FROM source_view ORDER BY value='表 odd',value", True),
]

def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    connection = sqlite3.connect(':memory:')
    assert connection.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
    assert sorted(row[0] for row in connection.execute('PRAGMA compile_options')) == manifest['compile_options']
    for sql in SETUP:
        connection.execute(sql)
    calls = []
    connection.create_function('probe', 1, lambda value: calls.append(encode(value)) or value)
    cases = []
    for sql, parameters in QUERIES:
        calls.clear()
        entry = {'sql': sql, 'parameters': parameters}
        try:
            cursor = connection.execute(sql, parameters)
            entry['columns'] = [column[0] for column in cursor.description]
            entry['rows'] = [[encode(value) for value in row] for row in cursor]
        except sqlite3.Error as error:
            entry['error'] = str(error)
        if sql in CALLBACK_QUERIES:
            entry['calls'] = list(calls)
        cases.append(entry)
    schema_operations = []
    for sql, query in SCHEMA_OPERATIONS:
        entry = {'sql': sql, 'query': query}
        try:
            cursor = connection.execute(sql)
            if query:
                entry['columns'] = [column[0] for column in cursor.description]
                entry['rows'] = [[encode(value) for value in row] for row in cursor]
        except sqlite3.Error as error:
            entry['error'] = str(error)
        schema_operations.append(entry)
    data = (json.dumps({'source_id': PIN, 'setup': SETUP, 'cases': cases, 'schema_operations': schema_operations}, indent=2) + '\n').encode()
    PATH.write_bytes(data)
    PATH.with_suffix('.sha256').write_text(hashlib.sha256(data).hexdigest() + '  ' + PATH.name + '\n')
    print('Generated', len(cases), 'metadata PRAGMA table-source cases and', len(schema_operations), 'schema operations')

if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(PATH.read_bytes()).hexdigest() == PATH.with_suffix('.sha256').read_text().split()[0]
        print('Metadata PRAGMA table-source oracle checksum verified')
    else:
        generate()
