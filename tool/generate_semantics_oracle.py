"""Pinned SQLite M6 functions/aggregate/metadata differential cases."""
import hashlib
import json
import sqlite3
from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode


class DartSum:
    def __init__(self):self.total=None
    def step(self,value):
        if isinstance(value,int):self.total=(self.total or 0)+value
    def finalize(self):return self.total


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
    expressions += [
        '1 IN (1,2)', 'NULL IN ()', 'NULL NOT IN ()', '1 IN (2,NULL)',
        'NULL IN (NULL)', '1 NOT IN (2,NULL)', '1 IN (NULL,1)',
        '2 BETWEEN 1 AND 3', '0 BETWEEN NULL AND -1', '1 NOT BETWEEN 2 AND NULL',
        "'abc' LIKE 'A%'", "'λ😀' LIKE '__'", "'A_C' LIKE 'a!_c' ESCAPE '!'",
        "'abc' NOT LIKE 'z%'", "'AbC' GLOB '[A-Z]*'", "'abc' GLOB '[^A-Z]*'",
        "'abc' GLOB '[a-c][a-c]?'", "']' GLOB '[]]'", "'-' GLOB '[-a]'",
        "'a' GLOB '['", "'a' LIKE 'a!' ESCAPE '!'",
        "CAST('123e2' AS INTEGER)", "CAST('123e2' AS NUMERIC)",
        "CAST('abc' AS REAL)", "CAST('9223372036854775808' AS INTEGER)",
        "CAST('-9223372036854775809' AS INTEGER)", "CAST(1e999 AS INTEGER)",
        "CAST('hello' AS BLOB)", "CAST(X'3132' AS TEXT)",
        "CASE WHEN NULL THEN 1 WHEN 0 THEN 2 ELSE 3 END",
        "CASE 1 WHEN '1' THEN 2 WHEN 1 THEN 3 ELSE 4 END",
        'CASE WHEN 1 THEN 7 ELSE abs(-9223372036854775808) END',
        "'A' = 'a' COLLATE NOCASE", "'a ' COLLATE RTRIM = 'a'", "'λ' = 'Λ' COLLATE NOCASE",
        '5 & 3', '5 | 2', '1 << 63', '-1 >> 64', '1 << -1', '1 << 65',
        '1 + 2 << 1', 'NULL ISNULL', '1 NOTNULL',
    ]
    queries = ['select '+e+' as result' for e in expressions]
    queries += [
        'WITH s AS (SELECT id,value FROM sample WHERE id<=3) SELECT * FROM s ORDER BY id',
        'WITH a AS (SELECT * FROM b), b AS (SELECT id FROM sample WHERE id=2) SELECT * FROM a',
        'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<10) SELECT sum(x),count(*) FROM n',
        'WITH n(x) AS (SELECT 1 UNION SELECT x FROM n) SELECT x FROM n',
        'WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT 10 UNION ALL SELECT x+1 FROM n WHERE x<3) SELECT x FROM n ORDER BY x',

        'select s.id,s.value from sample s where s.id<=3 order by s.id',
        'select s.rowid,s._rowid_,s.oid from sample as s where s.id=128',
        'select a.id,b.id from sample a join sample b on a.id=b.id+1 where a.id<5 order by a.id',
        'select a.id,b.i from sample a left join types b on a.id=b.rowid where a.id<5 order by a.id',
        'select a.id,b.i from sample a right join types b on a.id=b.rowid order by b.rowid',
        'select a.id,b.i from sample a full join types b on a.id=b.rowid where a.id<=2 or a.id is null order by b.rowid,a.id',
        'select a.id,b.id from sample a cross join sample b where a.id<=2 and b.id<=2 order by a.id,b.id',
        'select a.id,b.id from sample a, sample b where a.id=b.id and a.id<=3 order by a.id',
        'select * from sample a join sample b using(id,value) where id<=2 order by id',
        'select a.*,b.value from sample a natural join sample b where id<=2 order by id',
        'select d.id,d.v from (select id,value as v from sample where id<=3) d order by d.id desc',
        'select id from sample where id in (select rowid from types) order by id',
        'select id from sample where id not in (select rowid from types) order by id limit 3',
        'select id,(select count(*) from types where rowid<=s.id) as n from sample s where id<=3 order by id',
        'select id from sample s where exists(select 1 from types t where t.rowid=s.id) order by id',
        'select (select id from sample where id=999999) as n',
        'select (select id from sample order by id desc) as n',
        'select 2 as n union select 1 order by n',
        'select 1 as n union all select 1 union all select 2 order by n desc limit 2',
        'select id from sample where id<=3 intersect select rowid from types order by id',
        'select id from sample where id<=3 except select rowid from types order by id',
        'select 1,2 union select 3',
        'select (select id,value from sample limit 1)',
        'select id from sample a join sample b on a.id=b.id',

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
    expressions += [
        '1 IN (1,2)', 'NULL IN ()', 'NULL NOT IN ()', '1 IN (2,NULL)',
        'NULL IN (NULL)', '1 NOT IN (2,NULL)', '1 IN (NULL,1)',
        '2 BETWEEN 1 AND 3', '0 BETWEEN NULL AND -1', '1 NOT BETWEEN 2 AND NULL',
        "'abc' LIKE 'A%'", "'λ😀' LIKE '__'", "'A_C' LIKE 'a!_c' ESCAPE '!'",
        "'abc' NOT LIKE 'z%'", "'AbC' GLOB '[A-Z]*'", "'abc' GLOB '[^A-Z]*'",
        "'abc' GLOB '[a-c][a-c]?'", "']' GLOB '[]]'", "'-' GLOB '[-a]'",
        "'a' GLOB '['", "'a' LIKE 'a!' ESCAPE '!'",
        "CAST('123e2' AS INTEGER)", "CAST('123e2' AS NUMERIC)",
        "CAST('abc' AS REAL)", "CAST('9223372036854775808' AS INTEGER)",
        "CAST('-9223372036854775809' AS INTEGER)", "CAST(1e999 AS INTEGER)",
        "CAST('hello' AS BLOB)", "CAST(X'3132' AS TEXT)",
        "CASE WHEN NULL THEN 1 WHEN 0 THEN 2 ELSE 3 END",
        "CASE 1 WHEN '1' THEN 2 WHEN 1 THEN 3 ELSE 4 END",
        'CASE WHEN 1 THEN 7 ELSE abs(-9223372036854775808) END',
        "'A' = 'a' COLLATE NOCASE", "'a ' COLLATE RTRIM = 'a'", "'λ' = 'Λ' COLLATE NOCASE",
        '5 & 3', '5 | 2', '1 << 63', '-1 >> 64', '1 << -1', '1 << 65',
        '1 + 2 << 1', 'NULL ISNULL', '1 NOTNULL',
    ]
    queries = [q.replace('count(n),sum(n),total(n),avg(n)', 'count(value),sum(id),total(id),avg(id)') for q in queries]
    queries += [
      'SELECT min(id),value FROM sample',
      'SELECT max(id),value FROM sample',
      'SELECT min(id),value FROM sample WHERE 0',
      'SELECT id%3 AS bucket,count(*) AS n FROM sample GROUP BY 1 HAVING n>2 ORDER BY bucket',
      'SELECT id%3 AS bucket,count(*) AS n FROM sample GROUP BY bucket HAVING n>2 ORDER BY bucket',
      'SELECT id%3,count(*),min(id),value FROM sample GROUP BY id%3 ORDER BY 1',
      'SELECT count(*) FROM sample GROUP BY 0',
      'SELECT count(*) FROM sample GROUP BY 2',
    ]
    queries += [
      "SELECT id FROM sample WHERE value='row-001' ORDER BY id",
      "SELECT rowid FROM types WHERE b=X'00ff' ORDER BY rowid",
      "SELECT rowid FROM types WHERE b=NULL ORDER BY rowid",
      "SELECT rowid FROM boundary WHERE v=X'' ORDER BY rowid",
      "SELECT id FROM sample WHERE value=CAST(1 AS NUMERIC) ORDER BY id",
      "SELECT id FROM sample WHERE value='ROW-001' COLLATE NOCASE ORDER BY id",
    ]
    queries += [
      "PRAGMA table_xinfo(sample)","PRAGMA table_xinfo(keyed)",
      "PRAGMA index_list(sample)","PRAGMA index_list(keyed)","PRAGMA index_list(missing)",
      "PRAGMA index_info(sample_value)","PRAGMA index_xinfo(sample_value)","PRAGMA index_info(missing)",
      "PRAGMA foreign_key_list(sample)","PRAGMA foreign_key_list(missing)",
    ]
    queries += [
      'SELECT id,row_number() OVER (ORDER BY id DESC),rank() OVER (ORDER BY id%3),dense_rank() OVER (ORDER BY id%3) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,percent_rank() OVER (ORDER BY id%3),cume_dist() OVER (ORDER BY id%3),ntile(3) OVER (ORDER BY id) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,row_number() OVER (PARTITION BY id%2 ORDER BY id DESC),sum(id) OVER (PARTITION BY id%2) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,sum(id) OVER (ORDER BY id),count(*) OVER (),avg(id) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,sum(id) OVER (ORDER BY id%3),count(*) OVER (ORDER BY id%3 RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,lag(id) OVER (ORDER BY id),lead(id,2,99) OVER (ORDER BY id),lag(id,-1) OVER (ORDER BY id),lag(id,NULL,99) OVER (ORDER BY id),lag(id,1.5,99) OVER (ORDER BY id) FROM sample WHERE id>0 AND id<=5 ORDER BY id',
      'SELECT id,first_value(id) OVER (ORDER BY id ROWS 1 PRECEDING),last_value(id) OVER (ORDER BY id),nth_value(id,2) OVER (ORDER BY id),ntile(20) OVER (ORDER BY id) FROM sample WHERE id>0 AND id<=5 ORDER BY id',
      'SELECT id,min(id) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING),max(id) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING) FROM sample WHERE id>0 AND id<=5 ORDER BY id',
      'SELECT id FROM sample WHERE row_number() OVER ()=1',
      'SELECT sum(DISTINCT id) OVER () FROM sample',
      'SELECT sum(id) OVER (ROWS BETWEEN CURRENT ROW AND 1 PRECEDING) FROM sample',
      'SELECT row_number() FROM sample',
      'SELECT ntile(0) OVER () FROM sample',
      'SELECT nth_value(id,0) OVER () FROM sample',
    ]
    queries += [
      'SELECT sum(id) FILTER (WHERE id>2),count(*) FILTER (WHERE id>2),count(*) FILTER (WHERE NULL),min(id) FILTER (WHERE id>2),value FROM sample WHERE id>0 AND id<=5',
      'SELECT id%2,count(*) FILTER (WHERE id>2) FROM sample WHERE id>0 AND id<=5 GROUP BY 1 ORDER BY 1',
      'SELECT id,sum(id) FILTER (WHERE id%2=0) OVER (ORDER BY id ROWS 2 PRECEDING) FROM sample WHERE id>0 AND id<=5 ORDER BY id',
      'SELECT lower(id) FILTER (WHERE 1) FROM sample',
      'SELECT sum(id) FILTER (WHERE count(*)>1) FROM sample',
      'SELECT rank() FILTER (WHERE 1) OVER () FROM sample',
    ]
    queries += [
      'SELECT id,sum(id) OVER (ORDER BY id%3 GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING),sum(id) OVER (ORDER BY id%3 GROUPS CURRENT ROW) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,count(*) OVER (ORDER BY id%3 GROUPS BETWEEN 2 PRECEDING AND 1 PRECEDING),count(*) OVER (ORDER BY id%3 GROUPS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,sum(id) OVER (ORDER BY id RANGE BETWEEN 1.5 PRECEDING AND 2 FOLLOWING),sum(id) OVER (ORDER BY id DESC RANGE BETWEEN 1 PRECEDING AND 2 FOLLOWING) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,sum(id) OVER (ORDER BY id%3 ROWS UNBOUNDED PRECEDING EXCLUDE CURRENT ROW),sum(id) OVER (ORDER BY id%3 GROUPS UNBOUNDED PRECEDING EXCLUDE GROUP),sum(id) OVER (ORDER BY id%3 RANGE UNBOUNDED PRECEDING EXCLUDE TIES) FROM sample WHERE id>0 AND id<=8 ORDER BY id',
      'SELECT id,count(*) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP),count(*) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE TIES) FROM sample WHERE id>0 AND id<=5 ORDER BY id',
      'SELECT count(*) OVER (ORDER BY t RANGE 1 PRECEDING) FROM types ORDER BY rowid',
      'SELECT sum(id) OVER (ORDER BY id,value RANGE 1 PRECEDING) FROM sample',
      'SELECT sum(id) OVER (ROWS -1 PRECEDING) FROM sample',
      'SELECT sum(id) OVER (GROUPS 1.5 PRECEDING) FROM sample',
      'SELECT sum(id) OVER (ORDER BY id RANGE NULL PRECEDING) FROM sample',
      'SELECT id,count(*) OVER (ROWS 9223372036854775807 PRECEDING) FROM sample WHERE id>0 AND id<=3 ORDER BY id',
    ]
    queries += [
      'SELECT id,row_number() OVER w,sum(id) OVER w FROM sample WHERE id>0 AND id<=8 WINDOW w AS (PARTITION BY id%2 ORDER BY id) ORDER BY id',
      'SELECT id,sum(id) OVER (w ROWS 1 PRECEDING),sum(id) OVER w FROM sample WHERE id>0 AND id<=8 WINDOW w AS (ORDER BY id) ORDER BY id',
      'SELECT id,row_number() OVER ordered FROM sample WHERE id>0 AND id<=8 WINDOW base AS (PARTITION BY id%2),ordered AS (base ORDER BY id DESC) ORDER BY id',
      'SELECT id,sum(id) OVER w FROM sample WHERE id>0 AND id<=5 WINDOW w AS (ORDER BY id ROWS 1 PRECEDING) ORDER BY id',
      'SELECT sum(id) OVER (w) FROM sample WINDOW w AS (ROWS 1 PRECEDING)',
      'SELECT sum(id) OVER missing FROM sample',
      'SELECT sum(id) OVER (w ORDER BY value) FROM sample WINDOW w AS (ORDER BY id)',
      'SELECT sum(id) OVER (w PARTITION BY value) FROM sample WINDOW w AS (ORDER BY id)',
    ]
    queries += [
      'SELECT i,rowid FROM types ORDER BY i NULLS LAST,rowid',
      'SELECT i,rowid FROM types ORDER BY i DESC NULLS FIRST,rowid',
      'SELECT i,row_number() OVER (ORDER BY i NULLS LAST),rank() OVER (ORDER BY i DESC NULLS FIRST),sum(rowid) OVER (ORDER BY i DESC NULLS FIRST RANGE 2 PRECEDING) FROM types ORDER BY rowid',
      'SELECT NULL AS n UNION ALL SELECT 1 UNION ALL SELECT 2 ORDER BY n NULLS LAST',
      'SELECT NULL AS n UNION ALL SELECT 1 UNION ALL SELECT 2 ORDER BY n DESC NULLS FIRST',
      'SELECT id FROM sample ORDER BY id NULLS MIDDLE',
    ]
    queries += [
      'SELECT id%3 AS k,count(*) AS n,sum(count(*)) OVER (ORDER BY id%3),rank() OVER (ORDER BY count(*) DESC) FROM sample WHERE id>0 AND id<=8 GROUP BY id%3 ORDER BY k',
      'SELECT id%3 AS k,count(*) AS n,sum(count(*)) OVER () FROM sample WHERE id>0 AND id<=8 GROUP BY id%3 HAVING count(*)>2 ORDER BY k',
      'SELECT id%2 AS k,sum(id),lag(sum(id)) OVER (ORDER BY id%2),avg(sum(id)) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM sample WHERE id>0 AND id<=8 GROUP BY id%2 ORDER BY k',
      'SELECT sum(count(*)) OVER () FROM empty',
      'SELECT row_number() OVER (ORDER BY count(*)) FROM sample',
      'SELECT sum(count(*)) FROM sample',
      'SELECT sum(row_number() OVER ()) FROM sample',
      'SELECT row_number() OVER (ORDER BY row_number() OVER ()) FROM sample',
    ]
    queries += [
      'SELECT dart_twice(2),dart_twice(NULL)',
      'SELECT id%2,dart_sum(id),dart_sum(DISTINCT id),dart_sum(id) FILTER (WHERE id>2) FROM sample WHERE id>0 AND id<=6 GROUP BY id%2 ORDER BY 1',
      'SELECT dart_sum(id) FROM sample WHERE 0',
      'SELECT id%2,sum(dart_sum(id)) OVER (ORDER BY id%2) FROM sample WHERE id>0 AND id<=6 GROUP BY id%2 ORDER BY 1',
      'SELECT dart_twice()',
      'SELECT dart_sum(id) OVER () FROM sample',
    ]
    queries += ['SELECT '+e+' AS result' for e in [
      "instr('λ😀abc','a')","instr('a'||char(0)||'b','b')","instr(X'000102',X'0102')","instr('abc','')","instr(NULL,'a')",
      "octet_length('λ😀')","octet_length(X'00ff')","octet_length(123)","octet_length(NULL)",
      "concat(NULL,NULL)","concat('a',NULL,2)","concat_ws('-',NULL,'',2)","concat_ws(NULL,'a','b')",
      "unhex('00--FF','-')","unhex('0')","unhex('GG')","unhex('12','1')","unhex(NULL)",
      "sign(-2)","sign('1x')","sign(X'31')","sign('2.5')","sign(NULL)",
      "iif(0,1)","if(1,2)","iif(0,1,0,2,3)","iif(0,1,1,4,abs(-9223372036854775808))",
      'sqrt(9)','sqrt(-1)','pow(2,10)','power(0,-1)','mod(-5,2)','mod(5,0)',
      'ceil(2)','ceil(2.5)',"ceil('2')",'floor(-2.1)','trunc(-2.9)',
      'log(100)','log(2,8)','ln(1)','log2(8)','log10(-1)',
      'sin(0)','cos(0)','tan(0)','acos(1)','asin(0)','atan(0)','atan2(0,1)',
      'sinh(0)','cosh(0)','tanh(0)','asinh(0)','acosh(1)','atanh(0)',
      'exp(0)','degrees(0)','radians(0)','pi()',"sqrt('x')",'sqrt(NULL)',
    ]]
    queries += ['SELECT '+e+' AS result' for e in [
      "date('2000-02-29')","datetime('2000-01-01 12:34:56.789')","time('12:34:56.789','subsec')",
      "datetime('2020-01-01 24:00')","datetime('2020-01-01 24:00','+0 days')", "date('2023-02-30')",
      "datetime('2000-01-01 12:00:00+02:30')","julianday('2000-01-01 12:00')","unixepoch('1970-01-01')",
      "datetime(0,'unixepoch')","datetime(-0.1,'unixepoch')","unixepoch(-0.1,'unixepoch')","datetime(2451545)",
      "datetime(1000000000,'auto')","date(2451545,'julianday')","time('2000-01-01 23:59:59.9995','subsec')",
      "date('2020-02-29','+1 year')","date('2020-02-29','+1 year','floor')","date('2020-01-31','+1 month','floor')",
      "datetime('2020-01-01','+1.5 days','-2 hours')","date('2020-01-15','start of month')","date('2020-01-15','start of year')",
      "date('2020-01-01','weekday 0')","date('2020-01-01','weekday 3')", "date('bad')","datetime(NULL)","date('2020-13-01')",
      "datetime(99999999999999)","date('2020-01-01','bad modifier')","date('2020-01-01','unixepoch')",
      "strftime('%Y-%m-%d %H:%M:%S %f %j %w %u %W %U %V %G','2021-01-01 03:04:05.678')",
      "strftime('%F %R %T %I %l %k %p %P %%','2020-01-01 13:02:03')","strftime('%J %s','2000-01-01')","strftime('%Q','2000-01-01')",
      "unixepoch('2000-01-01 00:00:00.123','subsec')","strftime('%s','2000-01-01 00:00:00.123','subsec')",
    ]]
    queries += [
      'SELECT id FROM sample WHERE id>127 AND id<=130 ORDER BY id',
      'SELECT id FROM sample WHERE 127<id AND 130>=id ORDER BY id',
      'SELECT id FROM sample WHERE id>130 AND id<127 ORDER BY id',
      "SELECT id FROM sample WHERE value>='row-100' AND value<'row-105' ORDER BY id",
      "SELECT rowid FROM types WHERE b>=X'00' AND b<X'ff' ORDER BY rowid",
      'SELECT id FROM sample WHERE id>127.5 AND id<130.5 ORDER BY id',
    ]
    queries += ['PRAGMA integrity_check','PRAGMA quick_check(1)','PRAGMA foreign_key_check']
    queries += ['SELECT '+e+' AS result' for e in [
      "timediff('2024-02-29','2023-02-28')", "timediff('2023-02-28','2024-02-29')", "timediff('2023-03-15','2023-02-15')",
      "timediff('2023-02-28','2023-01-31')", "timediff('2020-01-01 01:02:03.123','2019-11-30 23:59:59.999')", "timediff(NULL,'2000-01-01')",
      "datetime('2023-01-31',timediff('2023-02-28','2023-01-31'))", "datetime('2024-02-29',timediff('2023-02-28','2024-02-29'))",
      "datetime('2000-01-01','+01:02:03.123')", "datetime('2000-01-01','-0001-02-03 04:05:06.789')",
      "date(0)","date('0000-02-29')","date('9999-12-31','+1 day')","date('2020-01-01','weekday 7')",
    ]]
    queries += ['SELECT '+e+' AS result' for e in [
      'round(2.675,2)','round(1.005,2)','round(4.05,1)','round(-1.25,1)','round(0.49999999999999994)',
      'round(1.23456789,30)','round(0.000000000000000000000000123456789,30)','round(1e999,2)',
      "round('12.34x',1)","round(12.34,'bad')",'round(NULL,2)','round(1,-5)','round(-0.1)',
    ]]
    queries += ['SELECT dart_counter() AS v',
      'SELECT dart_counter() AS v FROM sample WHERE id>0 AND id<=3 ORDER BY dart_counter()',
      'SELECT dart_counter() AS v FROM sample WHERE id>0 AND id<=3 ORDER BY v',
      'SELECT abs(-9223372036854775808),count(*) FROM sample HAVING 0',
      'SELECT id AS value,value AS old_value FROM sample WHERE id>0 AND id<=3 ORDER BY value DESC',
      'SELECT i FROM types ORDER BY 1 COLLATE BINARY NULLS LAST',
      'SELECT id FROM sample ORDER BY 0 COLLATE BINARY',
      'SELECT id%2,sum(id) FILTER (WHERE id<3) FROM sample WHERE id>0 AND id<=5 GROUP BY id%2 ORDER BY sum(id) FILTER (WHERE id>3)',
    ]
    queries += ['SELECT i FROM types ORDER BY TRUE', 'SELECT i FROM types ORDER BY FALSE',
      'SELECT i FROM types ORDER BY +1 NULLS LAST','SELECT i FROM types ORDER BY -(-1) NULLS LAST',
      'SELECT i FROM types ORDER BY -1','SELECT count(*) FROM sample GROUP BY TRUE',
      'SELECT id%2,count(*) FROM sample WHERE id>0 AND id<=5 GROUP BY +1 ORDER BY 1',
      'SELECT count(*) FROM sample GROUP BY -1',
      "SELECT value AS v,count(*) FROM sample GROUP BY 1 COLLATE NOCASE ORDER BY v LIMIT 3",
    ]
    queries += [
      "SELECT v='A' FROM (SELECT 'a' COLLATE NOCASE AS v)",
      "SELECT v='a' FROM (SELECT 'a ' COLLATE RTRIM AS v)",
      "SELECT v FROM (SELECT 'b' COLLATE NOCASE AS v UNION ALL SELECT 'A') ORDER BY v",
      "WITH c(v) AS (SELECT 'a' COLLATE NOCASE) SELECT v='A' FROM c",
      "SELECT v='A' FROM (SELECT v FROM (SELECT 'a' COLLATE NOCASE AS v))",
      "SELECT v,count(*) FROM (SELECT 'a' COLLATE NOCASE AS v UNION ALL SELECT 'A') GROUP BY v",
      "SELECT v FROM (SELECT 'a' COLLATE NOCASE AS v) UNION SELECT 'A'",
      "SELECT typeof(v) FROM (SELECT CAST(1 AS REAL) AS v)",
    ]
    queries += [
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT 5) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT 5 OFFSET 3) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<5 LIMIT -1 OFFSET 2) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT 0) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT dart_counter() UNION ALL SELECT x+1 FROM c LIMIT 0) SELECT dart_counter() FROM (SELECT count(*) FROM c)',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT NULL) SELECT x FROM c',
      "WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT '3') SELECT x FROM c",
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT 2.5) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION SELECT (x+1)%4 FROM c LIMIT 10 OFFSET 1) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<3 UNION ALL SELECT x+2 FROM c WHERE x<3 LIMIT 10) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<3 ORDER BY 1 DESC) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<3 ORDER BY missing LIMIT 2) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT sum(x) FROM c LIMIT 2) SELECT x FROM c',
    ]
    for order in ['2,1', '2 DESC,1 DESC', '1 DESC', '2 DESC,1', '2,1 DESC']:
      for tail in ['LIMIT 7', 'LIMIT 4 OFFSET 3']:
        queries.append('WITH RECURSIVE tree(x,depth) AS(SELECT 1,0 UNION ALL SELECT x*2+branch,depth+1 FROM tree CROSS JOIN (SELECT 0 AS branch UNION ALL SELECT 1) WHERE depth<3 ORDER BY '+order+' '+tail+') SELECT x,depth FROM tree')
    queries += ['WITH c AS(SELECT dart_counter() AS x) SELECT x FROM c', 'WITH c AS(SELECT dart_counter() AS x UNION ALL SELECT dart_counter()) SELECT x FROM c']
    queries += [
      "WITH RECURSIVE c(x) AS(SELECT 'b' AS x UNION ALL SELECT 'A' UNION ALL SELECT x||'z' FROM c WHERE length(x)<2 ORDER BY x COLLATE NOCASE LIMIT 5) SELECT x FROM c",
      "WITH RECURSIVE c(x) AS(SELECT 'a' COLLATE NOCASE UNION SELECT 'A' FROM c LIMIT 5) SELECT x FROM c",
      "WITH RECURSIVE c(x) AS(SELECT NULL AS x UNION ALL SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<3 ORDER BY 1 NULLS LAST LIMIT 5) SELECT x FROM c"
    ]
    queries += [
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT 1,2 FROM c LIMIT 0) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT missing FROM c LIMIT 0) SELECT x FROM c',
      'WITH RECURSIVE c(x) AS(SELECT 1 UNION ALL SELECT a.x+b.x FROM c a JOIN c b LIMIT 5) SELECT x FROM c'
    ]
    queries += [
      'VALUES(1,2)', 'VALUES(1),(2),(3)', "VALUES(NULL,X'00ff'),(1,'λ😀')",
      'SELECT * FROM (VALUES(3),(1),(2)) ORDER BY column1',
      'WITH c(a,b) AS(VALUES(1,2),(3,4)) SELECT a,b,a+b FROM c ORDER BY a',
      'WITH RECURSIVE c(x) AS(VALUES(1),(2) UNION SELECT x+1 FROM c WHERE x<4 LIMIT 3) SELECT x FROM c',
      'VALUES(1) UNION SELECT 2 ORDER BY 1 DESC LIMIT 1',
      'SELECT 1 UNION ALL VALUES(2),(3)',
      'SELECT (VALUES(1),(2))', 'SELECT 2 IN(VALUES(1),(2)),NULL IN(VALUES(1),(NULL))',
      'VALUES(1),(2,3)', 'VALUES(1) ORDER BY 1', 'VALUES(1) LIMIT 1',
      'SELECT 1 UNION ALL VALUES(2) ORDER BY 1',
      'VALUES(sum(1)),(sum(2))', 'VALUES(row_number() OVER()),(row_number() OVER())',
      'VALUES(dart_counter()),(dart_counter())',
      'SELECT id,(VALUES(id+1)) FROM sample WHERE id>0 AND id<3 ORDER BY id',
    ]
    queries += ['VALUES(sum(1),sum(2))', 'VALUES(sum(1)) UNION SELECT 2', 'SELECT 1 UNION VALUES(sum(2))', 'VALUES(1),(sum(2))']
    queries += [
      "SELECT x='1' FROM (SELECT CAST(1 AS INT) AS x)",
      "SELECT x=1 FROM (SELECT CAST('1' AS TEXT) AS x)",
      "WITH c(x) AS(SELECT CAST(1 AS REAL)) SELECT x='1',typeof(x) FROM c",
      "SELECT x='1' FROM (SELECT CAST(1 AS INT) AS x LIMIT 0)"
    ]
    queries += ["SELECT 1 AS 'λ😀'", "SELECT 1 'value'", "SELECT a.x FROM (SELECT 1 AS x) AS 'a'", "SELECT 1 AS '',2 AS ''"]
    cases = []
    for fixture in manifest['fixtures']:
        with sqlite3.connect(f"file:{ROOT/fixture['file']}?mode=ro",uri=True) as c:
            c.create_function('dart_twice',1,lambda value:None if value is None else value*2)
            c.create_aggregate('dart_sum',1,DartSum)
            for sql in queries:
                counter=[0]
                def next_counter():
                    counter[0]+=1
                    return counter[0]
                c.create_function('dart_counter',0,next_counter)
                parameters = [128] if sql.endswith('id=?') else []
                case={'file':fixture['file'],'sql':sql,'parameters':[encode(v) for v in parameters]}
                try:
                    cursor = c.execute(sql,parameters)
                    case.update({'columns':[v[0] for v in cursor.description],
                                 'rows':[[encode(v) for v in row] for row in cursor]})
                except sqlite3.Error as error:
                    case['error']=str(error)
                cases.append(case)
    path = ROOT/'semantics_oracle.json'
    path.write_text(json.dumps(cases,indent=2,ensure_ascii=False,allow_nan=False)+'\n')
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
