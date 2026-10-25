"""Development-only STAT1 selectivity plans/results against pinned SQLite."""
import json
import re
import sqlite3
import subprocess
import tempfile
from pathlib import Path

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def main():
    setup = [
        'CREATE TABLE items(id INTEGER PRIMARY KEY,a INT,b INT,c INT,payload TEXT)',
        "INSERT INTO items WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000) SELECT x,x%2,x,x%5,'payload-'||x FROM n",
        'CREATE INDEX broad ON items(a,c)',
        'CREATE INDEX selective ON items(b)',
        'CREATE INDEX small ON items(a) WHERE b>=990',
        'CREATE INDEX expression_broad ON items(abs(a),c)',
        'CREATE INDEX expression_selective ON items(b+0)',
        'ANALYZE',
    ]
    queries = [
        ('SELECT payload FROM items WHERE a=1 AND c=4 AND b=999', []),
        ('SELECT payload FROM items WHERE a=? AND c=? AND b=?', [1, 4, 999]),
        ('SELECT payload FROM items WHERE a=1 AND c>=4 AND c<=4 AND b=999', []),
        ('SELECT payload FROM items WHERE a=1 AND b>=990', []),
        ('SELECT payload FROM items WHERE abs(a)=1 AND c=4 AND b+0=999', []),
        ('SELECT payload FROM items INDEXED BY broad WHERE a=1 AND c=4 AND b=999', []),
        ('SELECT payload FROM items NOT INDEXED WHERE a=1 AND c=4 AND b=999', []),
        ('SELECT payload FROM items WHERE id=999 AND a=1 AND c=4', []),
        ('SELECT payload FROM main.items WHERE a=1 AND c=4 AND b=999', []),
        ('SELECT payload FROM items WHERE a=1 AND c=4 AND b=1001', []),
    ]
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            input_path = directory / 'input.json'
            image_path = directory / 'actual.db'
            input_path.write_text(json.dumps(dict(encoding=encoding, setup=setup,
                queries=[dict(sql=sql, parameters=parameters) for sql, parameters in queries])))
            actual = json.loads(subprocess.check_output([
                'dart', '--suppress-analytics', 'run', 'tool/planner_statistics_differential.dart',
                str(input_path), str(image_path)], cwd=ROOT.parents[1]))
            with sqlite3.connect(':memory:') as reference:
                assert reference.execute('select sqlite_source_id()').fetchone()[0] == PIN
                assert sorted(row[0] for row in reference.execute('pragma compile_options')) == manifest['compile_options']
                reference.execute(f'pragma encoding="{label}"')
                for statement in setup:
                    reference.execute(statement)
                for (sql, parameters), observed in zip(queries, actual):
                    cursor = reference.execute(sql, parameters)
                    assert observed['columns'] == [column[0] for column in cursor.description], sql
                    expected = [[encode(value) for value in row] for row in cursor]
                    assert observed['rows'] == expected, (sql, observed, expected)
                    details = ' '.join(row[3] for row in reference.execute('EXPLAIN QUERY PLAN ' + sql, parameters))
                    match = re.search(r'USING (?:COVERING )?INDEX ([^ ]+)', details)
                    index = match[1] if match else None
                    assert observed['index'] == index, (sql, observed, details)
            with sqlite3.connect(image_path) as opened:
                assert opened.execute('pragma integrity_check').fetchall() == [('ok',)]
                assert opened.execute("select stat from sqlite_stat1 where idx='broad'").fetchone() == ('1000 500 100',)
                assert opened.execute("select stat from sqlite_stat1 where idx='selective'").fetchone() == ('1000 1',)
    print(f'Pinned STAT1 planner checks passed: {len(queries)} selective plans/results in each encoding ({3*len(queries)} total), with native image integrity')


if __name__ == '__main__':
    main()
