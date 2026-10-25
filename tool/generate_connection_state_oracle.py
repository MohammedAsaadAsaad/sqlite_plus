"""Development-only connection-state sequences pinned to official SQLite."""
import hashlib
import json
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

OUTPUT = ROOT / 'connection_state_oracle.json'
CHECKSUM = ROOT / 'connection_state_oracle.sha256'
STATE = 'SELECT changes(),total_changes(),last_insert_rowid()'


def scenarios():
    for name in ['foreign_keys', 'recursive_triggers', 'user_version', 'application_id']:
        operations = [
            'CREATE TABLE state_pragma(x)', 'INSERT INTO state_pragma VALUES(7),(8)',
            (f'PRAGMA {name}', 'query'), (f'PRAGMA main.{name}', 'query'),
        ]
        for i,value in enumerate(['ON', 'OFF', 'YES', 'NO', 'TRUE', 'FALSE', '2', '-1', '+1',
                '1.5', '1e2', '1e-2', '0x10', '0x80000000', '-0x80000000',
                '2147483647', '2147483648', '-2147483648', '-2147483649',
                "'on'", "'unknown'", "'1x'", "'0x10'", "' 1'", "'+1'", "'-1'", "'123abc'",
                "'"+'0'*100+"1'", "'"+'9'*128+"'", "'0x"+'f'*100+"'"]):
            target = f'main.{name}' if i % 2 else name
            operations.extend([f'PRAGMA {target}({value})' if i % 3 == 0 else f'PRAGMA {target}={value}',
                (f'PRAGMA {name}', 'query'), (f'PRAGMA main.{name}', 'query')])
        for value in ['NULL', 'abs(1)', '1+2', '(1)', '?']:
            operations.extend([f'PRAGMA main.{name}={value}', (f'PRAGMA main.{name}', 'query')])
        operations.extend([f'PRAGMA other.{name}=1', ('PRAGMA other.'+name, 'query'),
            f'PRAGMA "main"."{name}"=1', (f'PRAGMA "main"."{name}"', 'query'),
            'BEGIN', f'PRAGMA main.{name}=0', (f'PRAGMA main.{name}', 'query'),
            'ROLLBACK', (f'PRAGMA {name}', 'query')])
        yield 'qualified state pragma '+name, operations
    yield 'direct writes and returning', [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,x INT UNIQUE)',
        'INSERT INTO t VALUES(10,1),(20,2)',
        'UPDATE t SET x=x WHERE 0', 'DELETE FROM t WHERE 0',
        'UPDATE t SET x=x RETURNING id,changes(),total_changes(),last_insert_rowid()',
        'INSERT INTO t VALUES(30,3) RETURNING changes(),total_changes(),last_insert_rowid()',
        'INSERT OR IGNORE INTO t VALUES(40,3),(50,5)',
        'REPLACE INTO t VALUES(60,3)',
        'INSERT INTO t VALUES(70,7) ON CONFLICT(x) DO NOTHING',
        'INSERT INTO t VALUES(80,7) ON CONFLICT(x) DO UPDATE SET x=x',
        'DELETE FROM t WHERE id>30 RETURNING id,changes(),total_changes(),last_insert_rowid()',
        ('SELECT * FROM t ORDER BY id', 'query'),
    ]
    yield 'statement errors preserve the correct counters', [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,x INT UNIQUE)',
        'INSERT INTO t VALUES(10,1),(20,2)',
        'INSERT INTO t VALUES(30,3),(40,2)',
        'INSERT OR FAIL INTO t VALUES(30,3),(40,2)',
        'INSERT OR IGNORE INTO t VALUES(40,2),(50,5)',
        'INSERT INTO t(missing) VALUES(1)',
        'INSERT INTO t VALUES(1)',
        'UPDATE t SET x=1',
        'UPDATE OR FAIL t SET x=1',
        ('SELECT * FROM t ORDER BY id', 'query'),
        ('SELECT changes(1)', 'query'),
        ('SELECT total_changes(1)', 'query'),
        ('SELECT last_insert_rowid(1)', 'query'),
    ]
    yield 'transactions savepoints and ddl do not restore counters', [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,x)', 'BEGIN',
        'INSERT INTO t VALUES(30,3),(40,4)', 'SAVEPOINT inner_save',
        'INSERT INTO t VALUES(50,5)', 'ROLLBACK TO inner_save',
        'RELEASE inner_save', 'ROLLBACK',
        'BEGIN', 'INSERT INTO t VALUES(-10,1)', 'COMMIT',
        'CREATE TABLE copied AS SELECT * FROM t',
        'CREATE INDEX idx ON t(x)', 'DROP INDEX idx',
        'ALTER TABLE t ADD COLUMN other', 'DROP TABLE copied',
        ('SELECT * FROM t', 'query'),
    ]
    yield 'trigger local counters and nested inserts', [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,x)',
        'CREATE TABLE aux(id INTEGER PRIMARY KEY,x)',
        'CREATE TABLE log(stage,id,c,tc,lr)',
        'INSERT INTO aux VALUES(100,0),(200,0)',
        "CREATE TRIGGER aux_change AFTER UPDATE ON aux BEGIN "
        "INSERT INTO log VALUES('nested',NEW.id,changes(),total_changes(),last_insert_rowid()); END",
        "CREATE TRIGGER before_t BEFORE INSERT ON t BEGIN "
        "INSERT INTO log VALUES('before',NEW.id,changes(),total_changes(),last_insert_rowid()); "
        "UPDATE aux SET x=x+1; "
        "INSERT INTO log VALUES('before_done',NEW.id,changes(),total_changes(),last_insert_rowid()); END",
        "CREATE TRIGGER after_t AFTER INSERT ON t BEGIN "
        "INSERT INTO log VALUES('after',NEW.id,changes(),total_changes(),last_insert_rowid()); "
        "INSERT OR IGNORE INTO aux VALUES(NEW.id,0); "
        "INSERT INTO log VALUES('after_done',NEW.id,changes(),total_changes(),last_insert_rowid()); END",
        'INSERT INTO t VALUES(10,1),(20,2)',
        ('SELECT * FROM log ORDER BY rowid', 'query'),
        'DELETE FROM log', 'INSERT OR IGNORE INTO t VALUES(20,9)',
        ('SELECT * FROM log ORDER BY rowid', 'query'),
    ]
    for policy in ['ABORT', 'FAIL', 'ROLLBACK', 'IGNORE']:
        yield 'trigger raise ' + policy.lower(), [
            'CREATE TABLE t(id INTEGER PRIMARY KEY,x UNIQUE)',
            'CREATE TABLE log(stage,c,tc,lr)',
            'INSERT INTO t VALUES(10,1)', 'BEGIN',
            "CREATE TRIGGER fail_t AFTER INSERT ON t WHEN NEW.id=30 BEGIN "
            "INSERT INTO log VALUES('before_raise',changes(),total_changes(),last_insert_rowid()); "
            f"SELECT RAISE({policy}" + ('' if policy == 'IGNORE' else ",'stop'") + '); END',
            'INSERT INTO t VALUES(20,2),(30,3),(40,4)',
            ('SELECT * FROM t ORDER BY id', 'query'),
            ('SELECT * FROM log ORDER BY rowid', 'query'),
            'ROLLBACK',
        ]
    yield 'view instead of triggers and without rowid', [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,x)',
        'CREATE VIEW v AS SELECT * FROM t',
        'CREATE TRIGGER write_v INSTEAD OF INSERT ON v BEGIN '
        'INSERT INTO t VALUES(NEW.id,NEW.x); END',
        'INSERT INTO v VALUES(50,5),(60,6) RETURNING id,changes(),total_changes(),last_insert_rowid()',
        'CREATE TABLE wr(id INT PRIMARY KEY,x) WITHOUT ROWID',
        'INSERT INTO wr VALUES(100,1),(200,2)',
        'UPDATE wr SET x=x+1',
        'CREATE TABLE copied AS SELECT * FROM wr',
        'INSERT INTO t VALUES(-99,9)', 'INSERT INTO wr VALUES(300,3)',
    ]
    yield 'foreign key cascades and replace victims', [
        'PRAGMA foreign_keys=ON', 'PRAGMA recursive_triggers=ON',
        'CREATE TABLE parent(id INTEGER PRIMARY KEY,x UNIQUE)',
        'CREATE TABLE child(id INTEGER PRIMARY KEY,p REFERENCES parent(id) ON DELETE CASCADE ON UPDATE CASCADE)',
        'CREATE TABLE log(stage,id,c,tc,lr)',
        "CREATE TRIGGER child_update AFTER UPDATE ON child BEGIN "
        "INSERT INTO log VALUES('cu',NEW.id,changes(),total_changes(),last_insert_rowid()); END",
        "CREATE TRIGGER child_delete AFTER DELETE ON child BEGIN "
        "INSERT INTO log VALUES('cd',OLD.id,changes(),total_changes(),last_insert_rowid()); END",
        "CREATE TRIGGER parent_delete AFTER DELETE ON parent BEGIN "
        "INSERT INTO log VALUES('pd',OLD.id,changes(),total_changes(),last_insert_rowid()); END",
        'INSERT INTO parent VALUES(10,1),(20,2)',
        'INSERT INTO child VALUES(100,10),(200,10),(300,20)',
        'UPDATE parent SET id=11 WHERE id=10',
        ('SELECT * FROM log ORDER BY rowid', 'query'),
        'REPLACE INTO parent VALUES(21,2)',
        ('SELECT * FROM log ORDER BY rowid', 'query'),
        'DELETE FROM parent WHERE id=11',
        ('SELECT * FROM log ORDER BY rowid', 'query'),
    ]
    yield 'foreign key failure and drop table', [
        'PRAGMA foreign_keys=ON',
        'CREATE TABLE parent(id INTEGER PRIMARY KEY)',
        'CREATE TABLE child(id INTEGER PRIMARY KEY,p REFERENCES parent ON DELETE CASCADE)',
        'CREATE TABLE log(x)',
        'CREATE TRIGGER child_delete AFTER DELETE ON child BEGIN INSERT INTO log VALUES(OLD.id); END',
        'INSERT INTO parent VALUES(10),(20)',
        'INSERT INTO child VALUES(100,10),(200,10)',
        'INSERT INTO child VALUES(300,999)',
        'DROP TABLE parent',
        ('SELECT * FROM log ORDER BY rowid', 'query'),
    ]
    yield 'recursive trigger rowid restoration', [
        'PRAGMA recursive_triggers=ON',
        'CREATE TABLE t(id INTEGER PRIMARY KEY)',
        'CREATE TABLE log(stage,id,c,tc,lr)',
        "CREATE TRIGGER recursive_t AFTER INSERT ON t WHEN NEW.id<3 BEGIN "
        "INSERT INTO log VALUES('enter',NEW.id,changes(),total_changes(),last_insert_rowid()); "
        "INSERT INTO t VALUES(NEW.id+1); "
        "INSERT INTO log VALUES('exit',NEW.id,changes(),total_changes(),last_insert_rowid()); END",
        'INSERT INTO t VALUES(1)',
        ('SELECT * FROM log ORDER BY rowid', 'query'),
    ]


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    cases = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        for name, statements in scenarios():
            with sqlite3.connect(':memory:', isolation_level=None) as db:
                if db.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
                    raise RuntimeError('Wrong SQLite source ID')
                if sorted(r[0] for r in db.execute('PRAGMA compile_options')) != manifest['compile_options']:
                    raise RuntimeError('Wrong SQLite compile options')
                db.execute(f"PRAGMA encoding='{label}'")
                steps = []
                for statement in statements:
                    sql, kind = statement if isinstance(statement, tuple) else (statement, 'execute')
                    step = {'sql': sql, 'kind': kind}
                    try:
                        cursor = db.execute(sql)
                        step['rows'] = [[encode(v) for v in row] for row in cursor.fetchall()]
                    except sqlite3.Error as error:
                        step['error'] = str(error)
                    step['state'] = [encode(v) for v in db.execute(STATE).fetchone()]
                    steps.append(step)
                cases.append({'name': name, 'encoding': encoding, 'steps': steps})
    data = (json.dumps(cases, ensure_ascii=False, indent=2) + '\n').encode()
    OUTPUT.write_bytes(data)
    CHECKSUM.write_text(hashlib.sha256(data).hexdigest() + '  ' + OUTPUT.name + '\n')
    print(f'Generated {len(cases)} counter sequences, {sum(len(c["steps"]) for c in cases)} pinned steps')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        if hashlib.sha256(OUTPUT.read_bytes()).hexdigest() != CHECKSUM.read_text().split()[0]:
            raise RuntimeError('Connection-counter oracle checksum mismatch')
        print('Connection-counter oracle checksum verified')
    else:
        generate()
