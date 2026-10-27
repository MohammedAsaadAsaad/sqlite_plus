"""Development-only native cross-open and write-continuation gate for the ORM."""
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

PACKAGE = Path(__file__).resolve().parents[1] / 'packages/sqlite_plus_orm'


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as reference:
        assert reference.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
        assert sorted(row[0] for row in reference.execute('PRAGMA compile_options')) == manifest['compile_options']
    with tempfile.TemporaryDirectory(prefix='sqlite-plus-orm-') as temporary:
        directory = Path(temporary)
        subprocess.run(['dart', '--suppress-analytics', 'run',
                        'tool/export_orm.dart', str(directory)],
                       cwd=PACKAGE, check=True)
        comparisons = 0
        for encoding in (1, 2, 3):
            path = directory / f'{encoding}.db'
            expected = json.loads((directory / f'{encoding}.json').read_text())
            with sqlite3.connect(path) as db:
                db.execute('PRAGMA foreign_keys=ON')
                assert db.execute('PRAGMA integrity_check').fetchall() == [('ok',)]
                assert db.execute('PRAGMA foreign_key_check').fetchall() == []
                for query in expected['queries']:
                    cursor = db.execute(query['sql'])
                    columns = [column[0] for column in cursor.description]
                    rows = [[encode(value) for value in row] for row in cursor]
                    assert columns == query['columns'], (encoding, query['sql'], columns)
                    assert rows == query['rows'], (encoding, query['sql'], rows, query['rows'])
                    comparisons += 1
                for sql, parameters in expected['native_writes']:
                    decoded = [bytes.fromhex(value['blob'])
                               if isinstance(value, dict) and 'blob' in value
                               else int(value['integer'])
                               if isinstance(value, dict) and 'integer' in value
                               else value for value in parameters]
                    db.execute(sql, decoded)
                assert db.execute('PRAGMA foreign_key_check').fetchall() == []
                assert db.execute('PRAGMA integrity_check').fetchall() == [('ok',)]
        subprocess.run(['dart', '--suppress-analytics', 'run',
                        'tool/export_orm.dart', str(directory), '--read-native'],
                       cwd=PACKAGE, check=True)
        for encoding in (1, 2, 3):
            with sqlite3.connect(directory / f'{encoding}.db') as db:
                assert db.execute('PRAGMA integrity_check').fetchall() == [('ok',)]
                assert db.execute('PRAGMA foreign_key_check').fetchall() == []
                assert db.execute('SELECT "display name",revision FROM '
                                  '"people ""主""" WHERE id=1001').fetchall() == [
                                      ('Dart after native', 8)]
        print(f'Pinned SQLite ORM gate passed: {comparisons} comparisons, '
              'three encoding cross-opens and native write continuations')


if __name__ == '__main__':
    main()
