"""Pinned development-only migration SQL/reference and physical image gate."""
import json
import pathlib
import sqlite3
import subprocess
import tempfile

from generate_fixtures import PIN, ROOT

PACKAGE = pathlib.Path(__file__).resolve().parents[1] / 'packages/sqlite_plus_orm'


def encode(value):
    if isinstance(value, int):
        return {'integer': str(value)}
    if isinstance(value, bytes):
        return {'blob': value.hex()}
    return value


def decode(value):
    if isinstance(value, dict) and 'integer' in value:
        return int(value['integer'])
    if isinstance(value, dict) and 'blob' in value:
        return bytes.fromhex(value['blob'])
    return value


def query(db, sql):
    cursor = db.execute(sql)
    return {'sql': sql, 'columns': [column[0] for column in cursor.description],
            'rows': [[encode(value) for value in row] for row in cursor]}


def main():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    operations = snapshots = 0
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        with tempfile.TemporaryDirectory(prefix='sqlite_plus_orm_migrations_') as path:
            subprocess.run(['dart', '--suppress-analytics', 'run',
                            'tool/export_migrations.dart', path, str(encoding)],
                           cwd=PACKAGE, check=True)
            generated = json.loads((pathlib.Path(path) / 'migrations.json').read_text())
            with sqlite3.connect(':memory:', isolation_level=None) as reference:
                assert reference.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
                assert sorted(row[0] for row in reference.execute('PRAGMA compile_options')) == manifest['compile_options']
                reference.execute(f"PRAGMA encoding='{label}'")
                for snapshot in generated['snapshots']:
                    for operation in snapshot['operations']:
                        error = False
                        try:
                            reference.execute(operation['sql'],
                                              [decode(v) for v in operation['parameters']])
                        except sqlite3.Error:
                            error = True
                        assert error == operation['error'], (label, snapshot['name'], operation)
                        operations += 1
                    image = pathlib.Path(path) / snapshot['file']
                    with sqlite3.connect(image, isolation_level=None) as physical:
                        physical.execute('PRAGMA foreign_keys=ON')
                        assert physical.execute('PRAGMA integrity_check').fetchall() == [('ok',)]
                        assert physical.execute('PRAGMA foreign_key_check').fetchall() == []
                        for expected in snapshot['queries']:
                            assert query(reference, expected['sql']) == expected, (
                                label, snapshot['name'], 'native SQL', expected['sql'],
                                query(reference, expected['sql']), expected)
                            assert query(physical, expected['sql']) == expected, (
                                label, snapshot['name'], 'cross-open', expected['sql'],
                                query(physical, expected['sql']), expected)
                    snapshots += 1
                # Continue natively from the Dart-written final schema, checking
                # composite FK updates/deletes and generated INTEGER PRIMARY KEY.
                with sqlite3.connect(image, isolation_level=None) as physical:
                    physical.execute('PRAGMA foreign_keys=ON')
                    physical.execute("UPDATE parent SET a=2,b='next'")
                    assert physical.execute('SELECT pa,pb FROM child').fetchall() == [(2, 'next')]
                    physical.execute('DELETE FROM parent')
                    assert physical.execute('SELECT pa,pb FROM child').fetchall() == [(None, None)]
                    physical.execute('INSERT INTO child(title) VALUES(7)')
                    assert physical.execute('SELECT id FROM child ORDER BY id').fetchall() == [(1,), (2,)]
                    assert physical.execute('PRAGMA integrity_check').fetchall() == [('ok',)]
                    assert physical.execute('PRAGMA foreign_key_check').fetchall() == []
    print(f'Pinned ORM migrations agree: {operations} SQL operations, {snapshots} cross-open snapshots, three native continuation checks')


if __name__ == '__main__':
    main()
