"""Cross-open Pure Dart-created schemas/indexes and compare to pinned SQLite."""
import warnings
warnings.filterwarnings("ignore", message="Binding .* is a named parameter.*", category=DeprecationWarning)
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
    statements += ["CREATE TABLE trigger_select(id INTEGER PRIMARY KEY,n INT)", "CREATE TABLE trigger_audit(n INT)", "INSERT INTO trigger_audit VALUES(1)", "CREATE TRIGGER trigger_capacity BEFORE INSERT ON trigger_select BEGIN SELECT RAISE(ABORT,'capacity') FROM trigger_audit WHERE (SELECT count(*) FROM trigger_select)>=2; END", "CREATE TRIGGER trigger_negative BEFORE INSERT ON trigger_select WHEN EXISTS(SELECT 1 FROM trigger_audit WHERE n=1) BEGIN WITH guard(x) AS (SELECT new.n) SELECT RAISE(ABORT,'negative') FROM guard WHERE x<0; END", "CREATE TRIGGER trigger_disabled BEFORE INSERT ON trigger_select BEGIN SELECT RAISE(ABORT,'disabled') FROM trigger_audit LIMIT 0; END", "INSERT INTO trigger_select VALUES(1,1),(2,2)", "INSERT INTO trigger_select VALUES(3,3)", "DELETE FROM trigger_select WHERE id=2", "INSERT INTO trigger_select VALUES(3,-1)", "INSERT INTO trigger_select VALUES(3,3)", "CREATE TABLE recursive_counter(n INT)", "INSERT INTO recursive_counter VALUES(0)", "CREATE TRIGGER recursive_bump AFTER UPDATE ON recursive_counter WHEN new.n<5 BEGIN UPDATE recursive_counter SET n=n+1; END", "UPDATE recursive_counter SET n=1", "PRAGMA recursive_triggers=ON", "UPDATE recursive_counter SET n=1", "PRAGMA recursive_triggers", "PRAGMA recursive_triggers=OFF", "PRAGMA recursive_triggers"]
    statements += ["CREATE TABLE trigger_assigned(id INTEGER PRIMARY KEY,v INT)", "CREATE TABLE trigger_observed(id INT,rid INT)", "CREATE TRIGGER observe_id BEFORE INSERT ON trigger_assigned BEGIN INSERT INTO trigger_observed VALUES(new.id,new.rowid); END", "CREATE TRIGGER seed_id BEFORE INSERT ON trigger_assigned WHEN new.v=1 BEGIN INSERT INTO trigger_assigned(v) VALUES(2); END", "INSERT INTO trigger_assigned(v) VALUES(1) RETURNING id", "DROP TRIGGER seed_id", "CREATE TRIGGER follow_id AFTER INSERT ON trigger_assigned WHEN new.v=3 BEGIN INSERT INTO trigger_assigned(v) VALUES(4); END", "INSERT INTO trigger_assigned(v) VALUES(3),(3) RETURNING id"]
    statements += ["CREATE TABLE typed_trigger(v TEXT COLLATE NOCASE,n NUMERIC,b BLOB)", "CREATE TABLE typed_hits(x INT)", "INSERT INTO typed_hits VALUES(0)", "CREATE TABLE typed_audit(v,b)", "CREATE TRIGGER typed_guard BEFORE INSERT ON typed_trigger WHEN new.v=1 AND new.n='2' -- comment\n BEGIN SELECT RAISE(ABORT,'wrong blob') WHERE typeof(new.b)!='blob'; UPDATE typed_hits SET x=x+1 WHERE new.v=1; INSERT INTO typed_audit SELECT new.v,new.b WHERE new.n='2'; END", "INSERT INTO typed_trigger VALUES('1','2',X'00ff')", "CREATE TRIGGER typed_case AFTER INSERT ON typed_trigger WHEN new.v='A' BEGIN UPDATE typed_hits SET x=x+1 WHERE new.v='A'; END", "INSERT INTO typed_trigger VALUES('a',3,X'00')"]
    statements += ["CREATE TRIGGER typed_guard_exact BEFORE INSERT ON typed_trigger WHEN new.v='1' AND new.n=2 BEGIN SELECT RAISE(ABORT,'wrong blob') WHERE typeof(new.b)!='blob'; UPDATE typed_hits SET x=x+1 WHERE new.v='1'; INSERT INTO typed_audit SELECT new.v,new.b WHERE new.n=2; END", "CREATE TABLE typed_flags(a,b,c)", "CREATE TRIGGER typed_flags_capture AFTER INSERT ON typed_trigger BEGIN INSERT INTO typed_flags SELECT new.v=1,new.n='2',new.v='A'; END", "INSERT INTO typed_trigger VALUES('1','2',X'00ff')", "INSERT INTO typed_trigger VALUES('a',2,X'00')"]
    statements += ["CREATE TABLE fail_before(x INT)","CREATE TABLE fail_audit(x INT)","CREATE TRIGGER fail_policy BEFORE INSERT ON fail_before WHEN new.x=2 BEGIN INSERT INTO fail_audit VALUES(new.x); SELECT RAISE(FAIL,'stop'); END", "INSERT INTO fail_before VALUES(1),(2),(3)", "CREATE TABLE fail_after(x INT)", "CREATE TRIGGER fail_after_policy AFTER INSERT ON fail_after WHEN new.x=2 BEGIN INSERT INTO fail_audit VALUES(new.x); SELECT RAISE(FAIL,'after'); END", "INSERT INTO fail_after VALUES(1),(2),(3)", "BEGIN", "SAVEPOINT fail_save", "INSERT INTO fail_before VALUES(4),(2),(5)", "ROLLBACK TO fail_save", "COMMIT", "CREATE TABLE rollback_policy(x INT)", "CREATE TRIGGER rollback_stop BEFORE INSERT ON rollback_policy WHEN new.x=2 BEGIN SELECT RAISE(ROLLBACK,'stop'); END", "INSERT INTO rollback_policy VALUES(9)", "INSERT INTO rollback_policy VALUES(1),(2)", "BEGIN", "INSERT INTO rollback_policy VALUES(8)", "SAVEPOINT rollback_save", "INSERT INTO rollback_policy VALUES(1),(2)", "RELEASE rollback_save"]
    statements += [
        "CREATE TABLE view_base(id INTEGER PRIMARY KEY,v TEXT,n REAL DEFAULT 4)",
        "CREATE VIEW editable(key,label,num) AS SELECT id,v,n FROM view_base",
        "INSERT INTO editable VALUES(1,'blocked',1)",
        "CREATE TRIGGER invalid_view BEFORE INSERT ON editable BEGIN SELECT 1; END",
        "CREATE TRIGGER invalid_table INSTEAD OF INSERT ON view_base BEGIN SELECT 1; END",
        "CREATE TRIGGER view_insert INSTEAD OF INSERT ON editable BEGIN INSERT INTO view_base VALUES(new.key,new.label,new.num); END",
        "INSERT INTO editable(label,num) VALUES('a',1),('b',2) RETURNING *",
        "CREATE TRIGGER view_update INSTEAD OF UPDATE OF label,num ON editable BEGIN UPDATE view_base SET v=new.label,n=new.num WHERE id=old.key; END",
        "UPDATE editable SET label=label||'!',num=num+1 WHERE key=1 RETURNING *",
        "UPDATE editable SET key=99 WHERE key=1 RETURNING *",
        "CREATE TRIGGER view_delete INSTEAD OF DELETE ON editable BEGIN DELETE FROM view_base WHERE id=old.key; END",
        "DELETE FROM editable WHERE key=2 RETURNING *",
        "INSERT INTO editable VALUES(7,42,'3') RETURNING typeof(label),typeof(num)",
        "INSERT INTO editable DEFAULT VALUES RETURNING *",
        "INSERT INTO editable(rowid) VALUES(9)",
        "CREATE TRIGGER view_no_rowid INSTEAD OF INSERT ON editable BEGIN INSERT INTO view_base VALUES(new.rowid,'bad',0); END",
        "INSERT INTO editable VALUES(8,'bad',0)",
        "DROP TRIGGER view_no_rowid",
        "INSERT INTO editable VALUES(9,'bad',0) ON CONFLICT DO NOTHING",
        "BEGIN", "DELETE FROM editable", "ROLLBACK",
        "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE conflict_rows(id INT UNIQUE,v INT NOT NULL DEFAULT 7 CHECK(v>0)) STRICT",
      "INSERT OR FAIL INTO conflict_rows VALUES(1,1),(2,NULL),(3,3)",
      "INSERT OR IGNORE INTO conflict_rows VALUES(2,NULL),(3,3) ON CONFLICT(id) DO NOTHING RETURNING *",
      "INSERT OR REPLACE INTO conflict_rows VALUES(2,NULL),(3,4) ON CONFLICT(id) DO UPDATE SET v=excluded.v RETURNING *",
      "INSERT OR IGNORE INTO conflict_rows VALUES(4,4),(1,5) ON CONFLICT(id) DO UPDATE SET v=NULL",
      "INSERT OR FAIL INTO conflict_rows VALUES(4,4),(1,5) ON CONFLICT(id) DO UPDATE SET v=-1",
      "INSERT OR FAIL INTO conflict_rows VALUES(4,4),(5,-1) ON CONFLICT(id) DO NOTHING",
      "INSERT OR FAIL INTO conflict_rows VALUES(6,6),(7,'bad') ON CONFLICT(id) DO NOTHING",
      "UPDATE OR FAIL conflict_rows SET v=CASE WHEN id=3 THEN NULL ELSE v+1 END",
      "BEGIN", "INSERT INTO conflict_rows VALUES(8,8)",
      "INSERT OR ROLLBACK INTO conflict_rows VALUES(9,9),(1,1)",
      "COMMIT", "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE policy_source(x INT)", "CREATE TABLE policy_target(x INT UNIQUE)",
      "INSERT INTO policy_target VALUES(1)",
      "CREATE TRIGGER policy_trigger AFTER INSERT ON policy_source BEGIN INSERT OR REPLACE INTO policy_target VALUES(new.x); END",
      "INSERT OR IGNORE INTO policy_source VALUES(1),(2)",
      "INSERT OR FAIL INTO policy_source VALUES(3),(1),(4)",
      "INSERT INTO policy_source VALUES(1)",
      "CREATE TRIGGER upsert_abort AFTER UPDATE ON conflict_rows BEGIN INSERT OR REPLACE INTO policy_target VALUES(1); END",
      "INSERT OR IGNORE INTO conflict_rows VALUES(1,2) ON CONFLICT(id) DO UPDATE SET v=excluded.v",
      "DROP TRIGGER upsert_abort",
      "UPDATE OR REPLACE conflict_rows SET v=NULL WHERE id=1 RETURNING *",
      "CREATE TABLE default_type(x INT NOT NULL DEFAULT '7') STRICT",
      "INSERT OR REPLACE INTO default_type VALUES(NULL) RETURNING *",
      "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE generated_rows(id INTEGER PRIMARY KEY,a INT,b INT GENERATED ALWAYS AS(a*2) STORED,c TEXT AS(b+1) VIRTUAL,d REAL AS(a/2.0),label TEXT AS('λ😀'||a) UNIQUE)",
      "INSERT INTO generated_rows(a) VALUES(2),(3),(NULL) RETURNING *",
      "CREATE INDEX generated_index ON generated_rows(c DESC,d) WHERE b>0",
      "UPDATE generated_rows SET a=a+2 WHERE id<3 RETURNING *",
      "INSERT INTO generated_rows(id,a,b) VALUES(9,9,18)",
      "UPDATE generated_rows SET b=1",
      "INSERT INTO generated_rows VALUES(10,10)",
      "INSERT INTO generated_rows(a) VALUES(4) ON CONFLICT(label) DO UPDATE SET a=excluded.a+10 RETURNING *",
      "INSERT INTO generated_rows(a) VALUES(7) ON CONFLICT(label) DO UPDATE SET b=1",
      "PRAGMA table_info(generated_rows)", "PRAGMA table_xinfo(generated_rows)",
      "ALTER TABLE generated_rows ADD extra TEXT AS(label||c)",
      "ALTER TABLE generated_rows ADD invalid INT AS(a+1) STORED",
      "ALTER TABLE generated_rows RENAME COLUMN a TO source",
      "UPDATE generated_rows SET source=source+1 WHERE id=2 RETURNING *",
      "ALTER TABLE generated_rows DROP source", "ALTER TABLE generated_rows DROP extra",
      "DROP INDEX generated_index", "ALTER TABLE generated_rows DROP d",
      "CREATE TABLE generated_wr(k TEXT PRIMARY KEY,a INT,b INT AS(a+1) STORED,c TEXT AS(b||k)) WITHOUT ROWID",
      "INSERT INTO generated_wr VALUES('x',1),('y',2)",
      "CREATE INDEX generated_wr_key ON generated_wr(c)",
      "UPDATE generated_wr SET a=a+1 RETURNING *",
      "CREATE TABLE generated_chain(a INT,b INT AS(c+1),c INT AS(a*2) STORED)",
      "INSERT INTO generated_chain VALUES(3) RETURNING *",
      "CREATE TABLE generated_strict(a TEXT,b INT AS(a),c REAL AS(b),kind TEXT AS(typeof(c))) STRICT",
      "INSERT INTO generated_strict VALUES('3') RETURNING *",
      "INSERT OR IGNORE INTO generated_strict VALUES('bad')",
      "CREATE TABLE generated_checks(a INT,b INT AS(a+1) CHECK(b<10) NOT NULL)",
      "INSERT OR IGNORE INTO generated_checks VALUES(1),(10),(NULL) RETURNING *",
      "CREATE TABLE invalid_gen_default(a,b AS(a) DEFAULT 1)",
      "CREATE TABLE invalid_gen_primary(a,b AS(a) PRIMARY KEY)",
      "CREATE TABLE invalid_gen_loop(a,b AS(c),c AS(b))",
      "CREATE TABLE invalid_gen_only(a AS(1))",
      "CREATE TABLE invalid_gen_sub(a,b AS((SELECT 1)))",
      "CREATE TABLE invalid_gen_param(a,b AS(?))",
      "CREATE TABLE invalid_gen_rowid(a,b AS(rowid))",
      "CREATE TABLE invalid_gen_agg(a,b AS(sum(a)))",
      "CREATE TABLE invalid_gen_clock(a,b AS(CURRENT_TIMESTAMP))",
      "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE schema_policy(id INTEGER PRIMARY KEY ON CONFLICT REPLACE,a INT UNIQUE ON CONFLICT IGNORE,b INT NOT NULL ON CONFLICT REPLACE DEFAULT 7)",
      "INSERT INTO schema_policy VALUES(1,1,NULL),(2,1,2),(3,3,3) RETURNING *",
      "INSERT INTO schema_policy VALUES(1,4,4) RETURNING *",
      "INSERT OR ABORT INTO schema_policy VALUES(5,3,5)",
      "INSERT OR REPLACE INTO schema_policy VALUES(5,3,NULL) RETURNING *",
      "CREATE TABLE schema_fail(a INT UNIQUE ON CONFLICT FAIL,b TEXT NOT NULL ON CONFLICT IGNORE)",
      "INSERT INTO schema_fail VALUES(1,'a'),(2,NULL),(3,'c'),(1,'stop'),(4,'d')",
      "UPDATE schema_fail SET a=1 WHERE a=3",
      "CREATE TABLE schema_wr(a INT,b INT,PRIMARY KEY(a,b) ON CONFLICT REPLACE) WITHOUT ROWID",
      "INSERT INTO schema_wr VALUES(1,2),(1,2),(1,3)",
      "CREATE TABLE schema_multi(a INT,b INT,UNIQUE(a,b) ON CONFLICT IGNORE)",
      "INSERT INTO schema_multi VALUES(1,2),(1,2),(2,3)",
      "CREATE TABLE schema_rollback(a INT UNIQUE ON CONFLICT ROLLBACK)",
      "INSERT INTO schema_rollback VALUES(1)", "BEGIN", "INSERT INTO schema_fail VALUES(9,'rollback')",
      "INSERT INTO schema_rollback VALUES(2),(1)", "COMMIT",
      "CREATE TABLE replacement_audit(kind TEXT,id INT)",
      "CREATE TRIGGER replacement_before BEFORE DELETE ON schema_policy BEGIN INSERT INTO replacement_audit VALUES('before',old.id); END",
      "CREATE TRIGGER replacement_after AFTER DELETE ON schema_policy BEGIN INSERT INTO replacement_audit VALUES('after',old.id); END",
      "PRAGMA recursive_triggers=OFF", "INSERT INTO schema_policy VALUES(1,6,6)",
      "PRAGMA recursive_triggers=ON", "INSERT INTO schema_policy VALUES(1,7,7)",
      "UPDATE OR REPLACE schema_policy SET a=7 WHERE id=5 RETURNING *",
      "PRAGMA recursive_triggers=OFF", "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE schema_duplicate(a UNIQUE,UNIQUE(a) ON CONFLICT IGNORE)",
      "INSERT INTO schema_duplicate VALUES(1),(1)",
      "CREATE TABLE invalid_duplicate(a UNIQUE ON CONFLICT FAIL,UNIQUE(a) ON CONFLICT IGNORE)",
      "CREATE TABLE schema_check(a,CHECK(a>0) ON CONFLICT IGNORE)",
      "INSERT INTO schema_check VALUES(1),(-1)",
      "PRAGMA recursive_triggers=ON",
      "CREATE TABLE replace_ignore(a INT UNIQUE)", "INSERT INTO replace_ignore VALUES(1)",
      "CREATE TRIGGER replace_skip BEFORE DELETE ON replace_ignore BEGIN SELECT RAISE(IGNORE); END",
      "INSERT OR REPLACE INTO replace_ignore VALUES(1),(2)",
      "DROP TRIGGER replace_skip",
      "CREATE TRIGGER replace_after_skip AFTER DELETE ON replace_ignore BEGIN SELECT RAISE(IGNORE); END",
      "INSERT OR REPLACE INTO replace_ignore VALUES(1),(2)",
      "PRAGMA recursive_triggers=OFF", "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE VIEW value_view(a,b) AS VALUES(1,'a'),(2,'λ😀')",
      "CREATE TABLE value_sink(a INT,b TEXT)",
      "INSERT INTO value_sink SELECT * FROM value_view RETURNING *",
      "CREATE TRIGGER value_guard BEFORE INSERT ON value_sink WHEN new.a<0 BEGIN VALUES(RAISE(ABORT,'negative')); END",
      "INSERT INTO value_sink VALUES(-1,'bad')",
      "CREATE TRIGGER value_audit AFTER INSERT ON value_sink BEGIN VALUES(new.a,new.b),(old.a,new.b); END",
      "INSERT INTO value_sink VALUES(3,'bad')", "DROP TRIGGER value_audit",
      "CREATE TRIGGER value_notify AFTER INSERT ON value_sink BEGIN VALUES(new.a,new.b),(new.a+1,new.b); END",
      "INSERT INTO value_sink VALUES(3,'ok') RETURNING *",
      "INSERT INTO value_sink WITH c(a,b) AS(VALUES(4,'four'),(5,'five')) SELECT * FROM c RETURNING *",
      "DROP VIEW value_view", "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE ctas_source(id INTEGER PRIMARY KEY,a VARCHAR(20) COLLATE NOCASE NOT NULL DEFAULT 'a',r REAL,n NUMERIC,b BLOB,g INT AS(id+1))",
      "INSERT INTO ctas_source(id,a,r,n,b) VALUES(1,'λ😀',2,3,X'00ff'),(2,'B',3.5,'4',NULL)",
      "CREATE TABLE ctas_copy AS SELECT * FROM ctas_source ORDER BY id DESC",
      "PRAGMA table_info(ctas_copy)",
      "CREATE TABLE ctas_empty AS SELECT a,r,n,b,id,g FROM ctas_source LIMIT 0",
      "PRAGMA table_info(ctas_empty)",
      "CREATE TABLE ctas_cast AS SELECT CAST(1 AS INTEGER) AS i,CAST(1 AS REAL) AS r,CAST(1 AS NUMERIC) AS n,CAST(1 AS TEXT) AS t,CAST(1 AS BLOB) AS b,1+1 AS expr",
      "PRAGMA table_info(ctas_cast)",
      "CREATE TABLE ctas_duplicate AS SELECT 1 AS x,2 AS X,3 AS 'x:1',4 AS ''",
      "PRAGMA table_info(ctas_duplicate)",
      "CREATE TABLE ctas_values AS VALUES(1,'one'),(2,'two')",
      "CREATE TABLE ctas_cte AS WITH c(x) AS(VALUES(3),(4)) SELECT x FROM c",
      "CREATE TABLE ctas_failed AS SELECT abs(-9223372036854775808)",
      "BEGIN", "CREATE TABLE ctas_rollback AS SELECT * FROM ctas_copy", "ROLLBACK",
      "CREATE TABLE shorthand(id INTEGER PRIMARY KEY,v INT UNIQUE)",
      "REPLACE INTO shorthand VALUES(1,1),(2,2) RETURNING *",
      "REPLACE INTO shorthand VALUES(3,2) RETURNING *",
      "REPLACE INTO shorthand(id,v) SELECT 1,3 ON CONFLICT(id) DO UPDATE SET v=excluded.v RETURNING *",
      "CREATE TRIGGER shorthand_trigger AFTER INSERT ON shorthand WHEN new.id=4 BEGIN REPLACE INTO shorthand VALUES(1,new.v+10); END",
      "REPLACE INTO shorthand VALUES(4,4)", "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE aggregate_rows(v TEXT COLLATE NOCASE,k INT)",
      "INSERT INTO aggregate_rows VALUES('a',3),('A',1),('λ😀',2),(NULL,0)",
      "CREATE TABLE aggregate_copy AS SELECT string_agg(v,'|' ORDER BY k) AS value,group_concat(DISTINCT v ORDER BY v) AS distinct_value FROM aggregate_rows",
      "CREATE VIEW aggregate_view AS SELECT group_concat(v ORDER BY k DESC) AS value FROM aggregate_rows",
      "INSERT INTO aggregate_copy(value) SELECT value FROM aggregate_view",
      "CREATE TRIGGER aggregate_guard BEFORE INSERT ON aggregate_rows BEGIN SELECT string_agg(v,'|' ORDER BY k) FROM aggregate_rows; END",
      "INSERT INTO aggregate_rows VALUES('b',4)", "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE rename_source(id INTEGER PRIMARY KEY,v INT,rename_source TEXT)",
      "CREATE TABLE rename_events(id INT,v INT)", "CREATE TABLE rename_audit(v INT)",
      "INSERT INTO rename_source VALUES(1,1,'one'),(2,2,'two')",
      "CREATE VIEW rename_plain AS SELECT rename_source.* FROM rename_source",
      "CREATE VIEW rename_nested AS SELECT a.id,(SELECT count(*) FROM rename_source WHERE rename_source.id<=a.id) AS n FROM rename_source AS a",
      "CREATE VIEW rename_shadow AS WITH rename_source(id) AS(VALUES(99)) SELECT rename_source.id FROM rename_source",
      "CREATE VIEW rename_alias AS SELECT rename_source.id,'rename_source' AS rename_source FROM rename_plain AS rename_source",
      "CREATE VIEW rename_agg AS SELECT string_agg(rename_source.v,'|' ORDER BY rename_source.id) AS value FROM rename_source",
      "CREATE TRIGGER rename_source AFTER UPDATE OF rename_source ON rename_source BEGIN INSERT INTO rename_audit VALUES(new.v); END",
      "CREATE TRIGGER rename_route AFTER INSERT ON rename_events WHEN EXISTS(SELECT 1 FROM rename_source) BEGIN INSERT INTO rename_source(id,v) VALUES(new.id,new.v) ON CONFLICT(id) DO UPDATE SET v=rename_source.v+excluded.v; END",
      "CREATE VIEW rename_edit AS SELECT * FROM rename_source",
      "CREATE TRIGGER rename_edit_insert INSTEAD OF INSERT ON rename_edit BEGIN REPLACE INTO rename_source VALUES(new.id,new.v,new.rename_source); END",
      "ALTER TABLE rename_source RENAME TO renamed_source",
      "SELECT * FROM rename_plain ORDER BY id", "SELECT * FROM rename_nested ORDER BY id",
      "SELECT * FROM rename_shadow", "SELECT * FROM rename_alias ORDER BY id", "SELECT * FROM rename_agg",
      "INSERT INTO rename_events VALUES(1,2),(1,3)",
      "UPDATE renamed_source SET rename_source='rename_source' WHERE id=1",
      "INSERT INTO rename_edit VALUES(3,7,'three')",
      "SELECT name,tbl_name FROM sqlite_schema WHERE name='rename_source' AND type='trigger'",
      "BEGIN", "ALTER TABLE renamed_source RENAME TO rename_undone", "SELECT * FROM rename_agg", "ROLLBACK",
      "SELECT * FROM rename_plain ORDER BY id",
      "CREATE TABLE \"odd.name\"(x INT)", "INSERT INTO \"odd.name\" VALUES(3)",
      "CREATE VIEW rename_quoted AS SELECT \"odd.name\".* FROM \"odd.name\"",
      "ALTER TABLE \"odd.name\" RENAME TO \"new name\"", "SELECT * FROM rename_quoted",
      "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE VIEW rename_invalid_qualifier AS SELECT renamed_source.id FROM renamed_source AS a",
      "ALTER TABLE renamed_source RENAME TO invalid_target", "DROP VIEW rename_invalid_qualifier",
      "CREATE VIEW rename_invalid_wildcard AS SELECT renamed_source.* FROM renamed_source AS a",
      "ALTER TABLE renamed_source RENAME TO invalid_target", "DROP VIEW rename_invalid_wildcard"
    ]
    statements += [
      "CREATE TABLE column_source(id INTEGER PRIMARY KEY,a INT UNIQUE,b TEXT,spare INT)",
      "INSERT INTO column_source VALUES(1,2,'one',0),(2,4,'two',0)",
      "CREATE TABLE column_other(id INT,z INT)","INSERT INTO column_other VALUES(1,7)",
      "CREATE VIEW column_plain AS SELECT column_source.a,column_source.b FROM column_source",
      "CREATE VIEW column_fixed(label) AS SELECT a FROM column_source",
      "CREATE VIEW column_cte AS WITH c(value) AS(SELECT a FROM column_source) SELECT value FROM c",
      "CREATE VIEW column_alias AS SELECT a AS a,b FROM column_source ORDER BY a",
      "CREATE VIEW column_correlated AS SELECT x.id,(SELECT count(*) FROM column_source y WHERE y.a<=x.a) AS n FROM column_source x",
      "CREATE VIEW column_joined AS SELECT column_source.a,column_other.z FROM column_source JOIN column_other ON column_source.id=column_other.id",
      "CREATE TABLE column_events(id INT,v INT)","CREATE TABLE column_audit(old_value INT,new_value INT)",
      "CREATE TRIGGER column_observe AFTER UPDATE OF a ON column_source WHEN old.a!=new.a BEGIN INSERT INTO column_audit VALUES(old.a,new.a); END",
      "CREATE TRIGGER column_route AFTER INSERT ON column_events BEGIN INSERT INTO column_source(id,a) VALUES(new.id,new.v) ON CONFLICT(id) DO UPDATE SET a=a+excluded.a; END",
      "ALTER TABLE column_source RENAME a TO value",
      "SELECT * FROM column_plain ORDER BY value", "SELECT * FROM column_fixed ORDER BY label",
      "SELECT * FROM column_cte ORDER BY value", "SELECT * FROM column_alias", "SELECT * FROM column_correlated ORDER BY id", "SELECT * FROM column_joined",
      "INSERT INTO column_events VALUES(1,3),(1,1)", "SELECT * FROM column_audit",
      "ALTER TABLE column_source DROP spare", "ALTER TABLE column_source DROP b",
      "ALTER TABLE column_source RENAME value TO VALUE", "SELECT * FROM column_plain ORDER BY VALUE",
      "BEGIN", "ALTER TABLE column_source RENAME VALUE TO undone", "ROLLBACK",
      "CREATE TABLE column_chain(a INT,b INT)","INSERT INTO column_chain VALUES(1,2)",
      "CREATE VIEW column_v AS SELECT a FROM column_chain", "CREATE VIEW column_w AS SELECT a FROM column_v",
      "ALTER TABLE column_chain RENAME a TO value", "DROP VIEW column_w", "DROP VIEW column_v",
      "CREATE VIEW column_v AS SELECT a AS a FROM column_chain", "CREATE VIEW column_w AS SELECT a FROM column_v",
      "ALTER TABLE column_chain RENAME a TO value", "SELECT * FROM column_w",
      "CREATE TABLE column_quote(\"a.b\" INT,spare INT)","INSERT INTO column_quote VALUES(3,0)",
      "CREATE VIEW column_quoted AS SELECT column_quote.\"a.b\" AS fixed FROM column_quote",
      "CREATE VIEW column_computed AS SELECT column_quote.\"a.b\"+1 FROM column_quote",
      "ALTER TABLE column_quote RENAME \"a.b\" TO \"new value\"", "SELECT * FROM column_computed", "SELECT * FROM column_quoted",
      "ALTER TABLE column_quote DROP spare",
      "CREATE TABLE unary_default_guard(a INT DEFAULT(-abs(-9223372036854775808)),b INT)",
      "CREATE VIEW unary_default_view AS SELECT b FROM unary_default_guard",
      "ALTER TABLE unary_default_guard RENAME b TO value", "INSERT INTO unary_default_guard DEFAULT VALUES",
      "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE window_dependency(a INT,b INT)","INSERT INTO window_dependency VALUES(1,2)",
      "CREATE VIEW window_unused AS SELECT b FROM window_dependency WINDOW w AS(ORDER BY a)",
      "CREATE VIEW window_table AS SELECT b FROM window_dependency WINDOW w AS(ORDER BY window_dependency.a)",
      "ALTER TABLE window_dependency RENAME a TO value", "SELECT * FROM window_unused",
      "ALTER TABLE window_dependency DROP value", "SELECT sql FROM sqlite_schema WHERE name='window_unused'",
      "ALTER TABLE window_dependency RENAME TO window_named", "SELECT sql FROM sqlite_schema WHERE name='window_table'",
      "PRAGMA integrity_check"
    ]
    for i,(join,target) in enumerate([('', 'l'),('LEFT','l'),('RIGHT','l'),('FULL','l'),('', 'r'),('LEFT','r'),('RIGHT','r'),('FULL','r')]):
      left,right,view=f'natural_l{i}',f'natural_r{i}',f'natural_v{i}'
      statements += [f"CREATE TABLE {left}(a INT,l TEXT)", f"CREATE TABLE {right}(a INT,r TEXT)",
        f"INSERT INTO {left} VALUES(1,'t1'),(2,'t2')",f"INSERT INTO {right} VALUES(1,'u1'),(3,'u3')",
        f"CREATE VIEW {view} AS SELECT a FROM {left} NATURAL {join} JOIN {right}",
        f"ALTER TABLE {left if target=='l' else right} RENAME a TO renamed", f"SELECT * FROM {view} ORDER BY 1"]
    statements += ["CREATE TABLE using_l(a INT,b INT)","CREATE TABLE using_r(a INT,c INT)",
      "CREATE VIEW using_view AS SELECT a FROM using_l JOIN using_r USING(a)",
      "ALTER TABLE using_l RENAME a TO renamed", "DROP VIEW using_view",
      "CREATE VIEW using_view AS SELECT a FROM using_l x JOIN using_l y USING(a)",
      "ALTER TABLE using_l RENAME a TO renamed", "DROP VIEW using_view",
      "CREATE VIEW using_view AS SELECT a FROM using_l x NATURAL FULL JOIN using_l y",
      "ALTER TABLE using_l RENAME a TO renamed", "DROP VIEW using_view", "PRAGMA integrity_check"]
    statements += [
      "CREATE TABLE rowid_left(a INT,spare INT)","CREATE TABLE rowid_right(a INT,rowid INT)",
      "INSERT INTO rowid_left VALUES(1,0)","INSERT INTO rowid_right VALUES(1,7)",
      "CREATE VIEW rowid_join AS SELECT a,rowid FROM rowid_left NATURAL JOIN rowid_right",
      "ALTER TABLE rowid_left RENAME spare TO unused", "ALTER TABLE rowid_left DROP unused",
      "SELECT * FROM rowid_join", "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE grouped_left(a INT,spare INT)", "CREATE TABLE grouped_right(a INT)", "CREATE TABLE grouped_other(a INT)",
      "INSERT INTO grouped_left VALUES(1,7)", "INSERT INTO grouped_right VALUES(1)", "INSERT INTO grouped_other VALUES(2)"
    ]
    for source in ["grouped_left JOIN grouped_right USING(a),grouped_other", "grouped_left NATURAL JOIN grouped_right CROSS JOIN grouped_other", "grouped_left FULL JOIN grouped_right USING(a),grouped_other", "grouped_left,grouped_right JOIN grouped_other USING(a)", "grouped_left,grouped_right FULL JOIN grouped_other USING(a)"]:
      statements += [f"CREATE VIEW grouped_bad AS SELECT a FROM {source}", "ALTER TABLE grouped_left RENAME spare TO other", "ALTER TABLE grouped_left DROP spare", "DROP VIEW grouped_bad"]
    statements += [
      "CREATE VIEW grouped_good AS SELECT grouped_left.spare FROM grouped_left JOIN grouped_right USING(a),grouped_other",
      "ALTER TABLE grouped_left RENAME spare TO other", "SELECT * FROM grouped_good", "DROP VIEW grouped_good"
    ]
    for i,declaration in enumerate(["", "(z,z)"]):
      statements += [f"CREATE VIEW duplicate_cte{i} AS WITH q{declaration} AS(SELECT a AS z,other AS z FROM grouped_left) SELECT \"z:1\" FROM q"]
    statements += ["ALTER TABLE grouped_left RENAME other TO spare", "SELECT * FROM duplicate_cte0", "SELECT * FROM duplicate_cte1", "ALTER TABLE grouped_left DROP spare", "PRAGMA integrity_check"]
    statements += [
      "CREATE TABLE qualified_alter(a INT,spare INT)", "INSERT INTO qualified_alter VALUES(1,7)",
      "CREATE VIEW qualified_view AS WITH qualified_alter AS(SELECT 99 AS a) SELECT main.qualified_alter.a AS fixed FROM main.qualified_alter",
      "CREATE VIEW qualified_alias AS SELECT main.q.a AS fixed FROM qualified_alter q",
      "ALTER TABLE qualified_alter RENAME a TO value", "SELECT * FROM qualified_view", "SELECT * FROM qualified_alias",
      "ALTER TABLE qualified_alter RENAME TO qualified_renamed", "SELECT * FROM qualified_view", "SELECT * FROM qualified_alias",
      "ALTER TABLE qualified_renamed DROP spare", "ALTER TABLE qualified_renamed DROP value", "PRAGMA integrity_check"
    ]
    statements += [
      "CREATE TABLE on_alias_left(a INT,spare INT)", "CREATE TABLE on_alias_right(b INT)",
      "INSERT INTO on_alias_left VALUES(1,0),(3,0)", "INSERT INTO on_alias_right VALUES(2),(9)",
      "CREATE VIEW on_alias_view AS SELECT a+1 AS next FROM on_alias_left JOIN on_alias_right ON next=b",
      "ALTER TABLE on_alias_left RENAME a TO value", "ALTER TABLE on_alias_left DROP spare", "SELECT * FROM on_alias_view",
      "CREATE VIEW on_alias_invalid AS SELECT sum(value) AS total FROM on_alias_left JOIN on_alias_right ON total=b",
      "ALTER TABLE on_alias_left RENAME value TO renamed", "DROP VIEW on_alias_invalid", "PRAGMA integrity_check"
    ]
    bound_parameters = {
      "INSERT INTO named_rows VALUES(:id,:v) RETURNING :id,id,:v,v": [1,7],
      "UPDATE named_rows SET v=:v WHERE id=:id RETURNING :v,v,:id": [8,1],
      "INSERT INTO named_rows SELECT :id,:v RETURNING :id,:v": [2,9],
      "INSERT INTO named_rows SELECT :id,:v ON CONFLICT(id) DO UPDATE SET v=:v+1 RETURNING :id,:v,v": [2,10],
      "DELETE FROM named_rows WHERE id=@id RETURNING @id,v": [1],
      "CREATE TABLE named_copy AS SELECT :x AS x,CAST(:x AS INT) AS y": [12],
      "INSERT INTO named_rows VALUES(:id,:v) RETURNING :id": [],
    }
    statements += ["CREATE TABLE named_rows(id INTEGER PRIMARY KEY,v INT)"] + list(bound_parameters) + [
      "CREATE TABLE invalid_check_parameter(x CHECK(x>:v))",
      "CREATE VIEW invalid_view_parameter AS SELECT :v",
      "CREATE INDEX invalid_index_parameter ON named_rows(:v)",
      "CREATE TRIGGER invalid_trigger_parameter AFTER INSERT ON named_rows BEGIN SELECT :v; END",
      "PRAGMA integrity_check"
    ]
    for encoding in [1,2,3]:
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'operations.json').write_text(json.dumps([{'sql':sql,'parameters':bound_parameters.get(sql,[]),'query':sql.split()[0].upper() in ['SELECT','WITH','VALUES'] or '=' not in sql and any(sql.upper().startswith('PRAGMA '+name) for name in ['FOREIGN_KEY_CHECK','INTEGRITY_CHECK','QUICK_CHECK','INDEX_INFO','INDEX_XINFO','INDEX_LIST','RECURSIVE_TRIGGERS','TABLE_INFO','TABLE_XINFO'])} for sql in statements]))
            subprocess.run(['dart','--suppress-analytics','run','tool/export_schema.dart',directory,str(encoding)],cwd=ROOT.parents[1],check=True)
            with sqlite3.connect(root/'reference.db',isolation_level=None) as ref:
                ref.execute('pragma page_size=512')
                ref.execute("pragma encoding='"+{1:'UTF-8',2:'UTF-16le',3:'UTF-16be'}[encoding]+"'")
                for i,sql in enumerate(statements):
                    error=None
                    returned=None
                    try:
                        cursor=ref.execute(sql,bound_parameters.get(sql,[]))
                        if cursor.description is not None:returned={'columns':[c[0] for c in cursor.description],'rows':[[encode(v) for v in row] for row in cursor.fetchall()]}
                    except sqlite3.Error as exc:error=str(exc)
                    metadata=json.loads((root/f'{i}.json').read_text())
                    if (error is None)!=(metadata['error'] is None):
                        raise RuntimeError(f'Error mismatch at {i}: {sql}; SQLite={error}; Dart={metadata}')
                    if returned!=metadata['returning']:raise RuntimeError(f'RETURNING mismatch at {i}: {sql}; SQLite={returned}; Dart={metadata}')
                    if error is None and sql.split()[0].upper() in ['INSERT','REPLACE','UPDATE','DELETE'] and cursor.rowcount!=metadata['changes']:raise RuntimeError(f'Change-count mismatch at {i}: {sql}; SQLite={cursor.rowcount}; Dart={metadata}')
                    with sqlite3.connect(f'file:{root/i.__str__()}.db?mode=ro',uri=True) as actual:
                        for pragma in ['user_version','application_id']:
                            if actual.execute('pragma '+pragma).fetchall()!=ref.execute('pragma '+pragma).fetchall():raise RuntimeError(f'Header {pragma} differs at {i}')
                        try: integrity=actual.execute('pragma integrity_check').fetchall()
                        except sqlite3.Error as exc: raise RuntimeError(f'Integrity error at {i}: {sql}; {exc}') from exc
                        if integrity!=[('ok',)]:raise RuntimeError(f'Integrity failure at {i}: {sql}; {integrity}')
                        names=[r[0] for r in ref.execute("select name from sqlite_schema where type='table' order by name")]
                        if names!=[r[0] for r in actual.execute("select name from sqlite_schema where type='table' order by name")]:raise RuntimeError(f'Schema names differ at {i}')
                        for name in names:
                            escaped='"'+name.replace('"','""')+'"'
                            expected=ref.execute(f'select * from {escaped}').fetchall();rows=actual.execute(f'select * from {escaped}').fetchall()
                            if sorted(expected,key=repr)!=sorted(rows,key=repr):raise RuntimeError(f'Rows differ at {i}: {name}; SQLite={expected!r}; Dart={rows!r}')
                            if ref.execute(f'pragma index_list({escaped})').fetchall()!=actual.execute(f'pragma index_list({escaped})').fetchall():raise RuntimeError(f'Index metadata differs at {i}: {name}')
                            if ref.execute(f'pragma foreign_key_list({escaped})').fetchall()!=actual.execute(f'pragma foreign_key_list({escaped})').fetchall():raise RuntimeError(f'Foreign-key metadata differs at {i}: {name}')
            print(f'Pinned SQLite verified {len(statements)} Dart schema/index/constraint mutation snapshots; encoding={encoding}')


if __name__=='__main__':main()
