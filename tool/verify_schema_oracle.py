"""Cross-open Pure Dart-created schemas/indexes and compare to pinned SQLite."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path
from generate_fixtures import ROOT,PIN
from generate_sql_oracle import encode


def main():
    with sqlite3.connect(':memory:') as c:
        if c.execute('select sqlite_source_id()').fetchone()[0]!=PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(r[0] for r in c.execute('pragma compile_options'))!=json.loads((ROOT/'manifest.json').read_text())['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    statements=[
        'CREATE TABLE users(id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE, age INT DEFAULT 18 CHECK(age>=0))',
        "INSERT INTO users(email) VALUES('a'),('b')",
        'CREATE INDEX users_age ON users(age DESC,email COLLATE NOCASE)',
        "UPDATE users SET age=age+2 WHERE id=1",
        "INSERT INTO users(email) VALUES(NULL)",
        "INSERT INTO users(email,age) VALUES('bad',-1)",
        "INSERT INTO users(email) VALUES('a')",
        "INSERT OR IGNORE INTO users(email) VALUES('a')",
        "INSERT OR REPLACE INTO users(email) VALUES('a')",
        'CREATE TABLE seq(id INTEGER PRIMARY KEY AUTOINCREMENT,value TEXT)',
        "INSERT INTO seq(value) VALUES('a')",'DELETE FROM seq',"INSERT INTO seq(value) VALUES('b')",
        'PRAGMA foreign_keys=1','CREATE TABLE parent(id INTEGER PRIMARY KEY)',
        'CREATE TABLE child(id INTEGER PRIMARY KEY,parent INT REFERENCES parent(id) ON DELETE CASCADE ON UPDATE CASCADE)',
        'INSERT INTO parent VALUES(7)','INSERT INTO child VALUES(1,7)','UPDATE parent SET id=8 WHERE id=7','DELETE FROM parent',
        'CREATE TABLE pairs(a TEXT,b INT,c TEXT,PRIMARY KEY(a,b)) WITHOUT ROWID',
    ]
    statements += [f"INSERT INTO pairs VALUES('k{i%7}',{i},'{('x'*150)+str(i)}')" for i in range(80)]
    statements += ["ALTER TABLE users ADD COLUMN label TEXT NOT NULL DEFAULT 'new'", "INSERT INTO users(email) SELECT 'bulk-'||id FROM users ORDER BY id"]
    statements += ["CREATE TABLE strict_t(i INT, r REAL, t TEXT, a ANY) STRICT", "INSERT INTO strict_t VALUES('7','3.5',9,'0001')", "INSERT INTO strict_t(i) VALUES('bad')", "CREATE TABLE auto_t(id INTEGER PRIMARY KEY AUTOINCREMENT,v TEXT UNIQUE)", "INSERT INTO auto_t(v) VALUES('a')", "INSERT OR IGNORE INTO auto_t(v) VALUES('a')", "INSERT INTO auto_t(v) VALUES('b')"]
    statements += ["CREATE TABLE key_order(u TEXT UNIQUE,p TEXT PRIMARY KEY)","INSERT INTO key_order VALUES('u','p')","CREATE TABLE desc_pk(id INTEGER PRIMARY KEY DESC,v TEXT)","INSERT INTO desc_pk VALUES(1,'a'),(2,'b')","CREATE TABLE wr_u(a TEXT PRIMARY KEY,b TEXT UNIQUE) WITHOUT ROWID","INSERT INTO wr_u VALUES('a','b')","CREATE TABLE ci(id INTEGER PRIMARY KEY,v TEXT COLLATE NOCASE UNIQUE)","INSERT INTO ci(v) VALUES('a')","INSERT INTO ci(v) VALUES('A')"]
    statements += ['CREATE INDEX pairs_c ON pairs(c)','UPDATE pairs SET a=\'changed\' WHERE b=1','DROP INDEX users_age','DELETE FROM users WHERE id=2']
    statements += ["CREATE TABLE watched(id INTEGER PRIMARY KEY,v TEXT)","CREATE TABLE audit(event TEXT,id INT,v TEXT)","CREATE VIEW visible(k,value) AS SELECT id,v FROM watched WHERE id>0", "CREATE TRIGGER ins AFTER INSERT ON watched BEGIN INSERT INTO audit VALUES('I',new.id,new.v); END", "CREATE TRIGGER upd AFTER UPDATE OF v ON watched BEGIN INSERT INTO audit VALUES('U',old.id,new.v); END", "CREATE TRIGGER del AFTER DELETE ON watched BEGIN INSERT INTO audit VALUES('D',old.id,old.v); END", "CREATE TRIGGER guard BEFORE INSERT ON watched WHEN new.v='bad' BEGIN SELECT RAISE(ABORT,'rejected'); END", "INSERT INTO watched VALUES(1,'a'),(2,'b')", "INSERT INTO watched VALUES(3,'ok'),(4,'bad')", "UPDATE watched SET v='changed' WHERE id=1", "DELETE FROM watched WHERE id=2", "DROP TRIGGER ins", "INSERT INTO watched VALUES(5,'no trigger')", "DROP VIEW visible"]
    statements += ["CREATE TABLE ignored(x INT)","CREATE TRIGGER ignore_two BEFORE INSERT ON ignored WHEN new.x=2 BEGIN INSERT INTO audit VALUES('skip',new.x,NULL); SELECT RAISE(IGNORE); END", "INSERT INTO ignored VALUES(1),(2),(3)","CREATE TABLE mismatch(id INT)", "INSERT INTO mismatch VALUES(1)","CREATE TABLE mismatch_child(pid INT REFERENCES mismatch(id))", "INSERT INTO mismatch_child VALUES(1)","CREATE UNIQUE INDEX mismatch_id ON mismatch(id)","INSERT INTO mismatch_child VALUES(1)","DROP TABLE mismatch_child", "CREATE TABLE mismatch_child(pid INT REFERENCES mismatch(id) ON DELETE CASCADE)","INSERT INTO mismatch_child VALUES(1)","INSERT OR REPLACE INTO mismatch VALUES(1)"]
    statements += ['PRAGMA user_version=7','PRAGMA application_id=-1','PRAGMA user_version=2147483648']
    statements += ["CREATE TABLE returned(id INTEGER PRIMARY KEY,v TEXT UNIQUE)","INSERT INTO returned(v) VALUES('a'),('b') RETURNING *,id+10 AS next", "INSERT OR IGNORE INTO returned(v) VALUES('a') RETURNING id", "CREATE TRIGGER changed AFTER UPDATE ON returned BEGIN UPDATE returned SET v='trigger' WHERE id=new.id; END", "UPDATE returned SET v='direct' WHERE id=1 RETURNING returned.id,v", "DELETE FROM returned WHERE id=1 RETURNING *", "INSERT INTO returned(v) SELECT 'c' RETURNING id,v", "DELETE FROM returned RETURNING count(*)"]
    statements += ["CREATE TABLE upserted(id INTEGER PRIMARY KEY AUTOINCREMENT,k TEXT UNIQUE,n INT NOT NULL CHECK(n>0))", "INSERT INTO upserted(k,n) VALUES('a',1),('b',2)", "INSERT INTO upserted(k,n) VALUES('a',3),('c',4) ON CONFLICT(k) DO UPDATE SET n=upserted.n+excluded.n RETURNING id,k,n", "INSERT INTO upserted(k,n) VALUES('a',1) ON CONFLICT(k) DO NOTHING RETURNING id", "INSERT INTO upserted(k,n) VALUES('a',1) ON CONFLICT(k) DO UPDATE SET n=excluded.n WHERE excluded.n>upserted.n RETURNING id", "INSERT INTO upserted(id,k,n) VALUES(1,'new',8) ON CONFLICT(id) DO UPDATE SET n=excluded.n RETURNING n", "INSERT INTO upserted(k,n) VALUES('a',NULL) ON CONFLICT(k) DO NOTHING", "INSERT INTO upserted(k,n) VALUES('a',2) ON CONFLICT(k) DO UPDATE SET k='b'", "INSERT INTO upserted(k,n) SELECT 'a',2 WHERE 1 ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING n", "CREATE TABLE wr_up(k TEXT PRIMARY KEY,n INT) WITHOUT ROWID", "INSERT INTO wr_up VALUES('x',1)", "INSERT INTO wr_up VALUES('x',2) ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING *", "INSERT INTO wr_up VALUES('x',3) ON CONFLICT(n) DO NOTHING"]
    statements += ["CREATE TABLE rename_p(id INTEGER PRIMARY KEY AUTOINCREMENT,k TEXT UNIQUE)","CREATE INDEX rename_p_k ON rename_p(k)","INSERT INTO rename_p(k) VALUES('a')", "CREATE TABLE rename_c(pid INT REFERENCES rename_p(id))", "INSERT INTO rename_c VALUES(1)", "ALTER TABLE rename_p RENAME TO renamed", "INSERT INTO renamed(k) VALUES('b')", "INSERT INTO rename_c VALUES(2)", 'ALTER TABLE renamed RENAME TO "space name"']
    statements += ["CREATE VIEW collision_view AS SELECT * FROM returned", "CREATE TABLE collision_view(x)", "CREATE INDEX collision_view ON returned(v)", "CREATE VIEW sqlite_bad AS SELECT 1", "CREATE TRIGGER bad AFTER INSERT ON returned BEGIN UPDATE returned SET ; END", "CREATE TRIGGER bad AFTER INSERT ON returned BEGIN INSERT INTO returned VALUES(1,'bad') RETURNING id; END"]
    statements += ["CREATE TABLE bound_source(v)", "CREATE TABLE bound_audit(v)", "CREATE TRIGGER bound_copy AFTER INSERT ON bound_source BEGIN INSERT INTO bound_audit VALUES(new.v); END", "INSERT INTO bound_source VALUES('a'||char(0)||'b'),(1e999),(-1e999),(X'0027ff')"]
    statements += ["INSERT INTO upserted(id,k,n) VALUES(1,'unused',1),(99,'b',2),(100,'fresh',3) ON CONFLICT(id) DO NOTHING ON CONFLICT(k) DO UPDATE SET n=excluded.n RETURNING k,n", "INSERT INTO upserted(k,n) VALUES('a',9) ON CONFLICT DO UPDATE SET n=excluded.n RETURNING n"]
    with tempfile.TemporaryDirectory() as directory:
        root=Path(directory);(root/'operations.json').write_text(json.dumps([{'sql':sql,'parameters':[]} for sql in statements]))
        subprocess.run(['dart','--suppress-analytics','run','tool/export_schema.dart',directory],cwd=ROOT.parents[1],check=True)
        with sqlite3.connect(root/'reference.db',isolation_level=None) as ref:
            ref.execute('pragma page_size=512')
            for i,sql in enumerate(statements):
                error=None
                returned=None
                try:
                    cursor=ref.execute(sql)
                    if cursor.description is not None:returned={'columns':[c[0] for c in cursor.description],'rows':[[encode(v) for v in row] for row in cursor.fetchall()]}
                except sqlite3.Error as exc:error=str(exc)
                metadata=json.loads((root/f'{i}.json').read_text())
                if (error is None)!=(metadata['error'] is None):
                    raise RuntimeError(f'Error mismatch at {i}: {sql}; SQLite={error}; Dart={metadata}')
                if returned!=metadata['returning']:raise RuntimeError(f'RETURNING mismatch at {i}: {sql}; SQLite={returned}; Dart={metadata}')
                with sqlite3.connect(f'file:{root/i.__str__()}.db?mode=ro',uri=True) as actual:
                    for pragma in ['user_version','application_id']:
                        if actual.execute('pragma '+pragma).fetchall()!=ref.execute('pragma '+pragma).fetchall():raise RuntimeError(f'Header {pragma} differs at {i}')
                    integrity=actual.execute('pragma integrity_check').fetchall()
                    if integrity!=[('ok',)]:raise RuntimeError(f'Integrity failure at {i}: {sql}; {integrity}')
                    names=[r[0] for r in ref.execute("select name from sqlite_schema where type='table' order by name")]
                    if names!=[r[0] for r in actual.execute("select name from sqlite_schema where type='table' order by name")]:raise RuntimeError(f'Schema names differ at {i}')
                    for name in names:
                        escaped='"'+name.replace('"','""')+'"'
                        expected=ref.execute(f'select * from {escaped}').fetchall();rows=actual.execute(f'select * from {escaped}').fetchall()
                        if sorted(expected,key=repr)!=sorted(rows,key=repr):raise RuntimeError(f'Rows differ at {i}: {name}')
                        if ref.execute(f'pragma index_list({escaped})').fetchall()!=actual.execute(f'pragma index_list({escaped})').fetchall():raise RuntimeError(f'Index metadata differs at {i}: {name}')
                        if ref.execute(f'pragma foreign_key_list({escaped})').fetchall()!=actual.execute(f'pragma foreign_key_list({escaped})').fetchall():raise RuntimeError(f'Foreign-key metadata differs at {i}: {name}')
        print(f'Pinned SQLite verified {len(statements)} Dart schema/index/constraint mutation snapshots')


if __name__=='__main__':main()
