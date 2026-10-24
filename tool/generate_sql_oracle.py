"""Pinned development-only SELECT oracle; runtime/tests never invoke SQLite."""
import hashlib
import json
import random
import sqlite3
from generate_fixtures import PIN, ROOT


def encode(v):
    if isinstance(v, bytes):
        return {'blob': v.hex()}
    if isinstance(v, int):
        return {'integer': str(v)}
    return v


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    with sqlite3.connect(':memory:') as connection:
        if connection.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        options = sorted(r[0] for r in connection.execute('pragma compile_options'))
        if options != manifest['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    queries = [
        ('select * from sample order by id limit 4', []),
        ('SELECT ID, value FROM SAMPLE WHERE id >= ? AND id < ? ORDER BY id DESC', [127, 131]),
        ('select rowid, _rowid_, oid, id from sample where id = 128', []),
        ('select value as v, id + 2 as next from sample where id <= 3 order by next desc', []),
        ('select id, value from sample where id = \'128\'', []),
        ('select id from sample where value = 1', []),
        ('select id from sample where +id = \'128\'', []),
        ('select id from sample order by 1 desc limit 3 offset 2', []),
        ('select id from sample limit 2,3', []),
        ('select id from sample limit -1 offset 198', []),
        ('select id from sample limit 0', []),
        ('select id from sample limit \'3\'', []),
        ('select id from sample limit 2.0', []),
        ('select id from sample where null', []),
        ('select distinct n from types', []),
        ('select i,r,t from types order by i', []),
        ('select i from types where i > 9223372036854775806.0 order by i', []),
        ('select i from types where i = -9223372036854775808', []),
        ('select k,v from keyed where v >= 148 order by k desc', []),
        ('select * from empty', []),
        ('select type,name,rootpage from sqlite_schema order by name', []),
        ('select type,name from sqlite_master where type = \'index\' order by name', []),
        ('select 1 + 2, -1 || 2, 0xff, X\'00ff\', \'a\'\'b\', null', []),
        ('select ?1, ?3, ?1 + ?2', [2, 3, 'bound']),
        ('select \'quoted;--\' as "λ label" /* comment */;', []),
        ('select [id], `value` from "sample" where "id"=1 -- comment', []),
    ]
    expressions = [
        '0.0 = -0.0', '1e999 % 3', '~1e999', '1e999 + -1e999',
        'NULL AND 0', 'NULL OR 1', 'NOT NULL', '2 IS TRUE', '2 IS FALSE',
        'NULL IS NOT TRUE', 'NULL IS FALSE', '0 IS NOT FALSE',
        '1 = \'1\'', '1 IS \'1\'', 'NULL IS NULL', 'NULL = NULL',
        '9223372036854775807 + 1', '-9223372036854775808 / -1',
        '-9223372036854775808', '0xffffffffffffffff',
        '-5 / 2', '-5 % 2', '5 / 0', '5.0 % 2',
        "'12xyz' + 1", "'abc' * 5", "X'3132' + 1", '1e100 + 1',
        "'a' < 'b'", "'λ' < '😀'", "X'ff' > 'text'", "-1 || 2",
        '1 < 2 = 1', 'NOT 2 = 1', '1 + 2 * 3', '1 || 2 + 3',
    ]
    rng = random.Random(318)
    leaves = ['NULL', '0', '1', '-3', '128', '9223372036854775807',
              '2.5', "'1'", "'abc'", "X'00'"]
    operators = ['+', '-', '*', '/', '%', '=', '<', '>=', 'AND', 'OR', 'IS', '||']
    for _ in range(180):
        expressions.append(f'({rng.choice(leaves)} {rng.choice(operators)} {rng.choice(leaves)})')
    queries += [(f'select {e} as result', []) for e in expressions]
    cases = []
    for fixture in manifest['fixtures']:
        with sqlite3.connect(f"file:{ROOT / fixture['file']}?mode=ro", uri=True) as connection:
            for sql, params in queries:
                cursor = connection.execute(sql, params)
                cases.append({'file': fixture['file'], 'sql': sql,
                              'parameters': [encode(v) for v in params],
                              'columns': [c[0] for c in cursor.description],
                              'rows': [[encode(v) for v in row] for row in cursor]})
    output = ROOT / 'select_oracle.json'
    output.write_text(json.dumps(cases, indent=2, ensure_ascii=False) + '\n')
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    (ROOT / 'select_oracle.sha256').write_text(digest + '\n')
    print(f'Wrote {len(cases)} pinned SELECT cases')


if __name__ == '__main__':
    import sys
    if '--verify' in sys.argv:
        actual = hashlib.sha256((ROOT / 'select_oracle.json').read_bytes()).hexdigest()
        expected = (ROOT / 'select_oracle.sha256').read_text().strip()
        if actual != expected:
            raise RuntimeError('SELECT oracle checksum mismatch')
        print('SELECT oracle checksum verified')
    else:
        generate()
