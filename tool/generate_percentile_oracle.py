"""Development-only percentile aggregate/window oracle for pinned SQLite."""
import hashlib
import json
import random
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

OUTPUT = ROOT / 'percentile_oracle.json'


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    queries = []
    samples = [[], [None], [1], [1, 3], [1, 3, 7, 9], [1, None, 1, 3],
               [-9, -3, 0, 3, 9], [-9223372036854775808, 9223372036854775807],
               [1e308, 1.5e308], [-1.5e308, 1.5e308]]
    rng = random.Random(3531)
    samples += [[rng.uniform(-1e9, 1e9) for _ in range(rng.randrange(1, 13))]
                for _ in range(30)]
    for values in samples:
        prefix = ('WITH t(y) AS (VALUES' + ','.join('(?)' for _ in values) + ') '
                  if values else 'WITH t(y) AS (SELECT NULL WHERE 0) ')
        for fraction in [0, 0.25, 0.5, 0.75, 1]:
            queries.append((prefix + f'SELECT median(y),percentile(y,{100*fraction}),'
                            f'percentile_cont(y,{fraction}),percentile_disc(y,{fraction}) FROM t', values))
    for value in [None, 1, '2', '2.0', '2x', b'2', float('inf'), -float('inf')]:
        queries.append(('SELECT median(?)', [value]))
        for function, fraction in [('percentile', 50), ('percentile_cont', .5), ('percentile_disc', .5)]:
            queries.append((f'SELECT {function}(?,?)', [value, fraction]))
    for fraction in [None, -1, -0.0, 0, 0.5, 1, 1.00001, 50, 100, 100.00001,
                     float('inf'), -float('inf'), '0.5', ' 0.5 ', '.5e0',
                     '.5\0suffix', '0.5x', '', 'true', '0x1', '1_0', b'.5', '\u00a0.5']:
        for function in ['percentile', 'percentile_cont', 'percentile_disc']:
            queries.append((f'SELECT {function}(NULL,?),{function}(1,?)', [fraction, fraction]))
    for function in ['percentile', 'percentile_cont', 'percentile_disc']:
        for first, second in [(0.5, 0.500999), (0.5, 0.501), (0.5, 0.501001),
                              (0.5, 0.6), (50, 50.05), (50, 50.1), (None, .5)]:
            for values in ['(1,?),(2,?)', '(NULL,?),(2,?)']:
                queries.append((f'WITH t(y,p) AS(VALUES{values}) SELECT {function}(y,p) FROM t', [first, second]))
    frames = ['', 'ROWS CURRENT ROW', 'ROWS BETWEEN 1 PRECEDING AND CURRENT ROW',
              'ROWS BETWEEN 1 FOLLOWING AND 1 FOLLOWING',
              'ROWS BETWEEN 2 FOLLOWING AND 3 FOLLOWING',
              'ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING',
              'ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING',
              'GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW',
              'RANGE BETWEEN 1 PRECEDING AND CURRENT ROW',
              'ROWS CURRENT ROW EXCLUDE NO OTHERS',
              'ROWS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW',
              'GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE GROUP',
              'GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE TIES']
    for frame in frames:
        for values in [
            '(1,10,0.5),(2,20,0.5),(3,NULL,0.5),(4,40,0.5)',
            '(1,10,0.5),(2,20,0.8),(3,30,0.8),(4,40,0.8)',
            '(1,10,0.5),(2,20,0.5005),(3,30,0.5005),(4,40,0.5005)',
        ]:
            over = f'OVER(ORDER BY n {frame})'
            queries.append((f'WITH t(n,y,p) AS(VALUES{values}) SELECT n,median(y){over},'
                            f'percentile_cont(y,p){over},percentile_disc(y,p){over} FROM t ORDER BY n', []))
            queries.append((f'WITH t(n,y,p) AS(VALUES{values}) SELECT n,'
                            f'percentile_cont(y,p) FILTER(WHERE n%2=1){over} FROM t ORDER BY n', []))
    prefix = 'WITH t(n,y,p) AS(VALUES(1,1,0.5),(2,2,0.8)) '
    queries += [(prefix + 'SELECT percentile_cont(y,p) OVER(ORDER BY n ROWS CURRENT ROW) FROM t LIMIT 1', []),
                (prefix + 'SELECT percentile_cont(y,p) OVER(PARTITION BY n) FROM t ORDER BY n', [])]
    prefix = 'WITH t(n,y) AS(VALUES(1,1),(2,1),(3,3),(4,NULL),(5,9)) '
    queries += [(prefix + expression, []) for expression in [
        'SELECT median(DISTINCT y),median(y ORDER BY n DESC) FROM t',
        'SELECT percentile_cont(y,0.5 ORDER BY n DESC) FILTER(WHERE n<4) FROM t',
        'SELECT n%2,median(y),percentile(y,25) FROM t GROUP BY n%2 HAVING median(y)>1 ORDER BY 1',
        'SELECT percentile_cont(y,0.5) OVER(ORDER BY n DESC) FROM t ORDER BY n',
        'SELECT percentile_disc(y,0.75) OVER w FROM t WINDOW w AS(ORDER BY n ROWS CURRENT ROW EXCLUDE NO OTHERS) ORDER BY n',
        'SELECT percentile_cont(DISTINCT y,0.5) FROM t',
        'SELECT median(y) OVER() FROM t LIMIT 0',
        'SELECT median(y) FROM t WHERE 0',
        'SELECT percentile_cont(y,NULL) FROM t WHERE 0',
        'SELECT median(sum(y)) FROM t',
        'SELECT y FROM t WHERE median(y)>1',
    ]]
    queries += [('SELECT ' + expression, []) for expression in [
        'median()', 'median(1,2)', 'percentile(1)', 'percentile(1,2,3)',
        'percentile_cont()', 'percentile_disc(1,2,3)', 'median(*)',
    ]]
    output = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        with sqlite3.connect(':memory:') as connection:
            assert connection.execute('select sqlite_source_id()').fetchone()[0] == PIN
            assert sorted(row[0] for row in connection.execute('pragma compile_options')) == manifest['compile_options']
            connection.execute(f'pragma encoding="{label}"')
            for sql, parameters in queries:
                case = dict(encoding=encoding, sql=sql, parameters=[encode(value) for value in parameters])
                try:
                    case['rows'] = [[encode(value) for value in row] for row in connection.execute(sql, parameters)]
                except sqlite3.Error as error:
                    case['error'] = str(error)
                output.append(case)
    OUTPUT.write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
    OUTPUT.with_suffix('.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest() + '\n')
    print(f'Generated {len(output)} pinned percentile cases')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('Percentile oracle checksum verified')
    else:
        generate()
