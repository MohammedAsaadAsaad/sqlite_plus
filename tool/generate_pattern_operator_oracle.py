"""Development-only native pattern-operator dispatch and preparation oracle."""
import hashlib
import json
import sqlite3
import sys

from generate_fixtures import ROOT, PIN
from generate_sql_oracle import encode

OUTPUT = ROOT / 'pattern_operator_oracle.json'
NAMES = ['like', 'glob', 'regexp', 'match']


def query_cases(profile):
    queries = []
    for name in NAMES:
        for value, pattern in [
                ("'Abc'", "'a%'"), ('NULL', "'null'"), ("'value'", 'NULL'),
                ("'left'", "'return-null'"), ("'left'", "'return-text'"),
                ("'left'", "'return-blob'"), ("'left'", "'return-real'"),
                ('1', '-7'), ('0', '0'), ("X'0102'", "X'0304'"),
                ("'λ😀'", "'λ%'"), ("'a%b'", "'a!%b'")]:
            for negate in ['', 'NOT ']:
                queries.append(f'SELECT {value} {negate}{name.upper()} {pattern}')
        for escape in ["'!'", 'NULL', "'too long'", "'😀'", "X'21'"]:
            queries.append(f"SELECT 'value' {name} 'pattern' ESCAPE {escape}")
        queries += [
            f'SELECT tap(1) {name} tap(2)',
            f'SELECT tap(1) NOT {name} tap(2)',
            f'SELECT tap(1) {name} tap(2) ESCAPE tap(3)',
            f'SELECT {name}(tap(2),tap(1))',
            f'SELECT {name}(tap(2),tap(1),tap(3))',
            f'SELECT CASE WHEN 0 THEN tap(1) {name} tap(2) ELSE 9 END',
            f'SELECT CASE WHEN 1 THEN 9 ELSE tap(1) {name} tap(2) END',
            f'SELECT tap(1) {name} tap(2) WHERE 0',
            f'SELECT v {name} p FROM t WHERE 0',
            f'SELECT v {name} p FROM t LIMIT 0',
            f'SELECT id,v {name} p FROM t ORDER BY id',
            f'SELECT id,v NOT {name} p FROM t ORDER BY id',
            f'SELECT id FROM t WHERE v {name} p ORDER BY id',
            f'SELECT id FROM t WHERE v NOT {name} p ORDER BY id',
            f'SELECT CASE WHEN v {name} p THEN 1 ELSE 0 END FROM t ORDER BY id',
            f'SELECT 1+2 {name} 3*4,NOT 1 {name} 0,1=1 {name} 1',
            f'SELECT (1 {name} 2) IS NULL,(1 {name} 2) NOT NULL',
        ]
        if profile == 'varargs':
            queries += [f'SELECT {name}()', f'SELECT {name}(1)',
                        f'SELECT {name}(1,2,3,4)']
    return queries


