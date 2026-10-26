"""Compare live callback traces and Dart images against pinned SQLite."""
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_insert_stream_oracle import cases, register_callbacks
from generate_sql_oracle import encode


def main(case_factory=cases, fixture='insert_stream_oracle.json'):
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    snapshots = operations = 0
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            subprocess.run(['dart', '--suppress-analytics', 'run',
                            'tool/insert_stream_differential.dart',
                            str(directory), str(encoding), fixture],
                           cwd=ROOT.parents[1], check=True)
            observed = json.loads((directory / 'observed.json').read_text())
            for case_index, case in enumerate(case_factory()):
                with sqlite3.connect(':memory:', isolation_level=None) as reference:
                    assert reference.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
                    assert sorted(row[0] for row in reference.execute('PRAGMA compile_options')) == manifest['compile_options']
                    reference.execute(f"PRAGMA encoding='{label}'")
                    trace = []
                    register_callbacks(reference, trace)
                    for step_index, sql in enumerate(case['setup'] + [case['sql']] + case['after']):
                        rows, changes, error = [], 0, False
                        parameters = case['parameters'] if sql == case['sql'] else []
                        try:
                            cursor = reference.execute(sql, parameters)
                            rows = [[encode(value) for value in row] for row in cursor] if cursor.description else []
                            if sql.startswith(('INSERT', 'REPLACE', 'UPDATE', 'DELETE', 'WITH')):
                                changes = reference.execute('SELECT changes()').fetchone()[0]
                        except sqlite3.Error:
                            error = True
                        expected = dict(error=error, changes=changes, rows=rows, trace=trace)
                        actual = observed[case_index][step_index]
                        context = (encoding, case['name'], sql)
                        assert actual == expected, (context, actual, expected)
                        operations += 1
                    with sqlite3.connect(f'file:{directory / str(case_index)}.db?mode=ro', uri=True) as opened:
                        assert opened.execute('PRAGMA encoding').fetchone()[0] == label
                        assert opened.execute('PRAGMA integrity_check').fetchall() == [('ok',)], case['name']
                        tables = reference.execute("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name").fetchall()
                        assert opened.execute("SELECT name FROM sqlite_schema WHERE type='table' ORDER BY name").fetchall() == tables
                        for (name,) in tables:
                            quoted = '"' + name.replace('"', '""') + '"'
                            without_rowid = reference.execute("SELECT wr FROM pragma_table_list WHERE name=?", (name,)).fetchone()[0]
                            if without_rowid:
                                columns = reference.execute(f'PRAGMA table_info({quoted})').fetchall()
                                keys = sorted((column for column in columns if column[5]), key=lambda column: column[5])
                                order = ','.join('"' + column[1].replace('"', '""') + '"' for column in keys)
                                query = f'SELECT * FROM {quoted} ORDER BY {order}'
                            else:
                                query = f'SELECT rowid,* FROM {quoted} ORDER BY rowid'
                            assert opened.execute(query).fetchall() == reference.execute(query).fetchall(), (encoding, case['name'], name)
                        snapshots += 1
    print(f'Pinned SQLite {fixture} checks passed: {operations} operations, {snapshots} native cross-open snapshots')


if __name__ == '__main__':
    main()
