"""Development-only SQLite text coercion/affinity reference corpus."""
import hashlib
import json
import sqlite3
import sys
from generate_fixtures import ROOT, PIN
from generate_sql_oracle import encode

OUTPUT = ROOT / 'numeric_text_oracle.json'


def inputs():
    result = ['', ' ', '\t\n\v\f\r ', '0', '-0', '+0', '123', '-1.5',
              '+1.5', '.5', '1.', '1e2', '1e-2', '1e+2', '1e', '1e+',
              '123junk', '123 junk', '0x10', '0_1', '1_0', '+ 1', '- 1',
              '\x00123', '123\x00', '1\x002', '\x001.5', '123junk\x00',
              '123\x00junk', '123 \x00junk', '1e2\x00',
              '9223372036854775807\x00', '9007199254740993\x00',
              '１２３', '١٢٣', '−1', 'NaN', 'Infinity', 'Inf',
              '9223372036854775807', '-9223372036854775808',
              '9223372036854775808', '-9223372036854775809',
              '9007199254740993.0', '9223372036854775807.0',
              '2251799813685247.0', '2251799813685248.0',
              '4503599627370495.0', '4503599627370496.0',
              '0' * 40 + '1', '9' * 65]
    for space in [' ', '\t', '\n', '\v', '\f', '\r', '\x85', '\xa0',
                  '\u1680', '\u2000', '\u2003', '\u2028', '\u2029',
                  '\u202f', '\u205f', '\u3000', '\ufeff']:
        result += [space + '123', '123' + space, space + '-1.5',
                   '0' + space, space + '0', '1' + space + '2']
    return list(dict.fromkeys(result))


def operations():
    yield 'CREATE TABLE n(n NUMERIC,i INTEGER,r REAL,t TEXT,b BLOB,a ANY)', [], False
    yield 'CREATE TABLE strict_values(n INT,r REAL,a ANY) STRICT', [], False
    for value in inputs():
        yield ('SELECT CAST(?1 AS INTEGER),CAST(?1 AS REAL),'
               'typeof(CAST(?1 AS NUMERIC)),CAST(?1 AS NUMERIC),'
               'typeof(?1+0),?1+0,NOT ?1,?1<<1,?1>>1,?1&3,?1|1,~?1,'
               'typeof(?1%7),?1%7,7%?1,abs(?1),sign(?1),'
               'round(?1),(?1=CAST(?1 AS NUMERIC))'), [value], True
        yield ('INSERT INTO n VALUES(?1,?1,?1,?1,?1,?1) RETURNING '
               'typeof(n),n,typeof(i),i,typeof(r),r,typeof(t),t,'
               'typeof(b),b,typeof(a),a'), [value], False
        yield 'INSERT INTO strict_values VALUES(?1,?1,?1) RETURNING typeof(n),n,typeof(r),r,typeof(a),a', [value], False
    # Numeric text is consumed by comparisons and aggregates as well as CAST.
    yield ('SELECT count(*),sum(n IS t),sum(i IS t),sum(r IS t),'
           'sum(b IS t),sum(a IS t) FROM n'), [], True
    yield 'SELECT typeof(sum(v)),sum(v),typeof(total(v)),total(v),avg(v) FROM (SELECT b AS v FROM n WHERE rowid<30)', [], True
    yield 'PRAGMA integrity_check', [], True


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    suites = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        with sqlite3.connect(':memory:', isolation_level=None) as db:
            assert db.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
            assert sorted(row[0] for row in db.execute('PRAGMA compile_options')) == manifest['compile_options']
            db.execute(f"PRAGMA encoding='{label}'")
            steps = []
            for sql, parameters, query in operations():
                step = {'sql': sql, 'parameters': parameters, 'query': query}
                try:
                    cursor = db.execute(sql, parameters)
                    step['rows'] = [[encode(value) for value in row] for row in cursor] if cursor.description else []
                    step['changes'] = db.execute('SELECT changes()').fetchone()[0] if sql.startswith('INSERT') else 0
                except sqlite3.Error as error:
                    step['error'] = str(error)
                steps.append(step)
            suites.append({'encoding': encoding, 'steps': steps})
    OUTPUT.write_text(json.dumps({'source_id': PIN, 'suites': suites}, indent=2)+'\n')
    OUTPUT.with_suffix('.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest()+'\n')
    print(f'Generated {sum(len(s["steps"]) for s in suites)} pinned numeric-text operations')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('Numeric-text oracle checksum verified')
    else:
        generate()
