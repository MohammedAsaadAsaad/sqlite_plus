"""Development-only INSERT SELECT callback-order oracle for pinned SQLite."""
import hashlib
import json
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

OUTPUT = ROOT / 'insert_stream_oracle.json'
SOURCE = [
    'CREATE TABLE src(id INTEGER PRIMARY KEY,y)',
    'INSERT INTO src VALUES(1,1),(2,1),(3,2)',
]
DESTINATION = 'CREATE TABLE dst(x DEFAULT(stamp()),v)'


def cases():
    result = []

    def add(name, select, *, setup=None, suffix='', insert='INSERT INTO dst(v) ',
            after=None, parameters=None):
        result.append(dict(name=name, setup=SOURCE + [DESTINATION] + (setup or []),
                           sql=insert + select + suffix,
                           parameters=parameters or [],
                           after=after or ['SELECT * FROM dst ORDER BY rowid']))

    add('single SELECT', 'SELECT tick()')
    add('simple table scan', 'SELECT tick() FROM src')
    add('projection and omitted defaults', 'SELECT tick(),visit(id) FROM src',
        insert='INSERT INTO dst(v,x) ')
    add('single VALUES default precedes supplied later field', 'VALUES(tick())')
    add('single VALUES RETURNING keeps destination order', 'VALUES(tick())', suffix=' RETURNING x,v')
    add('single VALUES trigger keeps destination order', 'VALUES(tick())',
        setup=['CREATE TRIGGER logged AFTER INSERT ON dst BEGIN SELECT audit(new.v); END'])
    add('single VALUES evaluates reversed target fields', 'VALUES(tick(),tick())', insert='INSERT INTO dst(v,x) ')
    add('single VALUES RETURNING evaluates reversed target fields', 'VALUES(tick(),tick())',
        insert='INSERT INTO dst(v,x) ', suffix=' RETURNING x,v')
    add('single VALUES implicit rowid follows declared fields', 'VALUES(tick(),tick())',
        insert='INSERT INTO dst(rowid,v) ')
    add('single VALUES INTEGER PRIMARY KEY follows declared order', 'VALUES(tick(),tick())',
        setup=['DROP TABLE dst', 'CREATE TABLE dst(x DEFAULT(stamp()),v,id INTEGER PRIMARY KEY)'],
        insert='INSERT INTO dst(v,id) ')
    add('multi VALUES preserves input target order', 'VALUES(tick(),tick()),(tick(),tick())',
        insert='INSERT INTO dst(v,x) ')
    add('multi VALUES RETURNING preserves input target order', 'VALUES(tick(),tick()),(tick(),tick())',
        insert='INSERT INTO dst(v,x) ', suffix=' RETURNING x,v')
    add('VALUES input', 'VALUES(tick()),(tick()),(tick())')
    add('WHERE filters between projected rows', 'SELECT tick() FROM src WHERE keep(id)')
    add('WHERE and projection reuse separate calls', 'SELECT visit(id) FROM src WHERE keep(id)')
    add('empty input', 'SELECT tick() FROM src WHERE 0')
    add('LIMIT zero suppresses input', 'SELECT tick() FROM src WHERE keep(id) LIMIT 0')
    add('LIMIT stops WHERE and projection', 'SELECT tick() FROM src WHERE keep(id) LIMIT 1')
    add('OFFSET skips only projections', 'SELECT tick() FROM src WHERE keep(id) LIMIT 1 OFFSET 1')
    add('bound LIMIT and OFFSET', 'SELECT tick() FROM src WHERE keep(id) LIMIT ?1 OFFSET ?2',
        parameters=[1, 1])
    add('negative LIMIT and OFFSET', 'SELECT tick() FROM src LIMIT -1 OFFSET -2')
    add('rowid ascending order streams', 'SELECT tick() FROM src ORDER BY id')
    add('rowid descending order streams', 'SELECT tick() FROM src ORDER BY id DESC')
    add('rowid descending projection values', 'SELECT visit(id) FROM src ORDER BY id DESC')
    add('aliased rowid descending LIMIT', 'SELECT tick() FROM src s ORDER BY s.id DESC LIMIT 1')
    add('qualified rowid descending LIMIT', 'SELECT tick() FROM main.src s ORDER BY main.s.id DESC LIMIT 1')
    add('implicit rowid descending LIMIT', 'SELECT tick() FROM src s ORDER BY s._rowid_ DESC LIMIT 1')
    add('rowid output alias descending LIMIT', 'SELECT id AS identity,tick() FROM src ORDER BY identity DESC LIMIT 1',
        insert='INSERT INTO dst(v,x) ')
    add('rowid ordinal descending LIMIT', 'SELECT id,tick() FROM src ORDER BY 1 DESC LIMIT 1',
        insert='INSERT INTO dst(v,x) ')
    wr = ['CREATE TABLE wr(a INTEGER PRIMARY KEY,b) WITHOUT ROWID',
          'INSERT INTO wr VALUES(1,5),(2,4),(3,3)']
    add('WITHOUT ROWID primary descending LIMIT', 'SELECT tick() FROM wr ORDER BY a DESC LIMIT 1', setup=wr)
    add('WITHOUT ROWID alias descending LIMIT', 'SELECT tick() FROM wr w ORDER BY w.a DESC LIMIT 1', setup=wr)
    add('WITHOUT ROWID ascending OFFSET', 'SELECT tick() FROM wr w ORDER BY w.a LIMIT 1 OFFSET 1', setup=wr)
    add('WITHOUT ROWID primary output alias', 'SELECT a AS identity,tick() FROM wr ORDER BY identity DESC LIMIT 1',
        setup=wr, insert='INSERT INTO dst(v,x) ')
    compound = ['CREATE TABLE wr(a COLLATE NOCASE,b,PRIMARY KEY(a DESC,b)) WITHOUT ROWID',
                "INSERT INTO wr VALUES('B',1),('a',2),('A',3)"]
    add('WITHOUT ROWID primary prefix', 'SELECT tick() FROM wr w ORDER BY w.a DESC LIMIT 1', setup=compound)
    add('WITHOUT ROWID reversed prefix', 'SELECT tick() FROM wr w ORDER BY w.a LIMIT 1', setup=compound)
    add('WITHOUT ROWID mixed primary direction', 'SELECT tick() FROM wr w ORDER BY w.a,w.b DESC LIMIT 1', setup=compound)
    add('unindexed order buffers projection', 'SELECT tick() FROM src ORDER BY y DESC')
    add('projection order buffers projection', 'SELECT tick() AS value FROM src ORDER BY value DESC')
    add('sort LIMIT buffers candidates', 'SELECT tick() FROM src ORDER BY y DESC LIMIT 1')
    add('sort OFFSET buffers candidates', 'SELECT tick() FROM src ORDER BY y DESC LIMIT 1 OFFSET 1')
    add('unbounded sort projection precedes callback key', 'SELECT tick() FROM src ORDER BY visit(y) DESC')
    add('sort LIMIT callback key precedes projection', 'SELECT tick() FROM src ORDER BY visit(y) DESC LIMIT 1')
    add('sort LIMIT skips worse projection callbacks', 'SELECT visit(id) FROM src ORDER BY y DESC LIMIT 1')
    add('sort LIMIT shared projection key', 'SELECT tick() AS value FROM src ORDER BY value DESC LIMIT 1')
    add('sort LIMIT retains two candidates', 'SELECT tick() FROM src ORDER BY visit(y) DESC LIMIT 2')
    add('sort LIMIT OFFSET retains extra candidate', 'SELECT tick() FROM src ORDER BY visit(y) DESC LIMIT 1 OFFSET 1')
    add('sort ascending LIMIT skips later ties', 'SELECT tick() FROM src ORDER BY visit(y) LIMIT 1')
    add('sort negative LIMIT still evaluates keys first', 'SELECT tick() FROM src ORDER BY visit(y) DESC LIMIT -1')
    add('sort large LIMIT still evaluates keys first', 'SELECT tick() FROM src ORDER BY visit(y) DESC LIMIT 5')
    add('DISTINCT streams unique projections', 'SELECT DISTINCT tick() FROM src')
    add('DISTINCT duplicate callbacks', 'SELECT DISTINCT visit(y) FROM src')
    add('DISTINCT LIMIT short circuits', 'SELECT DISTINCT visit(y) FROM src LIMIT 1')
    add('DISTINCT OFFSET counts unique rows', 'SELECT DISTINCT visit(y) FROM src LIMIT 1 OFFSET 1')
    add('UNION ALL constant branches', 'SELECT tick() UNION ALL SELECT tick() UNION ALL SELECT tick()')
    add('UNION ALL table branches', 'SELECT tick() FROM src WHERE keep(id) UNION ALL SELECT tick() FROM src WHERE id=2')
    add('UNION ALL LIMIT skips later branch', 'SELECT tick() FROM src UNION ALL SELECT tick() LIMIT 2')
    add('UNION ALL OFFSET crosses branches', 'SELECT tick() FROM src WHERE id=1 UNION ALL SELECT tick() FROM src LIMIT 2 OFFSET 1')
    add('UNION set buffers projections', 'SELECT tick() FROM src UNION SELECT tick()')
    add('INTERSECT set buffers projections', 'SELECT visit(y) FROM src INTERSECT SELECT visit(y) FROM src')
    add('EXCEPT set buffers projections', 'SELECT visit(y) FROM src EXCEPT SELECT visit(1)')
    add('UNION ALL ordered tail', 'SELECT tick() FROM src UNION ALL SELECT tick() ORDER BY 1 DESC')
    add('JOIN ON resumes between writes', 'SELECT tick() FROM src a JOIN src b ON gate(a.id,b.id)')
    add('LEFT JOIN ON resumes between writes', 'SELECT tick() FROM src a LEFT JOIN rhs b ON gate(a.id,b.id)',
        setup=['CREATE TABLE rhs(id)', 'INSERT INTO rhs VALUES(1),(2)'])
    add('LEFT JOIN rowid bound precedes ON callback', 'SELECT tick() FROM src a LEFT JOIN src b ON gate(a.id,b.id) AND b.id<3')
    add('JOIN WHERE resumes between writes', 'SELECT tick() FROM src a CROSS JOIN src b WHERE gate(a.id,b.id)')
    add('JOIN LIMIT short circuits predicates', 'SELECT tick() FROM src a JOIN src b ON gate(a.id,b.id) LIMIT 1')
    add('GROUP BY projects one group at a time', 'SELECT tick()+sum(id)*0 FROM src GROUP BY y')
    add('GROUP BY aggregate arguments', 'SELECT tick()+sum(visit(id))*0 FROM src GROUP BY y')
    add('HAVING callbacks precede each projection', 'SELECT tick()+sum(id)*0 FROM src GROUP BY y HAVING keep(y)')
    add('aggregate without groups', 'SELECT tick()+sum(visit(id))*0 FROM src')
    add('empty aggregate projects once', 'SELECT tick()+count(*) FROM src WHERE 0')
    add('window projection resumes between writes', 'SELECT tick()+row_number() OVER(ORDER BY id)*0 FROM src')
    add('window projection LIMIT stops callbacks', 'SELECT tick()+row_number() OVER(ORDER BY id)*0 FROM src LIMIT 1')
    add('self source materializes', 'SELECT tick() FROM dst',
        setup=['INSERT INTO dst VALUES(100,10),(200,20)'])
    add('nested self read materializes', 'SELECT tick() FROM src WHERE NOT EXISTS(SELECT 1 FROM dst)')
    add('view self source materializes outer projection', 'SELECT tick() FROM target_view',
        setup=['INSERT INTO dst VALUES(100,10),(200,20)',
               'CREATE VIEW target_view AS SELECT v FROM dst'])
    add('nested view self source materializes outer projection', 'SELECT tick() FROM outer_target_view',
        setup=['INSERT INTO dst VALUES(100,10),(200,20)',
               'CREATE VIEW target_view AS SELECT v FROM dst',
               'CREATE VIEW outer_target_view AS SELECT v FROM target_view'])
    add('CTE target name shadow permits streaming', 'WITH dst AS(SELECT id FROM src) SELECT tick() FROM dst')
    add('unused target reading CTE permits streaming', 'WITH unused AS(SELECT v FROM dst) SELECT tick() FROM src')
    add('target AFTER trigger materializes', 'SELECT tick() FROM src',
        setup=['CREATE TRIGGER logged AFTER INSERT ON dst BEGIN SELECT audit(new.v); END'])
    add('target BEFORE trigger materializes', 'SELECT tick() FROM src',
        setup=['CREATE TRIGGER logged BEFORE INSERT ON dst BEGIN SELECT audit(new.v); END'])
    add('target trigger materializes VALUES', 'VALUES(tick()),(tick()),(tick())',
        setup=['CREATE TRIGGER logged AFTER INSERT ON dst BEGIN SELECT audit(new.v); END'])
    add('target unrelated-event trigger permits streaming', 'SELECT tick() FROM src',
        setup=['CREATE TRIGGER logged AFTER UPDATE ON dst BEGIN SELECT audit(new.v); END'])
    add('trigger IGNORE skips row after materialization', 'SELECT tick() FROM src',
        setup=['CREATE TRIGGER ignored BEFORE INSERT ON dst WHEN new.v=2 BEGIN SELECT RAISE(IGNORE); END'])
    add('RETURNING materializes input before defaults', 'SELECT tick() FROM src', suffix=' RETURNING x,v')
    add('RETURNING materializes VALUES before defaults', 'VALUES(tick()),(tick()),(tick())', suffix=' RETURNING x,v')
    add('RETURNING callback follows default', 'SELECT tick() FROM src', suffix=' RETURNING audit(v),x')
    add('OR IGNORE consumes remaining source', 'SELECT visit(y) FROM src',
        setup=['CREATE UNIQUE INDEX dst_key ON dst(v)'], insert='INSERT OR IGNORE INTO dst(v) ')
    add('constraint ABORT stops source atomically', 'SELECT visit(y) FROM src',
        setup=['CREATE UNIQUE INDEX dst_key ON dst(v)'])
    add('constraint FAIL preserves accepted prefix', 'SELECT visit(y) FROM src',
        setup=['CREATE UNIQUE INDEX dst_key ON dst(v)'], insert='INSERT OR FAIL INTO dst(v) ')
    add('UPSERT NOTHING consumes source after conflict', 'SELECT visit(y) FROM src WHERE 1',
        setup=['CREATE UNIQUE INDEX dst_key ON dst(v)'], suffix=' ON CONFLICT(v) DO NOTHING RETURNING x,v')
    add('UPSERT UPDATE follows each source row', 'SELECT visit(y) FROM src WHERE 1',
        setup=['CREATE UNIQUE INDEX dst_key ON dst(v)'],
        suffix=' ON CONFLICT(v) DO UPDATE SET x=audit(excluded.x) RETURNING x,v')
    add('UPSERT NOTHING without RETURNING streams', 'SELECT visit(y) FROM src WHERE 1',
        setup=['CREATE UNIQUE INDEX dst_key ON dst(v)'], suffix=' ON CONFLICT(v) DO NOTHING')
    add('UPSERT UPDATE without RETURNING streams', 'SELECT visit(y) FROM src WHERE 1',
        setup=['CREATE UNIQUE INDEX dst_key ON dst(v)'],
        suffix=' ON CONFLICT(v) DO UPDATE SET x=audit(excluded.x)')
    add('projection error stops after accepted prefix', 'SELECT fail_if(id) FROM src')
    add('projection error before first write', 'SELECT fail_if(id) FROM src WHERE id>=2')
    add('trigger materialization projection error precedes defaults', 'SELECT fail_if(id) FROM src',
        setup=['CREATE TRIGGER logged AFTER INSERT ON dst BEGIN SELECT audit(new.v); END'])
    add('RETURNING materialization projection error precedes defaults', 'SELECT fail_if(id) FROM src',
        suffix=' RETURNING x,v')
    add('unused fatal default never executes', 'SELECT tick(),tick() FROM src',
        insert='INSERT INTO dst(x,v) ', setup=['DROP TABLE dst', 'CREATE TABLE dst(x DEFAULT(bad_stamp()),v)'])
    add('fatal default stops source after first projection', 'SELECT tick() FROM src',
        setup=['DROP TABLE dst', 'CREATE TABLE dst(x DEFAULT(bad_stamp()),v)'])
    add('trigger materialization precedes fatal default', 'SELECT tick() FROM src',
        setup=['DROP TABLE dst', 'CREATE TABLE dst(x DEFAULT(bad_stamp()),v)',
               'CREATE TRIGGER logged AFTER INSERT ON dst BEGIN SELECT audit(new.v); END'])
    add('width failure on empty source is callback free', 'SELECT tick(),id FROM src WHERE 0')
    add('RETURNING preparation failure is callback free', 'SELECT tick() FROM src', suffix=' RETURNING missing')
    add('trailing syntax failure is callback free', 'SELECT tick() FROM src WHERE 1', suffix=' trailing garbage')
    add('incorrect parameter count is callback free', 'SELECT tick() FROM src LIMIT ?1')
    add('invalid LIMIT is callback free', "SELECT tick() FROM src LIMIT 'invalid'")
    add('bound LIMIT zero does not execute callbacks', 'SELECT tick() FROM src WHERE keep(id) LIMIT ?1', parameters=[0])
    return result


