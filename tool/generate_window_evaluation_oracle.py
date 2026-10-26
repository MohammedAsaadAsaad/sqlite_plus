"""Development-only pinned SQLite window input-register/callback oracle."""
from pathlib import Path
import sys
import generate_insert_stream_oracle as harness

OUTPUT = harness.ROOT / 'window_evaluation_oracle.json'


def cases():
    result = []

    def add(name, expression, *, tail='', setup=None, before='', extra=''):
        result.append(dict(name=name, setup=harness.SOURCE + [harness.DESTINATION] + (setup or []),
                           sql='INSERT INTO dst(v) ' + before + 'SELECT tick()+(' + expression + ')*0 FROM src' + extra + tail,
                           parameters=[], after=['SELECT * FROM dst ORDER BY rowid']))

    for function in ['sum(visit(id))', 'total(visit(id))', 'avg(visit(id))',
                     'count(visit(id))', 'min(visit(id))', 'max(visit(id))',
                     'first_value(visit(id))', 'last_value(visit(id))',
                     'nth_value(visit(id),2)', 'lag(visit(id))', 'lead(visit(id))',
                     'ntile(visit(id))']:
        for frame in ['ORDER BY id', 'ORDER BY id ROWS 1 PRECEDING']:
            add(function + ' ' + frame, function+' OVER('+frame+')')
        add(function+' LIMIT', function+' OVER(ORDER BY id)', tail=' LIMIT 1')
    for frame in ['', 'ORDER BY id DESC ROWS 1 PRECEDING', 'ORDER BY y',
                  'PARTITION BY y ORDER BY id ROWS 1 PRECEDING',
                  'ORDER BY id ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING',
                  'ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING',
                  'ORDER BY id ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING',
                  'ORDER BY id RANGE BETWEEN CURRENT ROW AND CURRENT ROW',
                  'ORDER BY id RANGE BETWEEN CURRENT ROW AND 1 FOLLOWING',
                  'ORDER BY id GROUPS BETWEEN CURRENT ROW AND 1 FOLLOWING']:
        add('sum frame '+frame, 'sum(visit(id)) OVER('+frame+')')
        add('sum limited frame '+frame, 'sum(visit(id)) OVER('+frame+')', tail=' LIMIT 1')
    add('offset advances input registers', 'sum(visit(id)) OVER(ORDER BY id ROWS 1 PRECEDING)', tail=' LIMIT 1 OFFSET 1')
    add('FILTER arguments precede predicate', 'sum(visit(id)) FILTER(WHERE keep(id)) OVER(ORDER BY id ROWS 1 PRECEDING)')
    add('FILTER arguments are captured on excluded rows', 'sum(visit(id)) FILTER(WHERE 0) OVER(ORDER BY id ROWS 1 PRECEDING)')
    add('FILTER LIMIT input prefix', 'sum(visit(id)) FILTER(WHERE keep(id)) OVER(ORDER BY id ROWS 1 PRECEDING)',tail=' LIMIT 1')
    add('callback order key follows argument', 'sum(visit(id)) OVER(ORDER BY audit(y))')
    add('callback partition key follows argument', 'sum(visit(id)) OVER(PARTITION BY audit(y) ORDER BY id)')
    add('same window functions reverse argument registers', '(sum(visit(id)) OVER(ORDER BY id)+sum(audit(id)) OVER(ORDER BY id))')
    add('different windows stage their registers', '(sum(visit(id)) OVER(ORDER BY id)+sum(audit(id)) OVER(ORDER BY y))')
    add('lag evaluates unused defaults once per source row', 'lag(visit(id),tick(),tick()) OVER(ORDER BY id)')
    add('lag LIMIT evaluates argument prefix', 'lag(visit(id),tick(),tick()) OVER(ORDER BY id)', tail=' LIMIT 1')
    add('lead captures full partition', 'lead(visit(id),1,tick()) OVER(ORDER BY id)', tail=' LIMIT 1')
    add('nth value captures unused values', 'nth_value(visit(id),audit(id)) OVER(ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)')
    add('GROUPS follow needs only bounded future groups', 'sum(visit(id)) OVER(ORDER BY id GROUPS BETWEEN CURRENT ROW AND 1 FOLLOWING)', tail=' LIMIT 1', setup=['INSERT INTO src VALUES(4,3),(5,3)'])
    add('RANGE follow needs only bounded future values', 'sum(visit(id)) OVER(ORDER BY id RANGE BETWEEN CURRENT ROW AND 1 FOLLOWING)', tail=' LIMIT 1', setup=['INSERT INTO src VALUES(4,3),(5,3)'])
    add('frame-invalid literal after first input', 'sum(visit(id)) OVER(ORDER BY id ROWS -1 PRECEDING)')
    add('frame function not evaluated', 'sum(visit(id)) OVER(ORDER BY id ROWS tick() PRECEDING)')
    add('frame deterministic function not evaluated', 'sum(visit(id)) OVER(ORDER BY id ROWS abs(1) PRECEDING)')
    add('frame arithmetic constants', 'sum(visit(id)) OVER(ORDER BY id ROWS (1+1) PRECEDING)')
    add('EXCLUDE does not reevaluate argument', 'sum(visit(id)) OVER(ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW)')
    add('same window callback key is shared once', '(sum(visit(id)) OVER(ORDER BY keep(id))+sum(audit(id)) OVER(ORDER BY keep(id)))')
    add('different frames layer coroutines', '(sum(visit(id)) OVER(ORDER BY id ROWS 1 PRECEDING)+sum(audit(id)) OVER(ORDER BY id ROWS UNBOUNDED PRECEDING))', tail=' LIMIT 1')
    add('ranking and default aggregate layer coroutines', '(row_number() OVER(ORDER BY id)+sum(visit(id)) OVER(ORDER BY id))', tail=' LIMIT 1')
    add('identical windows preserve duplicate argument registers', '(sum(visit(id)) OVER(ORDER BY id)+sum(visit(id)) OVER(ORDER BY id))')
    add('lag coerces explicit frame', 'lag(visit(id)) OVER(ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)', tail=' LIMIT 1')
    add('lag unordered streams input', 'lag(visit(id)) OVER()', tail=' LIMIT 1')
    add('different directions stage sorted input', '(sum(visit(id)) OVER(ORDER BY id)+sum(audit(id)) OVER(ORDER BY id DESC))')
    add('infinite RANGE offset is nonnegative', 'sum(visit(id)) OVER(ORDER BY id RANGE BETWEEN CURRENT ROW AND 1e999 FOLLOWING)', tail=' LIMIT 1')
    add('max signed integer ROWS offset', 'sum(visit(id)) OVER(ORDER BY id ROWS 9223372036854775807 PRECEDING)')
    add('out of signed integer ROWS offset', 'sum(visit(id)) OVER(ORDER BY id ROWS 1e20 PRECEDING)')
    add('fractional ROWS offset rejects after input', 'sum(visit(id)) OVER(ORDER BY id ROWS 1.5 PRECEDING)')
    add('negative RANGE offset rejects after input', 'sum(visit(id)) OVER(ORDER BY id RANGE -1 PRECEDING)')
    return result


if __name__ == '__main__':
    harness.OUTPUT = OUTPUT
    if '--verify' in sys.argv:
        import hashlib
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('Window evaluation oracle checksum verified')
    else:
        harness.cases = cases
        harness.generate()
