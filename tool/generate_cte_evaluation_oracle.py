"""Development-only CTE/view evaluation oracle for the pinned SQLite build."""
import hashlib
import json
import sqlite3
import sys

from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

OUTPUT = ROOT / 'cte_evaluation_oracle.json'
SOURCE = [
    'CREATE TABLE t(id INTEGER PRIMARY KEY,y TEXT COLLATE NOCASE)',
    "INSERT INTO t VALUES(1,'A'),(2,'a'),(3,'B')",
    'CREATE TABLE empty(id)',
]


def cases():
    result = []

    def add(name, sql, setup=None, parameters=None):
        result.append(dict(name=name, setup=SOURCE + (setup or []), sql=sql,
                           parameters=parameters or []))

    bodies = [
        ('flat', 'SELECT tick() AS v FROM t'),
        ('constant', 'SELECT tick() AS v'),
        ('limited', 'SELECT tick() AS v FROM t LIMIT 2'),
        ('offset', 'SELECT tick() AS v FROM t LIMIT 2 OFFSET 1'),
        ('ordered', 'SELECT tick() AS v FROM t ORDER BY y DESC'),
        ('projection ordered', 'SELECT tick() AS v FROM t ORDER BY v DESC'),
        ('distinct', 'SELECT DISTINCT tick() AS v FROM t'),
        ('aggregate', 'SELECT tick()+count(*)*0 AS v FROM t'),
        ('grouped', 'SELECT tick()+count(*)*0 AS v FROM t GROUP BY y'),
        ('window', 'SELECT tick()+row_number() OVER()*0 AS v FROM t'),
        ('union all', 'SELECT tick() AS v FROM t UNION ALL SELECT tick() FROM t'),
        ('union', 'SELECT tick() AS v FROM t UNION SELECT tick() FROM t'),
    ]
    consumers = [
        ('duplicate reference', 'SELECT v,v FROM c'),
        ('filter reference', 'SELECT v FROM c WHERE v>0'),
        ('unused projection', 'SELECT count(*) FROM c'),
        ('early stop', 'SELECT v FROM c LIMIT 1'),
    ]
    for body_name, body in bodies:
        for hint in ['', 'NOT MATERIALIZED ', 'MATERIALIZED ']:
            for consumer_name, consumer in consumers:
                add(f'{hint or "default "}{body_name}: {consumer_name}',
                    f'WITH c AS {hint}({body}) {consumer}')

    for relation_kind in ['view', 'derived']:
        for body_name, body in bodies:
            for consumer_name, consumer in consumers:
                if relation_kind == 'view':
                    add(f'view {body_name}: {consumer_name}', consumer,
                        setup=[f'CREATE VIEW c AS {body}'])
                else:
                    add(f'derived {body_name}: {consumer_name}',
                        consumer.replace('FROM c', f'FROM ({body}) c'))

    for hint in ['', 'NOT MATERIALIZED ', 'MATERIALIZED ']:
        prefix = f'WITH c AS {hint}(SELECT tick() AS v FROM t) '
        add(f'{hint}flat two sources', prefix +
            'SELECT a.v,b.v FROM c a CROSS JOIN c b LIMIT 1')
        add(f'{hint}flat join predicate', prefix +
            'SELECT a.v,b.v FROM c a JOIN c b ON a.v>0 LIMIT 1')
        add(f'{hint}flat two scalar consumers', prefix +
            'SELECT (SELECT v FROM c LIMIT 1),(SELECT v FROM c LIMIT 1)')
        add(f'{hint}flat scalar and row consumers', prefix +
            'SELECT v,(SELECT v FROM c LIMIT 1) FROM c LIMIT 1')
        add(f'{hint}constant two sources',
            f'WITH c AS {hint}(SELECT tick() AS v) '
            'SELECT a.v,b.v FROM c a CROSS JOIN c b')
        add(f'{hint}limited two sources',
            f'WITH c AS {hint}(SELECT tick() AS v FROM t LIMIT 2) '
            'SELECT a.v,b.v FROM c a CROSS JOIN c b LIMIT 1')
        add(f'{hint}unused callback',
            f'WITH c AS {hint}(SELECT fail_if(2)) SELECT 42')
        add(f'{hint}unused unresolved source',
            f'WITH c AS {hint}(SELECT missing FROM absent) SELECT 42')
        add(f'{hint}unused width mismatch',
            f'WITH c(x,y) AS {hint}(SELECT tick()) SELECT 42')
        add(f'{hint}outer limit zero', prefix + 'SELECT v FROM c LIMIT 0')
        add(f'{hint}outer bound limit zero', prefix + 'SELECT v FROM c LIMIT ?1',
            parameters=[0])
        add(f'{hint}empty joined source', prefix +
            'SELECT c.v FROM empty CROSS JOIN c')
        add(f'{hint}unused projection error',
            f'WITH c AS {hint}(SELECT fail_if(id) AS v FROM t) '
            'SELECT count(*) FROM c')

    add('forward references remain lazy',
        'WITH c AS(SELECT v FROM d),d AS(SELECT tick() AS v FROM t) '
        'SELECT v,v FROM c')
    add('transitive unused CTEs remain unused',
        'WITH c AS(SELECT fail_if(2) AS v),d AS(SELECT v FROM c) SELECT 42')
    add('explicit CTE column aliases',
        'WITH c(x) AS(SELECT tick() FROM t) SELECT x,x FROM c WHERE x>0')
    add('view explicit column aliases', 'SELECT x,x FROM c WHERE x>0',
        setup=['CREATE VIEW c(x) AS SELECT tick() FROM t'])
    add('derived duplicate column labels',
        'SELECT v,"v:1" FROM(SELECT tick() AS v,tick() AS v FROM t)')
    add('nested view substitutions', 'SELECT v,v FROM outer_view',
        setup=['CREATE VIEW inner_view AS SELECT tick() AS v FROM t',
               'CREATE VIEW outer_view AS SELECT v FROM inner_view'])
    add('untaken scalar CTE branch',
        'WITH c AS(SELECT fail_if(2) AS v) '
        'SELECT CASE WHEN 0 THEN(SELECT v FROM c) ELSE 42 END')
    add('correlated source projection',
        'SELECT id,(WITH c AS(SELECT visit(t.id) AS v FROM empty) '
        'SELECT count(*) FROM c) FROM t')
    add('correlated constant projection',
        'SELECT id,(WITH c AS(SELECT visit(t.id) AS v) '
        'SELECT v+v FROM c) FROM t')
    add('flat CTE correlated scalar consumer',
        'WITH c AS(SELECT visit(id) AS v FROM t) '
        'SELECT id,(SELECT v FROM c WHERE v=t.id LIMIT 1) FROM t')
    add('flat underlying WHERE sequencing',
        'WITH c AS(SELECT visit(id) AS v FROM t WHERE keep(id)) '
        'SELECT v,v FROM c WHERE v>0 LIMIT 1')
    add('flat outer aggregate consumes values',
        'WITH c AS(SELECT visit(id) AS v FROM t) SELECT sum(v),sum(v+0) FROM c')
    add('flat outer window consumes values',
        'WITH c AS(SELECT visit(id) AS v FROM t) '
        'SELECT v,row_number() OVER(ORDER BY v) FROM c')
    add('flat outer GROUP BY alias',
        'WITH c AS(SELECT visit(y) AS v FROM t) SELECT v,count(*) FROM c GROUP BY v')
    add('flat outer DISTINCT',
        'WITH c AS(SELECT visit(y) AS v FROM t) SELECT DISTINCT v FROM c')
    add('flat ON and qualified wildcard',
        'WITH c AS(SELECT visit(id) AS v FROM t) '
        'SELECT c.* FROM t JOIN c ON t.id=c.v LIMIT 1')
    add('LEFT JOIN constant source preserves single evaluation',
        'WITH c AS(SELECT tick() AS v) SELECT t.id,c.v FROM t LEFT JOIN c ON 1')
    add('RIGHT JOIN constant source preserves single evaluation',
        'WITH c AS(SELECT tick() AS v) SELECT t.id,c.v FROM t RIGHT JOIN c ON t.id=1')
    add('recursive queue preserves computed values',
        'WITH RECURSIVE c(v,n) AS(SELECT tick(),1 UNION ALL '
        'SELECT tick(),n+1 FROM c WHERE n<3) SELECT v,v FROM c')
    add('recursive unused projection remains computed',
        'WITH RECURSIVE c(v,n) AS(SELECT tick(),1 UNION ALL '
        'SELECT tick(),n+1 FROM c WHERE n<3) SELECT count(*) FROM c')
    add('recursive unused relation is skipped',
        'WITH RECURSIVE c(v) AS(SELECT fail_if(2) UNION ALL '
        'SELECT v+1 FROM c WHERE v<3) SELECT 42')
    add('metadata view columns never invoke callbacks', 'PRAGMA table_xinfo(c)',
        setup=['CREATE VIEW c AS SELECT tick() AS v,CAST(id AS TEXT) AS label FROM t'])
    add('metadata recursive view chain never invokes callbacks', 'PRAGMA table_info(c)',
        setup=['CREATE VIEW inner_view AS SELECT fail_if(2) AS v',
               'CREATE VIEW c AS SELECT v FROM inner_view'])
    add('view LIMIT zero never invokes callbacks', 'SELECT * FROM c LIMIT 0',
        setup=['CREATE VIEW c AS SELECT fail_if(id) AS v FROM t'])
    add('used invalid CTE width fails before callbacks',
        'WITH c(x,y) AS(SELECT tick()) SELECT * FROM c')
    add('used invalid column fails before callbacks',
        'WITH c AS(SELECT tick() AS v FROM t) SELECT missing FROM c')
    add('flat projection error stops at failing row',
        'WITH c AS(SELECT fail_if(id) AS v FROM t) SELECT v FROM c')
    add('nested scalar forward dependency',
        'WITH c AS(SELECT (SELECT v FROM d) AS v),'
        'd AS(SELECT tick() AS v) SELECT v,v FROM c')
    add('derived forward dependency',
        'WITH c AS(SELECT v FROM(SELECT v FROM d)),'
        'd AS(SELECT tick() AS v FROM t) SELECT v,v FROM c LIMIT 1')
    add('unused nested WITH declarations do not load sources',
        'WITH c AS(WITH d AS(SELECT missing FROM absent) '
        'SELECT tick() AS v) SELECT v FROM c')
    add('nested WITH declaration shadows unused outer source',
        'WITH c AS(SELECT missing FROM absent) '
        'SELECT (WITH c AS(SELECT tick() AS v) SELECT v FROM c)')
    add('reachable scalar WITH ignores unused invalid sibling',
        'WITH c AS(SELECT tick() AS v),d AS(SELECT missing FROM absent) '
        'SELECT (SELECT v FROM c)')
    add('pushed predicate reads sibling WITH',
        'WITH q(x) AS(VALUES(1),(2)),r(y) AS(VALUES(1),(3)) '
        'SELECT y FROM r WHERE y IN q ORDER BY y')
    add('pushed predicate reads later sibling callback',
        'WITH r(y) AS(VALUES(1),(3)),q(x) AS(SELECT visit(id) FROM t) '
        'SELECT y FROM r WHERE y IN q ORDER BY y')
    add('nested WITH dependency retains outer lexical frame',
        'WITH c AS(WITH e AS(SELECT v FROM d) SELECT v FROM e),'
        'd AS(SELECT tick() AS v) SELECT v FROM c')
    add('used invalid nested width rejects before callbacks',
        'WITH c AS(WITH d(x,y) AS(SELECT tick()) SELECT * FROM d) '
        'SELECT * FROM c')
    add('unused invalid nested width is ignored',
        'WITH c AS(WITH d(x,y) AS(SELECT tick()) SELECT 42) SELECT * FROM c')
    add('unused recursive invalid source is ignored',
        'WITH RECURSIVE c(x) AS(SELECT missing FROM absent UNION ALL '
        'SELECT x+1 FROM c) SELECT 42')
    add('referenced circular source rejects before callbacks',
        'WITH c AS(SELECT * FROM d),d AS(SELECT * FROM c) SELECT * FROM c')
    add('unused unknown function is not resolved',
        'WITH c AS(SELECT no_such_cte_function()) SELECT 42')
    add('unused invalid function arity is not resolved',
        'WITH c AS(SELECT abs(1,2)) SELECT 42')
    add('unused invalid scalar FILTER is not resolved',
        'WITH c AS(SELECT abs(1) FILTER(WHERE 1)) SELECT 42')
    add('used unknown function rejects before callbacks',
        'WITH c AS(SELECT tick(),no_such_cte_function()) SELECT * FROM c')
    add('used invalid function arity rejects with LIMIT zero',
        'WITH c AS(SELECT abs(1,2)) SELECT * FROM c LIMIT 0')
    add('unused unknown function in scalar WITH stays unresolved',
        'SELECT (WITH c AS(SELECT no_such_cte_function()) SELECT 42)')
    for name, sql in [
        ('scalar subquery stops after first row',
         'SELECT id,(SELECT tick() FROM t) FROM t'),
        ('scalar subquery resumes after OFFSET',
         'SELECT id,(SELECT tick() FROM t LIMIT 2 OFFSET 1) FROM t'),
        ('scalar subquery keeps explicit zero LIMIT',
         'SELECT id,(SELECT tick() FROM t LIMIT 0) FROM t'),
        ('scalar ordered output has implicit one-row bound',
         'SELECT (SELECT tick() FROM t ORDER BY y DESC)'),
        ('scalar reverse rowid output has implicit one-row bound',
         'SELECT (SELECT tick() FROM t ORDER BY id DESC)'),
        ('scalar negative LIMIT still has one-row bound',
         'SELECT (SELECT tick() FROM t LIMIT -1)'),
        ('scalar invalid LIMIT retains preparation and runtime error',
         'SELECT (SELECT tick() FROM t LIMIT NULL)'),
        ('uncorrelated IN values are prepared once',
         'SELECT id FROM t WHERE id IN(SELECT visit(id) FROM t)'),
        ('correlated scalar retains live outer values',
         'SELECT id,(SELECT visit(t.id)) FROM t'),
        ('EXISTS skips unused projection',
         'SELECT id,EXISTS(SELECT tick() FROM t) FROM t'),
        ('EXISTS skips unused ORDER BY',
         'SELECT id,EXISTS(SELECT tick() FROM t ORDER BY tick()) FROM t'),
        ('EXISTS validates discarded ORDER BY names',
         'SELECT EXISTS(SELECT id FROM t ORDER BY missing)'),
        ('EXISTS validates discarded ORDER BY ordinal',
         'SELECT EXISTS(SELECT id FROM t ORDER BY 2)'),
        ('EXISTS keeps ORDER-only window inputs',
         'SELECT EXISTS(SELECT id FROM t ORDER BY '
         'row_number() OVER(ORDER BY visit(id)))'),
        ('EXISTS discards ORDER-only aggregate inputs',
         'SELECT EXISTS(SELECT id FROM t ORDER BY sum(visit(id)))'),
        ('EXISTS skips unused DISTINCT projection',
         'SELECT EXISTS(SELECT DISTINCT tick() FROM t)'),
        ('EXISTS retains aggregate inputs',
         'SELECT id,EXISTS(SELECT sum(tick()) FROM t) FROM t'),
        ('EXISTS retains grouped inputs',
         'SELECT EXISTS(SELECT sum(visit(id)) FROM t GROUP BY y)'),
        ('EXISTS retains window inputs',
         'SELECT EXISTS(SELECT tick()+sum(visit(id)) OVER() FROM t)'),
        ('EXISTS discards UNION ALL projections',
         'SELECT EXISTS(SELECT tick() FROM t UNION ALL SELECT tick() FROM t)'),
        ('EXISTS retains UNION set projections',
         'SELECT EXISTS(SELECT tick() FROM t UNION SELECT tick() FROM t)'),
        ('EXISTS retains INTERSECT set projections',
         'SELECT EXISTS(SELECT tick() FROM t INTERSECT SELECT tick() FROM t)'),
        ('EXISTS retains EXCEPT set projections',
         'SELECT EXISTS(SELECT tick() FROM t EXCEPT SELECT tick() FROM t)'),
        ('EXISTS ignores VALUES callbacks',
         'SELECT EXISTS(VALUES(tick()),(tick()))'),
        ('EXISTS flattened CTE projection stays unused',
         'SELECT EXISTS(WITH c AS(SELECT tick() AS v FROM t) SELECT v FROM c)'),
        ('unused derived projection remains needed by JOIN ON',
         'SELECT count(*) FROM(SELECT tick() AS v)c JOIN t ON c.v=t.id'),
        ('unused view projection remains needed by JOIN ON',
         'SELECT count(*) FROM c JOIN t ON c.v=t.id'),
    ]:
        add(name, sql,
            setup=['CREATE VIEW c AS SELECT tick() AS v']
            if name.startswith('unused view') else None)
    return result