def schema_cases(profile):
    result = []
    for name in NAMES:
        # Creation must inspect the actual registered function's determinism,
        # including when there are no rows to evaluate.
        result += [
            f'CREATE TABLE gen_{name}(x,y AS(x {name} 2))',
            f'CREATE INDEX idx_{name} ON t(v {name} p)',
            f'CREATE INDEX partial_{name} ON t(v) WHERE v {name} p',
        ]
        if profile == 'deterministic':
            result += [
                f'INSERT INTO gen_{name}(x) VALUES(3),(NULL)',
                f'SELECT * FROM gen_{name} ORDER BY x',
                f'SELECT id FROM t WHERE v {name} p ORDER BY id',
                f'DROP INDEX idx_{name}', f'DROP INDEX partial_{name}',
            ]
        result += [
            f'CREATE VIEW view_{name} AS SELECT id,v {name} p AS result FROM t',
            f'SELECT * FROM view_{name} ORDER BY id',
            f'DROP VIEW view_{name}',
        ]
    for definition in [
            'SELECT unknown_fn(v) FROM t',
            'SELECT abs() FROM t', 'SELECT abs(1,2) FROM t',
            'SELECT coalesce(1) FROM t',
            'SELECT likelihood(v,2) FROM t',
            'SELECT unknown_fn(v) FILTER(WHERE 1) FROM t',
            'SELECT abs(v) FILTER(WHERE 1) FROM t',
            'SELECT unknown_fn(v) OVER() FROM t',
            'SELECT abs(v) OVER() FROM t']:
        result += ['CREATE VIEW deferred AS '+definition, 'SELECT 42',
                   'SELECT * FROM deferred', 'SELECT * FROM deferred LIMIT 0',
                   'DROP VIEW deferred']
    result += ['CREATE VIEW invalid AS SELECT unknown_fn(1',
               'CREATE VIEW invalid AS SELECT unknown_fn(?)']
    result += ['CREATE TABLE fired(id INTEGER PRIMARY KEY,a)',
               'CREATE TABLE other_fired(id INTEGER PRIMARY KEY,a)']
    for event in ['INSERT', 'UPDATE', 'DELETE']:
        reference = 'old.a' if event == 'DELETE' else 'new.a'
        for when, body in [
                ('', 'SELECT unknown_fn()'),
                ('', 'SELECT abs()'),
                ('', 'SELECT CASE WHEN 0 THEN unknown_fn() ELSE 9 END'),
                ('', f'INSERT INTO other_fired(a) VALUES(unknown_fn({reference}))'),
                ('', f'UPDATE other_fired SET a=unknown_fn({reference}) WHERE 0'),
                ('', f'INSERT INTO other_fired(a) SELECT unknown_fn({reference}) WHERE 0'),
                (f'WHEN unknown_fn({reference})', 'SELECT 1'),
                ('WHEN 0', 'SELECT unknown_fn()')]:
            result += ['DELETE FROM fired', 'INSERT INTO fired VALUES(1,5)',
                       f'CREATE TRIGGER deferred_trigger AFTER {event} ON fired {when} BEGIN {body}; END',
                       'SELECT 42']
            if event == 'INSERT':
                result += ['UPDATE fired SET a=tap(a)',
                           'INSERT INTO fired(a) SELECT tap(7) WHERE 0',
                           'INSERT INTO fired(a) VALUES(tap(7))']
            elif event == 'UPDATE':
                result += ['INSERT INTO fired VALUES(2,8)',
                           'UPDATE fired SET a=tap(a) WHERE 0',
                           'UPDATE fired SET a=tap(a)']
            else:
                result += ['UPDATE fired SET a=tap(a)',
                           'DELETE FROM fired WHERE 0',
                           'DELETE FROM fired WHERE tap(a)']
            result += ['SELECT * FROM fired ORDER BY id',
                       'SELECT * FROM other_fired ORDER BY id',
                       'DROP TRIGGER deferred_trigger']
    result += [
        'CREATE TRIGGER deferred_trigger AFTER UPDATE OF a ON fired WHEN unknown_fn(new.a) BEGIN SELECT 1; END',
        'UPDATE fired SET id=id WHERE 0', 'UPDATE fired SET id=id',
        'UPDATE fired SET a=a WHERE 0', 'DROP TRIGGER deferred_trigger',
        'CREATE TRIGGER child_trigger AFTER INSERT ON other_fired BEGIN SELECT unknown_fn(); END',
        'CREATE TRIGGER parent_trigger AFTER INSERT ON fired BEGIN INSERT INTO other_fired(a) VALUES(new.a); END',
        'INSERT INTO fired(a) SELECT tap(7) WHERE 0',
        'INSERT INTO fired(a) VALUES(tap(7))',
        'DROP TRIGGER parent_trigger', 'DROP TRIGGER child_trigger']
    for expression in ['unknown_fn()', 'abs()', 'abs(1,2)', 'sum(1)',
                       'CASE WHEN 0 THEN unknown_fn() ELSE 7 END',
                       "match('p','x')"]:
        result += [f'CREATE TABLE default_fn(x DEFAULT({expression}),y)',
                   'INSERT INTO default_fn(x) VALUES(9)',
                   'SELECT * FROM default_fn',
                   'UPDATE default_fn SET y=tap(1)',
                   'INSERT INTO default_fn(y) SELECT tap(1) WHERE 0',
                   'INSERT INTO default_fn(y) VALUES(tap(1))',
                   'INSERT INTO default_fn DEFAULT VALUES',
                   'SELECT * FROM default_fn', 'DROP TABLE default_fn']
    result += [
        'CREATE TABLE default_nn(x NOT NULL DEFAULT(unknown_fn()),y)',
        'INSERT INTO default_nn(x) VALUES(8)',
        'INSERT OR REPLACE INTO default_nn(x) VALUES(tap(9))',
        'UPDATE OR REPLACE default_nn SET y=tap(1)',
        'UPDATE OR REPLACE default_nn SET x=tap(9)',
        'UPDATE default_nn SET x=tap(9)',
        'SELECT * FROM default_nn', 'DROP TABLE default_nn']
    return result


