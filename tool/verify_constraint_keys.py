"""Cross-open constraint-index sort/collation semantics against the pinned oracle."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def operations():
    statements = ['PRAGMA foreign_keys=ON']
    for i, (declaration, suffix) in enumerate([
        ('UNIQUE(a COLLATE NOCASE DESC)', ''),
        ('UNIQUE(a COLLATE RTRIM ASC)', ''),
        ('UNIQUE(a COLLATE BINARY DESC)', ''),
        ('UNIQUE(a DESC),PRIMARY KEY(a ASC)', ''),
        ('PRIMARY KEY(a COLLATE NOCASE DESC),UNIQUE(a COLLATE BINARY)', ''),
        ('UNIQUE(a COLLATE NOCASE),PRIMARY KEY(a COLLATE BINARY DESC)', ''),
        ('PRIMARY KEY(a COLLATE NOCASE DESC,b ASC)', ' WITHOUT ROWID'),
        ('UNIQUE(a DESC),PRIMARY KEY(a ASC)', ' WITHOUT ROWID'),
        ('UNIQUE(a COLLATE NOCASE),PRIMARY KEY(a COLLATE BINARY DESC)', ' WITHOUT ROWID'),
    ]):
        table = f'key_{i}'
        statements += [f'CREATE TABLE {table}(a TEXT COLLATE NOCASE,b INT,c TEXT,{declaration}){suffix}',
            f'PRAGMA index_list({table})', f'PRAGMA index_xinfo({table})',
            f"INSERT INTO {table} VALUES('a',1,'first'),('B',2,'second')",
            f"INSERT INTO {table} VALUES('A',1,'duplicate')",
            f"INSERT INTO {table} VALUES('a ',1,'trimmed')",
            f'SELECT * FROM {table} ORDER BY a COLLATE BINARY,b',
            f'CREATE INDEX {table}_a ON {table}(a COLLATE BINARY DESC)',
            f'PRAGMA index_xinfo({table}_a)',
            f'PRAGMA index_xinfo(sqlite_autoindex_{table}_1)',
            f'PRAGMA index_xinfo(sqlite_autoindex_{table}_2)',
            f"UPDATE {table} SET c='updated' WHERE b=2",
            f'PRAGMA integrity_check']
    statements += ['CREATE TABLE big(a TEXT,b INT,c BLOB,PRIMARY KEY(a COLLATE NOCASE DESC,b)) WITHOUT ROWID',
        'CREATE INDEX big_a ON big(a COLLATE BINARY)',
        'CREATE INDEX big_c ON big(length(c) DESC)']
    statements += [f"INSERT INTO big VALUES('k{i % 7}',{i},zeroblob({100 + i % 13}))" for i in range(90)]
    statements += ["INSERT INTO big VALUES('K0',0,X'11') ON CONFLICT(a COLLATE NOCASE,b) DO UPDATE SET c=excluded.c",
        "INSERT INTO big VALUES('K0',0,X'22') ON CONFLICT(a COLLATE BINARY,b) DO NOTHING",
        'PRAGMA index_xinfo(big)', 'PRAGMA index_xinfo(big_a)', 'PRAGMA index_xinfo(big_c)',
        'SELECT a,b,length(c) FROM big ORDER BY a COLLATE BINARY,b',
        'ALTER TABLE big RENAME a TO label','PRAGMA index_xinfo(big)','PRAGMA integrity_check']
    for i, suffix in enumerate(['', ' WITHOUT ROWID']):
        parent, child = f'p{i}', f'c{i}'
        statements += [f'CREATE TABLE {parent}(a TEXT,b INT,PRIMARY KEY(a COLLATE NOCASE DESC)){suffix}',
            f"INSERT INTO {parent} VALUES('a',1)",
            f'CREATE TABLE {child}(a REFERENCES {parent} ON UPDATE CASCADE ON DELETE CASCADE)',
            f"INSERT INTO {child} VALUES('A')",f'PRAGMA foreign_key_check({child})',
            f'SELECT * FROM {child}',
            f'DROP TABLE {child}',f'CREATE TABLE {child}(a REFERENCES {parent}(a))',
            f"INSERT INTO {child} VALUES('b')",f'DROP TABLE {child}']
    statements += ['CREATE TABLE many(k INT PRIMARY KEY,' + ','.join(f'c{i} INT UNIQUE' for i in range(12)) + ') WITHOUT ROWID',
        'CREATE INDEX many_added ON many(c0)','PRAGMA index_list(many)']
    statements += ['CREATE TABLE integer_alias(a INTEGER,b TEXT,PRIMARY KEY(a COLLATE NOCASE DESC))',
        "INSERT INTO integer_alias(b) VALUES('one'),('two')",'PRAGMA index_list(integer_alias)',
        'SELECT * FROM integer_alias ORDER BY a',
        'CREATE TABLE late_collation(a TEXT UNIQUE COLLATE NOCASE,b TEXT)',
        "INSERT INTO late_collation VALUES('a','one')","INSERT INTO late_collation VALUES('A','two')",
        'PRAGMA index_xinfo(sqlite_autoindex_late_collation_1)']
    statements += ['CREATE TABLE invalid_parent(a TEXT UNIQUE,b INT,c INT)',
        'CREATE TABLE invalid_child(a REFERENCES invalid_parent(b),b INT)',
        'INSERT INTO invalid_child VALUES(NULL,NULL)',
        'UPDATE invalid_child SET a=NULL','UPDATE invalid_child SET b=NULL',
        'UPDATE invalid_child SET rowid=rowid','DELETE FROM invalid_child',
        'UPDATE invalid_parent SET b=NULL','UPDATE invalid_parent SET a=NULL',
        'UPDATE invalid_parent SET c=NULL','DELETE FROM invalid_parent',
        'INSERT OR REPLACE INTO invalid_parent VALUES(NULL,NULL,NULL)',
        'UPDATE OR REPLACE invalid_parent SET a=NULL',
        'UPDATE OR REPLACE invalid_parent SET c=NULL',
        'INSERT INTO invalid_parent VALUES(NULL,NULL,NULL) ON CONFLICT(a) DO UPDATE SET b=1',
        'INSERT INTO invalid_parent VALUES(NULL,NULL,NULL) ON CONFLICT(a) DO UPDATE SET a=1',
        'DROP TABLE invalid_child',
        'CREATE TABLE invalid_child(a REFERENCES absent,b INT)',
        'INSERT INTO invalid_child VALUES(NULL,NULL)',
        'UPDATE invalid_child SET b=NULL',
        'DROP TABLE invalid_child']
    statements += [
        'CREATE TABLE invalid(a,UNIQUE(missing DESC))',
        'CREATE TABLE invalid(a,UNIQUE(a COLLATE missing))',
        'CREATE TABLE invalid(a,PRIMARY KEY(a COLLATE missing DESC))',
        'CREATE TABLE invalid(a,FOREIGN KEY(a DESC) REFERENCES p(a))',
        'CREATE TABLE invalid(a REFERENCES p(a DESC))',
        'CREATE TABLE invalid(a,UNIQUE(a) ON CONFLICT IGNORE,UNIQUE(a DESC) ON CONFLICT REPLACE)',
        'PRAGMA integrity_check']
    return statements


def probe_native_parent_collation_quirk():
    # The pinned engine uses indexed PK collation for implicit child lookups,
    # but declared column collation for parent-action matching. It can therefore
    # leave orphaned children. The Dart engine explicitly rejects this parent
    # action shape; constraint_key_test.dart verifies atomic rejection.
    for suffix in ['', ' WITHOUT ROWID']:
        with sqlite3.connect(':memory:', isolation_level=None) as reference:
            reference.execute('PRAGMA foreign_keys=ON')
            reference.execute('CREATE TABLE p(a TEXT,PRIMARY KEY(a COLLATE NOCASE))' + suffix)
            reference.execute('CREATE TABLE c(a REFERENCES p ON UPDATE CASCADE)')
            reference.execute("INSERT INTO p VALUES('a')")
            reference.execute("INSERT INTO c VALUES('A')")
            assert not reference.execute('PRAGMA foreign_key_check').fetchall()
            reference.execute("UPDATE p SET a='b'")
            assert reference.execute('SELECT * FROM c').fetchall() == [('A',)]
            assert reference.execute('PRAGMA foreign_key_check').fetchall() == [('c', 1, 'p', 0)]


def probe_native_repeated_primary_keys():
    # Native physical key layouts for repeated terms differ between ordinary
    # and WITHOUT ROWID tables. The engine currently rejects these declarations
    # atomically instead of constructing an incompatible image.
    for suffix in ['', ' WITHOUT ROWID']:
        with sqlite3.connect(':memory:') as reference:
            reference.execute('CREATE TABLE p(a TEXT,b INT,PRIMARY KEY(a,a))' + suffix)
            assert reference.execute('PRAGMA table_info(p)').fetchall()[0][-1] == 1
            keys = reference.execute('PRAGMA index_info(sqlite_autoindex_p_1)').fetchall()
            assert len(keys) == (1 if suffix else 2)


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as reference:
        assert reference.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
        assert sorted(r[0] for r in reference.execute('PRAGMA compile_options')) == manifest['compile_options']
    probe_native_parent_collation_quirk()
    probe_native_repeated_primary_keys()
    statements = operations()
    for encoding in [1, 2, 3]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'operations.json').write_text(json.dumps([{'sql': sql, 'parameters': [],
                'query': sql.split()[0].upper() == 'SELECT' or sql.upper().startswith('PRAGMA') and '=' not in sql} for sql in statements]))
            subprocess.run(['dart', '--suppress-analytics', 'run', 'tool/export_schema.dart',
                temporary, str(encoding)], cwd=ROOT.parents[1], check=True)
            with sqlite3.connect(root / 'reference.db', isolation_level=None) as reference:
                reference.execute('PRAGMA page_size=512')
                reference.execute("PRAGMA encoding='" + {1:'UTF-8',2:'UTF-16le',3:'UTF-16be'}[encoding] + "'")
                reference.execute('PRAGMA foreign_keys=ON')
                for i, sql in enumerate(statements):
                    expected_error = None
                    expected = None
                    try:
                        cursor = reference.execute(sql)
                        if cursor.description:
                            expected = {'columns': [c[0] for c in cursor.description],
                                'rows': [[encode(v) for v in row] for row in cursor.fetchall()]}
                    except sqlite3.Error as error:
                        expected_error = str(error)
                    actual = json.loads((root / f'{i}.json').read_text())
                    if (expected_error is None) != (actual['error'] is None):
                        raise RuntimeError(f'{encoding} {i} {sql}: SQLite {expected_error}; Dart {actual}')
                    if actual['returning'] != expected:
                        raise RuntimeError(f'{encoding} {i} {sql}: SQLite {expected}; Dart {actual}')
                    if expected_error is None and sql.split()[0].upper() in ['INSERT','UPDATE','DELETE'] and cursor.rowcount != actual['changes']:
                        raise RuntimeError(f'{encoding} {i} {sql}: change-count mismatch')
                    with sqlite3.connect(f'file:{root / str(i)}.db?mode=ro', uri=True) as image:
                        if image.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                            raise RuntimeError(f'{encoding} {i} {sql}: corrupt Dart image')
                        for (table,) in reference.execute("SELECT name FROM sqlite_schema WHERE type='table'").fetchall():
                            escaped = '"' + table.replace('"','""') + '"'
                            if sorted(reference.execute(f'SELECT * FROM {escaped}').fetchall(), key=repr) != sorted(image.execute(f'SELECT * FROM {escaped}').fetchall(), key=repr):
                                raise RuntimeError(f'{encoding} {i} {sql}: rows mismatch in {table}; SQLite={reference.execute(f"SELECT * FROM {escaped}").fetchall()}; Dart={image.execute(f"SELECT * FROM {escaped}").fetchall()}')
                            expected_indexes = reference.execute(f'PRAGMA index_list({escaped})').fetchall()
                            if expected_indexes != image.execute(f'PRAGMA index_list({escaped})').fetchall():
                                raise RuntimeError(f'{encoding} {i} {sql}: index_list mismatch in {table}')
                            for index in expected_indexes:
                                name = '"' + index[1].replace('"','""') + '"'
                                if reference.execute(f'PRAGMA index_xinfo({name})').fetchall() != image.execute(f'PRAGMA index_xinfo({name})').fetchall():
                                    raise RuntimeError(f'{encoding} {i} {sql}: index_xinfo mismatch in {name}')
            print(f'Pinned constraint keys agree: {len(statements)} cross-open/integrity snapshots, encoding={encoding}; '
                  'orphan-producing parent-collation quirk and repeated PK terms explicitly guarded')


if __name__ == '__main__':
    main()
