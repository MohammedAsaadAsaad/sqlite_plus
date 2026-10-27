"""Development-only native oracle for ORM-generated SQL and bound parameters."""
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

PACKAGE = Path(__file__).resolve().parents[1] / 'packages/sqlite_plus_orm'


def decode(value):
    if isinstance(value, dict):
        if 'integer' in value:
            return int(value['integer'])
        if 'blob' in value:
            return bytes.fromhex(value['blob'])
    return value


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as reference:
        if reference.execute('SELECT sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        options = sorted(row[0] for row in reference.execute('PRAGMA compile_options'))
        if options != manifest['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    with tempfile.TemporaryDirectory(prefix='sqlite-plus-orm-queries-') as temporary:
        directory = Path(temporary)
        subprocess.run(['dart', '--suppress-analytics', 'run',
                        'tool/export_query_oracle.dart', str(directory)],
                       cwd=PACKAGE, check=True)
        comparisons = 0
        for encoding in (1, 2, 3):
            expected = json.loads((directory / f'{encoding}.json').read_text())
            with sqlite3.connect(f'file:{directory / f"{encoding}.db"}?mode=ro',
                                 uri=True) as database:
                if database.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                    raise AssertionError(f'Integrity failure for encoding {encoding}')
                for case in expected:
                    parameters = [decode(value) for value in case['parameters']]
                    cursor = database.execute(case['sql'], parameters)
                    columns = [column[0] for column in cursor.description]
                    rows = [[encode(value) for value in row] for row in cursor]
                    if columns != case['columns'] or rows != case['rows']:
                        raise AssertionError((encoding, case['case'], case['sql'],
                                              columns, rows, case['rows']))
                    comparisons += 1
        print(f'Pinned SQLite ORM query gate passed: {comparisons} bound query '
              'comparisons across UTF-8, UTF-16le and UTF-16be')


if __name__ == '__main__':
    main()