def aggregate_cases():
    result = []
    for name in NAMES:
        result += [
            f'SELECT v {name} id FROM t',
            f'SELECT v NOT {name} id FROM t',
            f'SELECT v {name} id FROM t WHERE 0',
            f'SELECT v {name} id FROM t LIMIT 0',
            f'SELECT id FROM t WHERE v {name} id',
            f'SELECT sum(v {name} id) FROM t',
            f'SELECT v {name} sum(id) FROM t',
            f'SELECT CASE WHEN 0 THEN v {name} id ELSE 9 END FROM t',
            f'SELECT (v {name} id)+1 FROM t',
        ]
    return result


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    suites = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        for profile in ['default', 'scalar2', 'scalar3', 'varargs',
                        'deterministic', 'aggregate']:
            with sqlite3.connect(':memory:', isolation_level=None) as db:
                assert db.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
                assert sorted(r[0] for r in db.execute('PRAGMA compile_options')) == manifest['compile_options']
                db.execute(f"PRAGMA encoding='{label}'")
                db.execute('CREATE TABLE t(id INTEGER PRIMARY KEY,v,p,k)')
                db.execute("INSERT INTO t VALUES(1,'a',2,'x'),(2,NULL,0,'x'),(3,'λ',NULL,'y')")
                trace = []

                def tap(value):
                    trace.append(['tap', [encode(value)]])
                    return value

                def pattern(name):
                    def invoke(*args):
                        trace.append([name, [encode(v) for v in args]])
                        if args and args[0] == 'return-null':
                            return None
                        if args and args[0] == 'return-text':
                            return '12abc'
                        if args and args[0] == 'return-blob':
                            return b'12abc'
                        if args and args[0] == 'return-real':
                            return 0.25
                        return args[0] if args else 99
                    return invoke

                def aggregate(name):
                    class State:
                        def __init__(self):
                            self.total = 0

                        def step(self, *args):
                            trace.append([name, [encode(v) for v in args]])
                            if isinstance(args[0], (int, float)):
                                self.total += args[0]

                        def finalize(self):
                            return self.total
                    return State

                db.create_function('tap', 1, tap)
                if profile != 'default':
                    for name in NAMES:
                        if profile == 'aggregate':
                            db.create_aggregate(name, 2, aggregate(name))
                        else:
                            for count in ({'scalar2': [2], 'scalar3': [3],
                                           'varargs': [-1],
                                           'deterministic': [2, 3]}[profile]):
                                db.create_function(name, count, pattern(name),
                                                   deterministic=profile == 'deterministic')
                statements = aggregate_cases() if profile == 'aggregate' else query_cases(profile)
                if profile in ['default', 'scalar2', 'deterministic']:
                    statements += schema_cases(profile)
                steps = []
                for sql in statements:
                    trace.clear()
                    step = {'sql': sql, 'query': sql.startswith('SELECT')}
                    try:
                        cursor = db.execute(sql)
                        step['rows'] = [[encode(v) for v in row] for row in cursor] if cursor.description else []
                    except sqlite3.Error as error:
                        step['error'] = str(error)
                    # Schema/index rebuilds may evaluate deterministic functions
                    # differently. Trace comparisons target query semantics.
                    if profile != 'deterministic':
                        step['trace'] = list(trace)
                    steps.append(step)
                suites.append({'encoding': encoding, 'profile': profile, 'steps': steps})
    OUTPUT.write_text(json.dumps({'source_id': PIN, 'suites': suites}, indent=2)+'\n')
    OUTPUT.with_suffix('.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest()+'\n')
    print(f'Generated {sum(len(s["steps"]) for s in suites)} native pattern-operator operations')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('Pattern-operator oracle checksum verified')
    else:
        generate()
