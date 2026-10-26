"""Development-only aggregate input/evaluation comparison with pinned SQLite."""
import hashlib
import json
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

OUTPUT = ROOT / 'aggregate_evaluation_oracle.json'
SOURCE = [
    'CREATE TABLE t(id INTEGER PRIMARY KEY,k TEXT,v)',
    "INSERT INTO t VALUES(1,'b',4),(2,'a',2),(3,'b',4),(4,'A',NULL)",
]


def statements():
    queries = [
        'SELECT sum(visit(id)),sum(visit(id)+0) FROM t',
        'SELECT sum(visit(id)),sum(visit(id)),count(visit(id)) FROM t',
        'SELECT sum(visit(id)),count(visit(v)),total(visit(v)) FROM t WHERE keep(id)',
        'SELECT sum(visit(id)) FILTER(WHERE keep(id)),count(visit(v)) FROM t',
        'SELECT sum(DISTINCT visit(v)),count(visit(v)) FROM t',
        'SELECT id,min(visit(v)) FROM t',
        'SELECT id,max(visit(v)) FROM t',
        'SELECT id,min(visit(v)) FILTER(WHERE keep(id)) FROM t',
        'SELECT id,min(visit(NULL)) FROM t',
        'SELECT id,min(DISTINCT visit(NULL)) FROM t',
        'SELECT id,min(visit(NULL)) FILTER(WHERE id<3) FROM t',
        'SELECT id,min(visit(v)) FILTER(WHERE 0) FROM t',
        'SELECT id,min(DISTINCT visit(v)) FROM t',
        'SELECT id,max(DISTINCT visit(v)) FROM t',
        'SELECT id,min(visit(v)) FILTER(WHERE id=4) FROM t',
        'SELECT id,min(visit(v) ORDER BY id DESC) FROM t',
        'SELECT visit(k),count(*) FROM t GROUP BY visit(k)',
        'SELECT visit(k)||\'!\',count(*) FROM t GROUP BY visit(k)',
        'SELECT visit(k) COLLATE NOCASE,count(*) FROM t GROUP BY visit(k) COLLATE NOCASE',
        'SELECT k,fold_a(visit(v)),fold_b(visit(id)) FROM t GROUP BY k',
        'SELECT fold_a(visit(v)),fold_b(visit(id)) FROM t',
        'SELECT fold_a(visit(v)),fold_a(visit(v)),fold_b(visit(v)) FROM t',
        'SELECT fold_a(visit(v)),fold_b(visit(id)) FROM t WHERE keep(id)',
        'SELECT fold_a(visit(v)) FILTER(WHERE keep(id)),fold_b(visit(id)) FROM t',
        'SELECT fold_a(DISTINCT visit(v)),fold_b(visit(id)) FROM t',
        'SELECT fold_a(visit(v) ORDER BY id DESC),fold_b(visit(id)) FROM t',
        'SELECT fold_b(visit(id)),fold_a(visit(v) ORDER BY id DESC) FROM t',
        'SELECT fold_a(visit(v) ORDER BY visit(id) DESC),fold_b(visit(id)) FROM t',
        'SELECT fold_a(visit(v) ORDER BY visit(v)),fold_b(visit(id)) FROM t',
        'SELECT fold_a(DISTINCT visit(v) ORDER BY visit(v)),fold_b(visit(id)) FROM t',
        'SELECT fold_a(visit(v)),tick() FROM t',
        'SELECT k,fold_a(visit(v)),tick() FROM t GROUP BY k',
        'SELECT k,count(visit(v)) FROM t WHERE keep(id) GROUP BY visit(k)',
        'SELECT k,count(visit(v)) FROM t GROUP BY k HAVING count(visit(v))>0',
        'SELECT k,count(visit(v)) FROM t GROUP BY k HAVING count(visit(id))>0',
        'SELECT count(visit(v)),count(visit(v)) FROM t WHERE 0',
    ]
    for body in [
        'SELECT visit(id) AS x FROM t',
        'SELECT visit(id) AS x FROM t WHERE keep(id)',
    ]:
        for hint in ['', 'NOT MATERIALIZED ', 'MATERIALIZED ']:
            for consumer in [
                'SELECT sum(x),sum(x+0) FROM c',
                'SELECT fold_a(x),fold_b(x) FROM c',
                'SELECT fold_a(x ORDER BY x DESC),fold_b(x) FROM c',
                'SELECT x,count(*) FROM c GROUP BY x',
            ]:
                queries.append(f'WITH c AS {hint}({body}) {consumer}')
    return queries


def register(db, trace):
    serial = 0

    def visit(name, value):
        trace.append(f'{name}:{"null" if value is None else value}')
        return value

    def tick():
        nonlocal serial
        serial += 1
        trace.append(f'tick:{serial}')
        return serial

    def collector(name):
        class Collector:
            def __init__(self):
                self.values = []

            def step(self, value):
                visit(name, value)
                self.values.append('null' if value is None else str(value))

            def finalize(self):
                trace.append(f'{name}:finish')
                return '|'.join(self.values)
        return Collector

    db.create_function('visit', 1, lambda value: visit('visit', value))
    db.create_function('keep', 1, lambda value: visit('keep', value) != 2)
    db.create_function('tick', 0, tick)
    db.create_aggregate('fold_a', 1, collector('a'))
    db.create_aggregate('fold_b', 1, collector('b'))


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    suites = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        cases = []
        for sql in statements():
            with sqlite3.connect(':memory:', isolation_level=None) as db:
                assert db.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
                assert sorted(row[0] for row in db.execute('PRAGMA compile_options')) == manifest['compile_options']
                db.execute(f"PRAGMA encoding='{label}'")
                trace = []
                register(db, trace)
                for setup in SOURCE:
                    db.execute(setup)
                case = dict(sql=sql, setup=SOURCE)
                try:
                    cursor = db.execute(sql)
                    case['columns'] = [column[0] for column in cursor.description]
                    case['rows'] = [[encode(value) for value in row] for row in cursor]
                except sqlite3.Error as error:
                    case['error'] = str(error)
                case['trace'] = list(trace)
                cases.append(case)
        suites.append(dict(encoding=encoding, cases=cases))
    OUTPUT.write_text(json.dumps(dict(source_id=PIN, suites=suites), indent=2)+'\n')
    OUTPUT.with_suffix('.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest()+'\n')
    print(f'Generated {sum(len(s["cases"]) for s in suites)} pinned aggregate evaluation cases')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('Aggregate evaluation oracle checksum verified')
    else:
        generate()
