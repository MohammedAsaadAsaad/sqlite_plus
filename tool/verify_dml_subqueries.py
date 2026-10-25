"""Development-only DML subquery cross-open checks against pinned SQLite."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as connection:
        assert connection.execute('select sqlite_source_id()').fetchone()[0] == PIN
        assert sorted(row[0] for row in connection.execute('pragma compile_options')) == manifest['compile_options']
    statements = [
        'CREATE TABLE t(id INTEGER PRIMARY KEY,x INT)',
        'INSERT INTO t VALUES(1,1),(2,2),(3,3)',
        'UPDATE t SET x=(SELECT sum(a.x) FROM t a WHERE a.id<=t.id) RETURNING id,x',
        'UPDATE t SET x=(SELECT max(x) FROM t) RETURNING id,x',
        'UPDATE t SET x=id',
        'UPDATE t SET x=x+10 WHERE EXISTS(SELECT 1 FROM t a WHERE a.x=t.x-1) RETURNING id,x',
        'UPDATE t SET x=id',
        'DELETE FROM t WHERE EXISTS(SELECT 1 FROM t a WHERE a.x=t.x-1) RETURNING id,x',
        'INSERT INTO t VALUES(2,2),(3,3)',
        'CREATE TABLE audit(x)',
        'CREATE TRIGGER ins AFTER INSERT ON t BEGIN INSERT INTO audit VALUES(new.x); END',
        'INSERT INTO t(x) VALUES((SELECT max(x)+1 FROM t)),((SELECT max(x)+1 FROM t)) RETURNING id,x',
        ('UPDATE t AS target SET x=(SELECT a.x+? FROM t a WHERE a.id=target.id) WHERE id IN (SELECT id FROM t WHERE id>?) RETURNING id,x', [10, 1]),
        'INSERT INTO t VALUES(1,99) ON CONFLICT(id) DO UPDATE SET x=(SELECT excluded.x+t.x) WHERE EXISTS(SELECT 1 WHERE excluded.x>t.x) RETURNING x',
        'DELETE FROM t AS target WHERE target.id IN (SELECT id FROM t WHERE x>50) RETURNING id',
        ('WITH q(v) AS (VALUES(?)) UPDATE t SET x=(SELECT v FROM q)+? WHERE id=? RETURNING x', [8, 2, 2]),
        'WITH RECURSIVE q(n) AS (VALUES(6) UNION ALL SELECT n+1 FROM q WHERE n<7) INSERT INTO t SELECT n,n*10 FROM q RETURNING id,x',
        ('WITH q AS (SELECT id FROM t WHERE id>?) DELETE FROM t WHERE id IN (SELECT id FROM q) RETURNING id', [5]),
        ('WITH q(v) AS (VALUES(?)) INSERT INTO t(x) VALUES((SELECT v FROM q)) RETURNING id,x', [20]),
        'UPDATE t SET x=(SELECT id,x FROM t)',
        'UPDATE t SET x=(SELECT missing FROM t)',
        'DELETE FROM t WHERE id IN (SELECT id,x FROM t)',
        'INSERT INTO t(x) VALUES((SELECT id,x FROM t))',
        'UPDATE t SET x=CASE WHEN id=2 THEN 99 ELSE (SELECT abs(-9223372036854775808)) END',
        'WITH q AS (VALUES(1)),q AS (VALUES(2)) DELETE FROM t',
        'UPDATE t SET x=(SELECT x FROM t WHERE 0)',
        'DELETE FROM t WHERE id NOT IN (SELECT x FROM t)',
        'CREATE TABLE words(k TEXT PRIMARY KEY COLLATE NOCASE,v TEXT) WITHOUT ROWID',
        "INSERT INTO words VALUES('A','λ😀'),('B','two')",
        "UPDATE words AS w SET v=(SELECT v||'!' FROM words a WHERE a.k=w.k) WHERE k IN (SELECT 'a') RETURNING *",
        "DELETE FROM words WHERE EXISTS(SELECT 1 FROM words a WHERE a.k=words.k AND a.v='two') RETURNING *",
        'CREATE TABLE parent(id INTEGER PRIMARY KEY)',
        'CREATE TABLE child(pid REFERENCES parent(id))',
        'PRAGMA foreign_keys=1',
        'INSERT INTO parent VALUES((SELECT max(id)+1 FROM t))',
        'INSERT INTO child VALUES((SELECT id FROM parent))',
        'DELETE FROM parent WHERE id IN (SELECT pid FROM child)',
        'BEGIN',
        'UPDATE t SET x=(SELECT count(*) FROM child) RETURNING *',
        'SAVEPOINT s',
        'DELETE FROM t WHERE id IN (SELECT id FROM t WHERE id>2)',
        'ROLLBACK TO s',
        'RELEASE s',
        'ROLLBACK',
        'CREATE TABLE dst(id INTEGER PRIMARY KEY,v)',
        'CREATE TRIGGER copy AFTER INSERT ON dst BEGIN UPDATE t SET x=(SELECT new.v) WHERE id=2; INSERT INTO audit VALUES((SELECT new.v)); END',
        "INSERT INTO dst VALUES(1,'value') RETURNING *",
        'CREATE VIEW tv AS SELECT id,x FROM t',
        'UPDATE dst SET v=(SELECT x FROM tv WHERE id=2) RETURNING *',
        'UPDATE dst SET v=(SELECT x FROM t WHERE id=dst.id) RETURNING (SELECT count(*) FROM dst)',
        'PRAGMA integrity_check',
    ]
    for number, action in enumerate(['CASCADE', 'SET NULL', 'SET DEFAULT']):
        p, c, log = [f'fk_{kind}{number}' for kind in ['p', 'c', 'log']]
        statements.extend([
            f'CREATE TABLE {p}(id INTEGER PRIMARY KEY)',
            f'CREATE TABLE {c}(id INTEGER PRIMARY KEY,pid DEFAULT 0 REFERENCES {p}(id) ON UPDATE {action} ON DELETE {action})',
            f'CREATE TABLE {log}(s)',
            f'INSERT INTO {p} VALUES(0),(1)',
            f'INSERT INTO {c} VALUES(10,1)',
            f"CREATE TRIGGER {p}bu BEFORE UPDATE ON {p} BEGIN INSERT INTO {log} VALUES('pbu'); END",
            f"CREATE TRIGGER {p}au AFTER UPDATE ON {p} BEGIN INSERT INTO {log} VALUES('pau'); END",
            f"CREATE TRIGGER {c}bu BEFORE UPDATE ON {c} BEGIN INSERT INTO {log} VALUES('cbu:'||old.pid||':'||coalesce(new.pid,'N')); END",
            f"CREATE TRIGGER {c}au AFTER UPDATE ON {c} BEGIN INSERT INTO {log} VALUES('cau:'||old.pid||':'||coalesce(new.pid,'N')); END",
            f"CREATE TRIGGER {c}bd BEFORE DELETE ON {c} BEGIN INSERT INTO {log} VALUES('cbd:'||old.pid); END",
            f"CREATE TRIGGER {c}ad AFTER DELETE ON {c} BEGIN INSERT INTO {log} VALUES('cad:'||old.pid); END",
            f'UPDATE {p} SET id=2 WHERE id=1 RETURNING id',
            f'DELETE FROM {p} WHERE id=2',
            f'DELETE FROM {c}',
            f'INSERT INTO {p} VALUES(1)',
            f'INSERT INTO {c} VALUES(10,1)',
            f'INSERT OR REPLACE INTO {p} VALUES(1)',
            f'DROP TABLE {p}',
        ])
    statements.extend([
        'CREATE TABLE fk_p(id PRIMARY KEY)',
        'CREATE TABLE fk_c(pid REFERENCES fk_p ON DELETE CASCADE)',
        'INSERT INTO fk_p VALUES(1)',
        'INSERT INTO fk_c VALUES(1)',
        "CREATE TRIGGER fk_block BEFORE DELETE ON fk_c BEGIN INSERT INTO audit VALUES('blocked'); SELECT RAISE(IGNORE); END",
        'DELETE FROM fk_p',
        'DROP TRIGGER fk_block',
        "CREATE TRIGGER fk_block BEFORE DELETE ON fk_c BEGIN INSERT INTO audit VALUES('blocked'); SELECT RAISE(FAIL,'blocked'); END",
        'DELETE FROM fk_p',
        'DROP TRIGGER fk_block',
        'CREATE TABLE fk_g(pid REFERENCES fk_c(pid) ON DELETE CASCADE)',
        'DROP TABLE fk_g',
        'CREATE UNIQUE INDEX fk_c_key ON fk_c(pid)',
        'CREATE TABLE fk_g(pid REFERENCES fk_c(pid) ON DELETE CASCADE)',
        'INSERT INTO fk_g VALUES(1)',
        "CREATE TRIGGER fk_gd AFTER DELETE ON fk_g BEGIN INSERT INTO audit VALUES('grandchild'); END",
        'DELETE FROM fk_p',
        'PRAGMA integrity_check',
    ])
    statements.extend([
        'CREATE TABLE from_t(id INTEGER PRIMARY KEY,n INTEGER)',
        'INSERT INTO from_t VALUES(1,10),(2,20),(3,30)',
        'CREATE TABLE from_s(id INTEGER,delta INTEGER)',
        'INSERT INTO from_s VALUES(1,2),(1,3),(3,4)',
        'UPDATE from_t SET n=from_t.n+from_s.delta FROM from_s WHERE from_s.id=from_t.id RETURNING id,n',
        'UPDATE from_t AS target SET n=source.n+1 FROM from_t AS source WHERE target.id=source.id+1 RETURNING *',
        ('WITH q(id,v) AS (VALUES(?,?)) UPDATE from_t AS target SET n=q.v+d.delta+? FROM q JOIN (SELECT id,max(delta) AS delta FROM from_s GROUP BY id) AS d USING(id) WHERE target.id=q.id RETURNING from_t.id,n', [1,40,2]),
        'UPDATE from_t SET n=from_s.delta FROM from_s LEFT JOIN (SELECT 1 AS k) AS q ON q.k=from_s.id WHERE from_t.id=from_s.id RETURNING *',
        'CREATE TABLE from_wr(k TEXT PRIMARY KEY COLLATE NOCASE,n) WITHOUT ROWID',
        "INSERT INTO from_wr VALUES('A',10),('B',20)",
        "UPDATE from_wr SET n=from_s.delta FROM from_s WHERE from_wr.k=CASE from_s.id WHEN 1 THEN 'a' ELSE 'z' END RETURNING *",
        'CREATE TABLE from_shadow(rowid,oid,_rowid_,v)',
        'INSERT INTO from_shadow VALUES(1,1,1,0),(1,1,1,0)',
        'UPDATE from_shadow SET v=from_s.delta FROM from_s WHERE from_s.id=1 RETURNING v',
        'CREATE VIEW from_v AS SELECT id,n FROM from_t',
        'CREATE TRIGGER from_vu INSTEAD OF UPDATE ON from_v BEGIN UPDATE from_t SET n=new.n WHERE id=old.id; END',
        'UPDATE from_v SET n=from_v.n+from_s.delta FROM from_s WHERE from_v.id=from_s.id RETURNING *',
        'UPDATE from_t SET n=id FROM from_s',
        'UPDATE from_t SET n=missing FROM from_s',
        'UPDATE from_t SET n=1 FROM missing',
        'UPDATE from_t SET n=1 FROM from_t',
        'UPDATE from_t SET n=from_s.delta FROM from_s RETURNING from_s.delta',
        'UPDATE from_t AS q SET n=1 RETURNING q.n',
        'UPDATE from_t SET n=1 RETURNING main.from_t.n',
        'UPDATE from_t SET n=from_s.delta FROM from_s WHERE 0',
        'PRAGMA integrity_check',
    ])
    statements.extend([
        'CREATE VIEW dml_first AS SELECT id,n FROM from_t',
        'CREATE VIEW dml_second AS SELECT id,n FROM dml_first',
        'UPDATE from_t SET n=id',
        'UPDATE from_t SET n=(SELECT sum(n) FROM dml_second WHERE id<=from_t.id) RETURNING n',
        'CREATE TABLE from_r(id,b)',
        'INSERT INTO from_r VALUES(2,5),(4,8)',
        'UPDATE from_t SET n=coalesce(from_s.delta,from_r.b) FROM from_s FULL JOIN from_r USING(id) WHERE from_t.id=from_s.id OR from_t.id=from_r.id RETURNING *',
        'UPDATE from_t SET n=coalesce(from_s.delta,from_r.b) FROM from_s RIGHT JOIN from_r USING(id) WHERE from_t.id=from_r.id RETURNING *',
        'UPDATE from_t SET n=from_s.delta FROM from_s JOIN from_r ON from_t.id=from_r.id',
        'UPDATE from_t SET n=from_s.delta FROM from_s LEFT JOIN from_r ON from_t.id=from_r.id',
        'UPDATE from_t SET n=from_s.delta FROM from_s FULL JOIN from_r ON from_t.id=from_r.id',
        'PRAGMA integrity_check',
    ])
    operations = [dict(sql=item if isinstance(item, str) else item[0],
                       parameters=[] if isinstance(item, str) else item[1],
                       query=item.startswith('PRAGMA integrity') if isinstance(item, str) else False)
                  for item in statements]
    for encoding in [1, 2, 3]:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / 'operations.json').write_text(json.dumps(operations))
            subprocess.run(['dart', '--suppress-analytics', 'run', 'tool/export_schema.dart', str(directory), str(encoding)],
                           cwd=ROOT.parents[1], check=True)
            with sqlite3.connect(':memory:', isolation_level=None) as reference:
                reference.execute(f'pragma encoding="{["UTF-8", "UTF-16le", "UTF-16be"][encoding-1]}"')
                for i, operation in enumerate(operations):
                    expected_error = None
                    rows = None
                    changes = 0
                    try:
                        cursor = reference.execute(operation['sql'], operation['parameters'])
                        if cursor.description:
                            rows = dict(columns=[col[0] for col in cursor.description],
                                        rows=[[encode(v) for v in row] for row in cursor.fetchall()])
                        if not operation['query']:
                            changes = (reference.execute('select changes()').fetchone()[0]
                                       if operation['sql'].startswith('WITH')
                                       else max(0, cursor.rowcount))
                    except sqlite3.DatabaseError as error:
                        expected_error = str(error)
                    actual = json.loads((directory / f'{i}.json').read_text())
                    context = f'encoding {encoding}, step {i}: {operation["sql"]}'
                    assert bool(actual['error']) == bool(expected_error), (context, actual, expected_error)
                    assert actual['changes'] == changes, (context, actual, changes)
                    assert actual['returning'] == rows, (context, actual, rows)
                    with sqlite3.connect(f'file:{directory / str(i)}.db?mode=ro', uri=True) as opened:
                        assert opened.execute('pragma integrity_check').fetchall() == [('ok',)], context
                        for (name,) in reference.execute("select name from sqlite_schema where type='table' order by name"):
                            escaped = name.replace('"', '""')
                            expected = reference.execute(f'SELECT * FROM "{escaped}"').fetchall()
                            observed = opened.execute(f'SELECT * FROM "{escaped}"').fetchall()
                            assert observed == expected, (context, name, observed, expected)
    print(f'Pinned SQLite DML subquery checks passed: {len(operations)} snapshots per encoding ({3*len(operations)} total)')


if __name__ == '__main__':
    main()