def register_callbacks(db, trace):
    serial = 0

    def increment(name):
        nonlocal serial
        serial += 1
        trace.append(f'{name}:{serial}')
        return serial

    def visit(name, value):
        trace.append(f'{name}:{value}')
        return value

    def gate(left, right):
        trace.append(f'gate:{left}:{right}')
        return left == right

    def fail_if(value):
        visit('fail_if', value)
        if value == 2:
            raise ValueError('requested projection failure')
        return value

    def bad_stamp():
        trace.append('bad_stamp')
        raise ValueError('requested default failure')

    db.create_function('tick', 0, lambda: increment('tick'))
    db.create_function('stamp', 0, lambda: increment('stamp'))
    db.create_function('visit', 1, lambda value: visit('visit', value))
    db.create_function('audit', 1, lambda value: visit('audit', value))
    db.create_function('keep', 1, lambda value: visit('keep', value) != 2)
    db.create_function('gate', 2, gate)
    db.create_function('fail_if', 1, fail_if)
    db.create_function('bad_stamp', 0, bad_stamp)


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    suites = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        generated = []
        for case in cases():
            with sqlite3.connect(':memory:', isolation_level=None) as db:
                assert db.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
                assert sorted(row[0] for row in db.execute('PRAGMA compile_options')) == manifest['compile_options']
                db.execute(f"PRAGMA encoding='{label}'")
                trace = []
                register_callbacks(db, trace)
                steps = []
                for sql in case['setup'] + [case['sql']] + case['after']:
                    parameters = case['parameters'] if sql == case['sql'] else []
                    step = dict(sql=sql, parameters=parameters, query=sql.startswith('SELECT'))
                    try:
                        cursor = db.execute(sql, parameters)
                        step['rows'] = [[encode(value) for value in row] for row in cursor] if cursor.description else []
                        step['changes'] = db.execute('SELECT changes()').fetchone()[0] if sql.startswith(('INSERT', 'REPLACE', 'UPDATE', 'DELETE', 'WITH')) else 0
                    except sqlite3.Error as error:
                        step['error'] = str(error)
                    step['trace'] = list(trace)
                    steps.append(step)
                generated.append(dict(name=case['name'], steps=steps))
        suites.append(dict(encoding=encoding, cases=generated))
    OUTPUT.write_text(json.dumps(dict(source_id=PIN, suites=suites), indent=2)+'\n')
    OUTPUT.with_suffix('.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest()+'\n')
    print(f'Generated {sum(len(s["cases"]) for s in suites)} pinned INSERT stream cases')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('INSERT stream oracle checksum verified')
    else:
        generate()
