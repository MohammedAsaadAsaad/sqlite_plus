"""Cross-open Dart-written files and compare each mutation to pinned SQLite."""
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
from generate_fixtures import PIN, ROOT


def main(transactions=False):
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as c:
        if c.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(r[0] for r in c.execute('pragma compile_options')) != manifest['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    operations = [
        {'sql': 'INSERT INTO notes(value,n) VALUES(?,?),(?,?)',
         'parameters': ['overflow-λ😀' * 3000, 7, 'short', 8]},
        {'sql': 'UPDATE notes SET value=?,n=n+1 WHERE id>=?', 'parameters': ['updated', 1999]},
        {'sql': 'UPDATE notes SET id=-id WHERE id<4', 'parameters': []},
        {'sql': 'DELETE FROM notes WHERE id>5 AND id<1999', 'parameters': []},
        {'sql': 'INSERT INTO notes VALUES(-128,?,?)', 'parameters': ['negative', -32769]},
        {'sql': 'UPDATE notes SET value=? WHERE id=2002', 'parameters': ['x' * 5000]},
        {'sql': 'DELETE FROM notes', 'parameters': []},
        {'sql': 'INSERT INTO notes(value,n) VALUES(?,?)', 'parameters': ['restart', 1]},
    ]
    if transactions:
        operations = [
            {'sql': 'BEGIN', 'parameters': []},
            {'sql': "UPDATE notes SET value='transaction' WHERE id=1", 'parameters': []},
            {'sql': 'SAVEPOINT a', 'parameters': []},
            {'sql': 'DELETE FROM notes WHERE id>5', 'parameters': []},
            {'sql': 'SAVEPOINT b', 'parameters': []},
            {'sql': "INSERT INTO notes VALUES(6,'temporary',6)", 'parameters': []},
            {'sql': 'ROLLBACK TO b', 'parameters': []},
            {'sql': 'RELEASE b', 'parameters': []},
            {'sql': 'ROLLBACK TO a', 'parameters': []},
            {'sql': 'RELEASE a', 'parameters': []},
            {'sql': 'COMMIT', 'parameters': []},
            {'sql': 'SAVEPOINT outer', 'parameters': []},
            {'sql': 'DELETE FROM notes', 'parameters': []},
            {'sql': 'ROLLBACK', 'parameters': []},
        ]
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        (directory / 'operations.json').write_text(json.dumps(operations))
        subprocess.run(['dart', '--suppress-analytics', 'run', 'tool/export_mutations.dart', str(directory)],
                       cwd=ROOT.parents[1], check=True)
        expected_path = directory / 'reference.db'
        shutil.copyfile(ROOT / 'write.db', expected_path)
        with sqlite3.connect(expected_path) as reference:
            for i, operation in enumerate(operations):
                cursor = reference.execute(operation['sql'], operation['parameters'])
                if not transactions:
                    reference.commit()
                expected = reference.execute('select * from notes order by id').fetchall()
                metadata = json.loads((directory / f'{i}.json').read_text())
                if metadata['changes'] != max(0, cursor.rowcount):
                    raise RuntimeError(f'Change count mismatch at step {i}')
                with sqlite3.connect(f'file:{directory / str(i)}.db?mode=ro', uri=True) as actual:
                    if actual.execute('pragma integrity_check').fetchone() != ('ok',):
                        raise RuntimeError(f'Integrity failure at step {i}')
                    if actual.execute('select * from notes order by id').fetchall() != expected:
                        raise RuntimeError(f'Row mismatch at step {i}')
        print(f'Pinned SQLite cross-open/integrity/differential checks passed for {len(operations)} mutations')


if __name__ == '__main__':
    import sys
    main(transactions='--transactions' in sys.argv)
