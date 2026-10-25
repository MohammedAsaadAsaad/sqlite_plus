"""Development-only TRUE/FALSE fallback-name oracle for the pinned SQLite."""
import hashlib,json,sqlite3,sys
from generate_fixtures import PIN,ROOT
from generate_sql_oracle import encode
PATH=ROOT/'boolean_name_oracle.json'
SETUP=[
 'CREATE TABLE plain(x INT)', 'INSERT INTO plain VALUES(0),(2),(NULL)',
 'CREATE TABLE flags("true" INT,"false" TEXT,x INT)',
 "INSERT INTO flags VALUES(9,'value',3),(0,'0',0),(NULL,NULL,NULL)",
 'CREATE TABLE one_true("true" TEXT)', "INSERT INTO one_true VALUES('A'),('b'),(NULL)",
 'CREATE TABLE second("true" INT)', 'INSERT INTO second VALUES(1)',
 'CREATE TABLE empty_flags("true" INT,"false" TEXT)',
]

def generate():
 manifest=json.loads((ROOT/'manifest.json').read_text())
 c=sqlite3.connect(':memory:');assert c.execute('SELECT sqlite_source_id()').fetchone()[0]==PIN
 assert sorted(row[0] for row in c.execute('PRAGMA compile_options'))==manifest['compile_options']
 for sql in SETUP:c.execute(sql)
 queries=[]
 for source in ['', ' FROM plain', ' FROM flags', ' FROM one_true', ' FROM empty_flags']:
  for value in ['true','false','TRUE','FALSE','(true)','(false)','typeof(true)','typeof(false)','true+false','NOT true','true IS false','true IS NOT false','true IS NULL','CASE true WHEN 9 THEN 1 ELSE 0 END','(true,false)=(9,\'value\')']:
   queries.append('SELECT '+value+source)
 for lhs in ['NULL','0','1','2',"'2'",'x']:
  for rhs in ['TRUE','FALSE','(TRUE)','(FALSE)','+TRUE','TRUE+0','FALSE+1','TRUE COLLATE BINARY','(FALSE COLLATE NOCASE)']:
   for op in ['IS','IS NOT','IS DISTINCT FROM','IS NOT DISTINCT FROM']:
    queries.append(f'SELECT {lhs} {op} {rhs} FROM flags')
    if lhs!='x':queries.append(f'SELECT {lhs} {op} {rhs}')
 queries += [
  'SELECT 5 AS true WHERE true=5', 'SELECT 0 AS true WHERE true',
  'SELECT 7 AS false WHERE false=7', 'SELECT true AS true WHERE true',
  'SELECT false AS true,true AS false WHERE true',
  'SELECT true AS false,false AS true WHERE false',
  'SELECT x AS true FROM plain WHERE true=2',
  'SELECT x AS false FROM plain WHERE false=2',
  'SELECT x AS true FROM flags WHERE true=9',
  'SELECT x AS false FROM flags WHERE false=\'value\'',
  'SELECT x AS true,count(*) FROM plain GROUP BY true ORDER BY true',
  'SELECT count(*) AS true FROM plain HAVING true',
  'SELECT count(*) AS false FROM plain HAVING false=3',
  'SELECT count(*) AS true FROM plain WHERE true',
  'SELECT count(*) AS true FROM empty_flags WHERE true',
  'SELECT 2 AS true FROM flags ORDER BY true',
  'SELECT true FROM flags,second', 'SELECT false FROM flags,second',
  'SELECT true FROM empty_flags,second WHERE 0',
  'SELECT flags.true,second.true FROM flags,second',
  'SELECT main.flags.true FROM main.flags',
  'SELECT q.true FROM flags AS q',
  'SELECT (SELECT true) FROM flags',
  'SELECT (SELECT true FROM plain LIMIT 1) FROM flags',
  'SELECT (SELECT true FROM one_true LIMIT 1) FROM flags',
  'SELECT true,false FROM (SELECT 9 AS true,8 AS false)',
  'WITH c AS (SELECT true AS true,false AS false) SELECT true,false FROM c',
  'WITH c(true,false) AS (VALUES(9,8)) SELECT true,false FROM c',
  'SELECT true FROM flags UNION ALL SELECT true FROM one_true',
  'SELECT x AS true FROM plain JOIN second ON true=second.true',
  'SELECT tick() AS true WHERE true',
  'SELECT tick() AS false WHERE false>0',
  'SELECT tick() AS true WHERE FALSE',
  'SELECT false AS true,tick() AS false WHERE true',
 ]
 cases=[];calls=[0]
 def tick():calls[0]+=1;return calls[0]
 c.create_function('tick',0,tick)
 for sql in dict.fromkeys(queries):
  calls[0]=0;case={'sql':sql}
  try:
   cursor=c.execute(sql);case['columns']=[row[0] for row in cursor.description];case['rows']=[[encode(v) for v in row] for row in cursor]
  except sqlite3.Error as error:case['error']=str(error)
  if 'tick()' in sql:case['calls']=calls[0]
  cases.append(case)
 data=(json.dumps({'source_id':PIN,'setup':SETUP,'cases':cases},indent=2)+'\n').encode();PATH.write_bytes(data)
 PATH.with_suffix('.sha256').write_text(hashlib.sha256(data).hexdigest()+'  '+PATH.name+'\n')
 print('Generated',len(cases),'boolean-name cases')

if __name__=='__main__':
 if '--verify' in sys.argv:
  assert hashlib.sha256(PATH.read_bytes()).hexdigest()==PATH.with_suffix('.sha256').read_text().split()[0]
  print('Boolean-name oracle checksum verified')
 else:generate()
