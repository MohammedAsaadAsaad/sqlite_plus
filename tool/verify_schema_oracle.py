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
    statements += ["CREATE TABLE defaults_pinned(id INTEGER PRIMARY KEY,v TEXT DEFAULT (datetime('2000-01-01','+1 day')),n INT DEFAULT (1+2))", "INSERT INTO defaults_pinned DEFAULT VALUES", "PRAGMA foreign_keys=0", "CREATE TABLE pragma_p(id INTEGER PRIMARY KEY)", "CREATE TABLE pragma_c(id INTEGER PRIMARY KEY,pid REFERENCES pragma_p)", "INSERT INTO pragma_p VALUES(1)", "INSERT INTO pragma_c VALUES(1,1),(2,9),(3,NULL)", "PRAGMA foreign_key_check(pragma_c)", "PRAGMA integrity_check", "PRAGMA quick_check(1)", "CREATE TABLE pragma_wr(k TEXT PRIMARY KEY,pid REFERENCES pragma_p) WITHOUT ROWID", "INSERT INTO pragma_wr VALUES('x',9)", "PRAGMA foreign_key_check(pragma_wr)", "CREATE TABLE pragma_mismatch(pid REFERENCES defaults_pinned(n))", "PRAGMA foreign_key_check(pragma_mismatch)"]
    statements += ["CREATE TABLE alter_p(id INTEGER PRIMARY KEY,code TEXT UNIQUE,junk BLOB,value INT CHECK(value>0),CHECK(length(code)>0))", "CREATE INDEX alter_idx ON alter_p(code,value DESC)", "CREATE TABLE alter_c(code TEXT REFERENCES alter_p(code))", "INSERT INTO alter_p VALUES(1,'a',zeroblob(2000),7)", "INSERT INTO alter_c VALUES('a')", "ALTER TABLE alter_p RENAME COLUMN code TO label", "ALTER TABLE alter_p DROP COLUMN junk", "ALTER TABLE alter_p RENAME value TO length", "ALTER TABLE alter_p RENAME COLUMN length TO amount", "ALTER TABLE alter_p DROP COLUMN amount", "DROP INDEX alter_idx", "ALTER TABLE alter_p DROP amount", "ALTER TABLE alter_p DROP label", "ALTER TABLE alter_p DROP id", "ALTER TABLE alter_p RENAME label TO id", "PRAGMA integrity_check"]
    statements += ["CREATE TABLE alter_wr(k TEXT PRIMARY KEY,pad BLOB,n INT) WITHOUT ROWID", "INSERT INTO alter_wr VALUES('key',zeroblob(1000),7)", "ALTER TABLE alter_wr DROP pad", "ALTER TABLE alter_wr RENAME k TO ident", "PRAGMA integrity_check"]
    statements += ['CREATE TABLE punct("(" TEXT,")" INT,"," BLOB)', "INSERT INTO punct VALUES('x',7,X'00')", 'ALTER TABLE punct RENAME COLUMN ")" TO number', 'ALTER TABLE punct DROP COLUMN ","']
    statements += [
        "CREATE TABLE expr_idx(id INTEGER PRIMARY KEY,name TEXT COLLATE NOCASE,active INT,n INT)",
        "CREATE UNIQUE INDEX expr_live ON expr_idx(lower(name)) WHERE active=1",
        "CREATE INDEX expr_mag ON expr_idx(abs(n) DESC,substr(name,1,1) COLLATE RTRIM) WHERE n IS NOT NULL",
        "INSERT INTO expr_idx VALUES(1,'Alpha',1,-7),(2,'ALPHA',0,8),(3,NULL,1,NULL),(4,NULL,1,9)",
        "CREATE UNIQUE INDEX invalid_full ON expr_idx(lower(name))",
        "INSERT INTO expr_idx VALUES(5,'alpha',1,2)",
        "INSERT OR IGNORE INTO expr_idx VALUES(5,'alpha',1,2)",
        "UPDATE expr_idx SET active=1 WHERE id=2",
        "INSERT OR REPLACE INTO expr_idx VALUES(5,'alpha',1,2)",
        "INSERT INTO expr_idx VALUES(6,'Alpha',1,3) ON CONFLICT(lower(name)) WHERE active=1 DO UPDATE SET n=excluded.n RETURNING id,n",
        "INSERT INTO expr_idx VALUES(7,'ALPHA',1,4) ON CONFLICT DO UPDATE SET n=excluded.n RETURNING id,n",
        "INSERT INTO expr_idx VALUES(8,'alpha',1,5) ON CONFLICT(lower(name)) DO NOTHING",
        "UPDATE expr_idx SET n=-n",
        "UPDATE expr_idx SET active=0 WHERE id=5",
        "INSERT INTO expr_idx VALUES(8,'ALPHA',1,5) RETURNING lower(name)='alpha',lower(name)='ALPHA',name='alpha',CAST(name AS TEXT)='alpha',(name||'')='alpha'",
        "DELETE FROM expr_idx WHERE id=8",
        "PRAGMA index_info(expr_live)","PRAGMA index_xinfo(expr_live)","PRAGMA index_xinfo(expr_mag)",
        "ALTER TABLE expr_idx RENAME COLUMN name TO label", "ALTER TABLE expr_idx RENAME TO expr_renamed",
        "UPDATE expr_renamed SET label='Beta' WHERE id=5", "PRAGMA integrity_check",
        "ALTER TABLE expr_renamed DROP active", "ALTER TABLE expr_renamed DROP label",
        "DROP INDEX expr_live", "ALTER TABLE expr_renamed DROP active",
        "CREATE TABLE expr_wr(k TEXT PRIMARY KEY,n INT) WITHOUT ROWID", "INSERT INTO expr_wr VALUES('A',1),('a',2),('b',3)",
        "CREATE INDEX expr_wr_case ON expr_wr(k COLLATE NOCASE)", "CREATE INDEX expr_wr_mag ON expr_wr(abs(n)) WHERE n>1",
        "PRAGMA index_xinfo(expr_wr_case)","PRAGMA index_xinfo(expr_wr_mag)", "UPDATE expr_wr SET n=-n", "INSERT INTO expr_wr VALUES('c',7)",
        "CREATE INDEX invalid_agg ON expr_renamed(sum(n))", "CREATE INDEX invalid_subquery ON expr_renamed((SELECT 1))",
        "CREATE INDEX invalid_parameter ON expr_renamed(?)", "CREATE INDEX invalid_rowid ON expr_renamed(rowid)",
        "CREATE INDEX invalid_now ON expr_renamed(CURRENT_TIMESTAMP)",
        "CREATE INDEX expr_clock ON expr_renamed(datetime(n))", "INSERT OR IGNORE INTO expr_renamed VALUES(99,'now','now')",
        "INSERT OR IGNORE INTO expr_renamed VALUES(99,'overflow',-9223372036854775808)",
        "PRAGMA integrity_check",
    ]
    statements += ["INSERT INTO expr_renamed VALUES(100,'"+('X'*4000)+"',100)","PRAGMA integrity_check"]
    statements += ["CREATE TABLE expr_target(a INT,active INT)","CREATE UNIQUE INDEX expr_target_partial ON expr_target(a) WHERE active=1", "INSERT INTO expr_target VALUES(1,1)"]
    statements += [f"INSERT INTO expr_target VALUES(1,1) ON CONFLICT(a) WHERE {predicate} DO NOTHING" for predicate in ['active=TRUE','active=1 AND a>0','1=active','active=1.0']]
    statements += ["CREATE UNIQUE INDEX expr_real_key ON expr_target(a+1.0)", "INSERT INTO expr_target VALUES(1,1) ON CONFLICT(a+1.00) DO NOTHING", "INSERT INTO expr_target VALUES(1,1) ON CONFLICT(a+1.0) DO NOTHING", "CREATE INDEX expr_fixed_clock ON expr_target(datetime('2000-01-01','subsec'))"]
    statements += ["CREATE TABLE unicode_expr(id INTEGER PRIMARY KEY,v TEXT,b BLOB)", "CREATE UNIQUE INDEX unicode_expr_key ON unicode_expr(lower(v))", "CREATE INDEX unicode_blob_key ON unicode_expr(substr(b,2,2))", "INSERT INTO unicode_expr VALUES(1,'λ😀A',X'0001ff'),(2,'😀λA',X'0002fe')", "INSERT INTO unicode_expr VALUES(3,'λ😀a',X'00')", "CREATE INDEX invalid_raise ON unicode_expr(RAISE(ABORT,'bad'))", "PRAGMA integrity_check"]
    statements += ["CREATE TABLE expr_reals(id INTEGER PRIMARY KEY,r REAL)","INSERT INTO expr_reals VALUES(1,1),(2,2.0)","CREATE INDEX expr_real_type ON expr_reals(typeof(r))","CREATE INDEX expr_real_text ON expr_reals(CAST(r AS TEXT))","UPDATE expr_reals SET r=r+1 RETURNING typeof(r)","PRAGMA integrity_check"]
    for encoding in [1,2,3]:
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'operations.json').write_text(json.dumps([{'sql':sql,'parameters':[],'query':any(sql.upper().startswith('PRAGMA '+name) for name in ['FOREIGN_KEY_CHECK','INTEGRITY_CHECK','QUICK_CHECK','INDEX_INFO','INDEX_XINFO','INDEX_LIST'])} for sql in statements]))
            subprocess.run(['dart','--suppress-analytics','run','tool/export_schema.dart',directory,str(encoding)],cwd=ROOT.parents[1],check=True)
            with sqlite3.connect(root/'reference.db',isolation_level=None) as ref:
                ref.execute('pragma page_size=512')
                ref.execute("pragma encoding='"+{1:'UTF-8',2:'UTF-16le',3:'UTF-16be'}[encoding]+"'")
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
            print(f'Pinned SQLite verified {len(statements)} Dart schema/index/constraint mutation snapshots; encoding={encoding}')


if __name__=='__main__':main()
