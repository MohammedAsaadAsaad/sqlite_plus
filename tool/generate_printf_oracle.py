"""Development-only pinned FORMAT/PRINTF oracle. Tests never invoke SQLite."""
import hashlib
import json
import math
import random
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


PATH = ROOT / 'printf_oracle.json'


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    connection = sqlite3.connect(':memory:')
    assert connection.execute('select sqlite_source_id()').fetchone()[0] == PIN
    assert sorted(r[0] for r in connection.execute('pragma compile_options')) == manifest['compile_options']
    cases = []
    values = [None, 0, 1, -1, 12, -1234, 9223372036854775807,
              -9223372036854775808, 1.5, -1.5, '123e2', '-99.5', 'abc', ' 42rest', b'123']
    for conversion in ['d', 'i', 'u', 'o', 'x', 'X', 'p', 'r']:
        for flags in ['', '+', ' ', '#', '0', '-', ',', ',0', '+#', '+ ']:
            for width in ['', '12', '.0', '.5', '12.5']:
                for value in values:
                    cases.append(['%' + flags + width + conversion, value])
    for conversion in ['s', 'z', 'q', 'Q', 'w', 'c']:
        for flags in ['', '-', '!', '#', '#!']:
            for width in ['', '10', '.0', '.2', '10.2']:
                for value in [None, '', 'abc', "a'b\"c", '\\abc\n\x01', 'λ😀xy', 123, b'abc']:
                    cases.append(['%' + flags + width + conversion, value])
    floats = [0.0, -0.0, 1.0, 1.5, -1.5, 1.25, 2.675, 49.47, -0.00001,
              1.2345678901234567, 1e-100, 1e100, 1e-5, 1e-4, 999999.9,
              math.inf, -math.inf, 5e-324, 1.7976931348623157e308]
    for conversion in ['f', 'e', 'E', 'g', 'G']:
        for flags in ['', '+', '#', '!', '0', ',']:
            for width in ['', '20', '.0', '.2', '.17', '.20', '.30']:
                for value in floats:
                    cases.append(['%' + flags + width + conversion, value])
    rng = random.Random(3531)
    for _ in range(400):
        value = rng.uniform(-1, 1) * 10 ** rng.randrange(-300, 300)
        cases.append(['%' + rng.choice(['', '!', '#', ',']) + '.' +
                      str(rng.randrange(0, 24)) + rng.choice(['f', 'e', 'g']), value])
    cases += [[], [None], [''], ['abc%'], ['abc%k tail'], ['%T', 1],
              ['%d %s %q %Q %c'], ['%n%d', 7], ['%*.*f', 12, -3, 1.25],
              ['%*s', -8, 'x'], ['%*s', -2147483648, 'x'],
              ['%.*s', -2147483648, 'abc'], ['%4294967296d', 1],
              ['%2147483648d', 1], ['%.*d', -3, 1],
              ['%lld|%ld|%u', -123, 456, -1], ['%d', '9223372036854775808'],
              ['%d', '-9223372036854775809'], ['x%5%y'], ['%.3c', '😀'],
              ['%s', 'a\x00b'], ['a\x00%d', 12], ['%s:%d', b'12', 3]]
    results = []
    for args in cases:
        if not args:
            # SQL accepts FORMAT() with no arguments; it returns NULL.
            result = connection.execute('select format()').fetchone()[0]
        else:
            result = connection.execute('select format(' + ','.join('?' for _ in args) + ')', args).fetchone()[0]
        results.append({'arguments': [encode(v) for v in args], 'result': result})
    payload = {'sqlite_version': sqlite3.sqlite_version, 'source_id': PIN, 'cases': results}
    PATH.write_text(json.dumps(payload, ensure_ascii=False, separators=(',', ':')) + '\n')
    PATH.with_suffix('.sha256').write_text(hashlib.sha256(PATH.read_bytes()).hexdigest() + '\n')
    print(f'Generated {len(results)} pinned printf cases')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        expected = PATH.with_suffix('.sha256').read_text().strip()
        assert hashlib.sha256(PATH.read_bytes()).hexdigest() == expected
        print('printf oracle checksum verified')
    else:
        generate()
