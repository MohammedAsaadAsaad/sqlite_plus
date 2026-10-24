"""Pinned SQLite M6 functions/aggregate/metadata differential cases."""
import hashlib
import json
import sqlite3
from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


def main():
    manifest = json.loads((ROOT/'manifest.json').read_text())
    with sqlite3.connect(':memory:') as c:
        if c.execute('select sqlite_source_id()').fetchone()[0] != PIN:
            raise RuntimeError('Wrong SQLite source ID')
        if sorted(r[0] for r in c.execute('pragma compile_options')) != manifest['compile_options']:
            raise RuntimeError('Wrong SQLite compile options')
    expressions = [
        "abs(-7)","abs(-1.25)","abs('12')","abs('x')","abs(NULL)",
        "length(1e100)","length(-0.0)","quote(1e100)","quote(1e999)","quote(-1e999)","quote(1.2345678901234567)","quote(1e-5)","length('λ😀')","length(X'00ff')","length('')","length(NULL)",
        "lower('AbCλ')","upper('aBcλ')","typeof(1)","typeof(1.0)","typeof(X'')","typeof(NULL)",
        "coalesce(NULL,7,8)","coalesce(NULL,NULL)","ifnull(0,9)","nullif(1,1)","nullif(1,'1')",
        "iif(0,abs(-9223372036854775808),4)","iif(NULL,1,2)",
        "hex('λ😀')","hex(X'00ff')","hex(NULL)","quote('a''b')","quote(NULL)","quote(X'00ff')",
        "unicode('😀')","unicode('')","char(65,955,128512)","char(NULL,-1,1114112)",
        "substr('λ😀abc',2,3)","substr('abcdef',-3,2)","substr('abcdef',0,3)",
        "substr('abcdef',4,-2)","substr('abcdef',-99,100)","substr(X'0001020304',2,2)",
        "substr('abcdef',-99,1)","substr('abcdef',-99,-1)","substr('abcdef',999,-2)","substring('abc',2)","replace('abab','ab','x')","replace('abc','','x')",
        "trim('  x  ')","ltrim('xyxabcxy','xy')","rtrim('xyxabcxy','xy')",
        "trim('λλxλλ','λ')","length(zeroblob(4))","hex(zeroblob(-1))",
        "min('λ','😀')","max('λ','😀')","min(1,3,2)","max(1,'a',X'00')","min(1,NULL,3)",
    ]
    queries = ['select '+e+' as result' for e in expressions]
    queries += [
        'select count(*),count(),count(n),sum(n),total(n),avg(n),min(id),max(id) from sample where id<4',
        'select count(*),count(value),sum(id),total(id),avg(id),min(id),max(id) from sample where 0',
        'select count(*),count(n),sum(i),total(i),avg(i),min(i),max(i) from types where rowid>=0 and rowid<128',
        'select sum(t),total(t),avg(t) from types',
        'select avg(i),total(i),avg(r),sum(r),total(r) from types',
        'select min(t),max(t) from types',
        'select coalesce(1,sum(i)) from types',
        'select iif(0,sum(i),1) from types',
        'select abs(-9223372036854775808),count(*) from sample limit 0',
        'select n,count(*),min(i),max(i) from types group by n order by n',
        'select value,count(*) from sample group by value having count(*)>0 order by value limit 4',
        'select count(distinct n),count(distinct t) from types',
        "select group_concat(id),group_concat(value,'|') from sample where id<=3",
        'select abs(sum(id)) from sample where id<4',
        'select count(*) as c from sample having count(*)>5 order by c',
        'select sum(id) from sample where id=?',
        'select id from sample where id=128',
        'select id from sample where id=128.0 and value is not null',
        "select id from sample where '128'=id",
        'select id from sample where id=999999',
        'select rowid,i from types where rowid=-9223372036854775808',
        'select rowid,i from types where rowid=9223372036854775807',
        'select rowid,i from types where rowid=-1',
        'select rowid,i from types where rowid=0',
        'PRAGMA page_size','PRAGMA page_count','PRAGMA freelist_count',
        'PRAGMA user_version','PRAGMA schema_version','PRAGMA application_id','PRAGMA encoding',
        'PRAGMA table_info(sample)','PRAGMA table_info(types)','PRAGMA table_info(keyed)',
        'PRAGMA table_info(missing)',
    ]
    # sample has no n; aggregate its value column instead.
    queries = [q.replace('count(n),sum(n),total(n),avg(n)', 'count(value),sum(id),total(id),avg(id)') for q in queries]
    cases = []
    for fixture in manifest['fixtures']:
        with sqlite3.connect(f"file:{ROOT/fixture['file']}?mode=ro",uri=True) as c:
            for sql in queries:
                parameters = [128] if '?' in sql else []
                case={'file':fixture['file'],'sql':sql,'parameters':[encode(v) for v in parameters]}
                try:
                    cursor = c.execute(sql,parameters)
                    case.update({'columns':[v[0] for v in cursor.description],
                                 'rows':[[encode(v) for v in row] for row in cursor]})
                except sqlite3.OperationalError as error:
                    case['error']=str(error)
                cases.append(case)
    path = ROOT/'semantics_oracle.json'
    path.write_text(json.dumps(cases,indent=2,ensure_ascii=False)+'\n')
    (ROOT/'semantics_oracle.sha256').write_text(hashlib.sha256(path.read_bytes()).hexdigest()+'\n')
    print(f'Wrote {len(cases)} M6 oracle cases')


if __name__=='__main__':
    import sys
    if '--verify' in sys.argv:
        if hashlib.sha256((ROOT/'semantics_oracle.json').read_bytes()).hexdigest() != (ROOT/'semantics_oracle.sha256').read_text().strip():
            raise RuntimeError('M6 oracle checksum mismatch')
        print('M6 oracle checksum verified')
    else:
        main()