def register_callbacks(db, trace):
    serial = 0

    def tick():
        nonlocal serial
        serial += 1
        trace.append(f'tick:{serial}')
        return serial

    def visit(name, value):
        trace.append(f'{name}:{"null" if value is None else value}')
        return value

    def fail_if(value):
        visit('fail_if', value)
        if value == 2:
            raise ValueError('requested projection failure')
        return value

    db.create_function('tick', 0, tick)
    db.create_function('visit', 1, lambda value: visit('visit', value))
    db.create_function('keep', 1, lambda value: visit('keep', value) != 2)
    db.create_function('fail_if', 1, fail_if)


def generate():
    manifest = json.loads((ROOT / 'manifest.json').read_text())
    suites = []
    for encoding, label in [(1, 'UTF-8'), (2, 'UTF-16le'), (3, 'UTF-16be')]:
        generated = []
        for case in cases():
            with sqlite3.connect(':memory:', isolation_level=None) as db:
                assert db.execute('SELECT sqlite_source_id()').fetchone()[0] == PIN
                assert sorted(row[0] for row in db.execute('PRAGMA compile_options')) == manifest['compile_options']
                db.execute(f"PRAGMA encoding='{label}'")
                trace = []
                register_callbacks(db, trace)
                for sql in case['setup']:
                    db.execute(sql)
                assert not trace, case['name']
                observed = dict(case)
                try:
                    cursor = db.execute(case['sql'], case['parameters'])
                    observed['columns'] = [column[0] for column in cursor.description]
                    observed['rows'] = [[encode(value) for value in row] for row in cursor]
                except sqlite3.Error as error:
                    observed['error'] = str(error)
                    observed.pop('rows', None)
                    observed.pop('columns', None)
                observed['trace'] = list(trace)
                generated.append(observed)
        suites.append(dict(encoding=encoding, cases=generated))
    OUTPUT.write_text(json.dumps(dict(source_id=PIN, suites=suites), indent=2)+'\n')
    OUTPUT.with_suffix('.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest()+'\n')
    print(f'Generated {sum(len(s["cases"]) for s in suites)} pinned CTE/view evaluation cases')


if __name__ == '__main__':
    if '--verify' in sys.argv:
        assert hashlib.sha256(OUTPUT.read_bytes()).hexdigest() == OUTPUT.with_suffix('.sha256').read_text().strip()
        print('CTE/view evaluation oracle checksum passed')
    else:
        generate()
