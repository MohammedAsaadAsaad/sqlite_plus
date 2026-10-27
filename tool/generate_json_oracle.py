"""Development-only JSON oracle pinned to SQLite 3.53.1.

The generator loads the amalgamation CLI (SQLITE_PLUS_SQLITE3, default
/tmp/sqlite-build/sqlite3). It requires sqlite_source_id() to equal PIN.
This build's compiler is gcc-13.3.0, so compile_options do not match
manifest.json (COMPILER=clang-22.1.3). JSON behavior is checked against the
source id, and the compiler difference is recorded rather than weakening the
other generators. --verify only checks the checksum and does not run SQLite.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from generate_fixtures import PIN, ROOT

OUTPUT = ROOT / "json_oracle.json"
CHECKSUM = ROOT / "json_oracle.sha256"
CLI = os.environ.get("SQLITE_PLUS_SQLITE3", "/tmp/sqlite-build/sqlite3")

QUERIES = [
    "SELECT json('{\"a\":1}')",
    "SELECT json('  { \"a\" : 1, } ')",
    "SELECT json('{a:1}')",
    "SELECT json('''a''')",
    "SELECT json('1.0')",
    "SELECT json(1.0)",
    "SELECT json(10.0)",
    "SELECT json(-0.0)",
    "SELECT json(1e2)",
    "SELECT json(1e20)",
    "SELECT json(1e-7)",
    "SELECT json(1e15)",
    "SELECT json(2.2250738585072014e-308)",
    "SELECT json('+1')",
    "SELECT json('1.')",
    "SELECT json('.5')",
    "SELECT json('0x10')",
    "SELECT json('-0')",
    "SELECT json('01')",
    "SELECT json(NULL)",
    "SELECT json('nope')",
    "SELECT json()",
    "SELECT json(1,2)",
    "SELECT json('Infinity'), json('-infinity'), json('+Infinity')",
    "SELECT json('1e'), json('1e+')",
    "SELECT json('[1,]')",
    "SELECT json('{\"a\":1,}')",
    "SELECT json('/*c*/1')",
    "SELECT json('//c' || char(10) || '1')",
    "SELECT json('1,')",
    "SELECT json_valid('{\"a\":1}')",
    "SELECT json_valid('{a:1}')",
    "SELECT json_valid('{a:1}', 1)",
    "SELECT json_valid('{a:1}', 2)",
    "SELECT json_valid('{a:1}', 3)",
    "SELECT json_valid(NULL)",
    "SELECT json_valid(1)",
    "SELECT json_valid(1.5)",
    "SELECT json_valid(x'00')",
    "SELECT json_valid(x'7b7d')",
    "SELECT json_valid(jsonb('null'))",
    "SELECT json_valid(jsonb('1'))",
    "SELECT json_valid(jsonb('null'), 4)",
    "SELECT json_valid(jsonb('null'), 8)",
    "SELECT json_valid(jsonb('null'), 12)",
    "SELECT json_valid(x'ff', 8)",
    "SELECT json_valid(x'ff', 4)",
    "SELECT json_valid('{}', 0)",
    "SELECT json_valid('{}', 16)",
    "SELECT json_valid('{}', 15)",
    "SELECT json_valid('{}', '2')",
    "SELECT json_valid('{}', 'no')",
    "SELECT json_type('{\"a\":1}','$.a')",
    "SELECT json_type('1.0')",
    "SELECT json_type('1')",
    "SELECT json_type('1e2')",
    "SELECT json_type('{}','$.missing')",
    "SELECT json_type(NULL)",
    "SELECT json_type(NULL,'$.a')",
    "SELECT json_type('nope')",
    "SELECT json_type('true'), json_type('false'), json_type('null'), json_type('[]'), json_type('{}'), json_type('\"a\"')",
    "SELECT json_type('{\"a\":1}','')",
    "SELECT json_error_position('x'), json_error_position('{'), json_error_position(NULL), json_error_position('1'), json_error_position('')",
    "SELECT json_extract('{\"a\":1}','$.a'), typeof(json_extract('{\"a\":1}','$.a'))",
    "SELECT json_extract('[1,2]','$[0]')",
    "SELECT json_extract('{\"a\":1}','$.b')",
    "SELECT json_extract('{\"a\":{\"b\":[1,2]}}','$.a.b[1]')",
    "SELECT json_extract('{\"a\":1}','$.a','$.b')",
    "SELECT json_extract('[1,2,3]','$[0]','$[2]','$[9]')",
    "SELECT json_extract('{\"a\":1}', NULL)",
    "SELECT json_extract('{\"a\":1}','$.a', NULL)",
    "SELECT json_extract()",
    "SELECT json_extract('nope','$')",
    "SELECT json_extract('{}','')",
    "SELECT json_extract('{}','a')",
    "SELECT json_extract('{}', '')",
    "SELECT json_extract('{\"a\":1,\"a\":2}','$.a')",
    "SELECT json_extract('[1,2]','$[01]')",
    "SELECT json_extract('[1,2]','$[#]')",
    "SELECT json_extract('[1,2]','$[#-1]')",
    "SELECT json_extract('[1,2]','$[#-9]')",
    "SELECT json_extract('{\"a\":1}','$.')",
    "SELECT json_extract('[1]','$.a.')",
    "SELECT json_extract('{}','$[')",
    "SELECT json_extract('[1]','$[')",
    "SELECT json_extract('{\"a\":1}','$.a b')",
    "SELECT json_extract('{\"a \":1}','$.a ')",
    "SELECT json_extract('1.5','$'), typeof(json_extract('1.5','$'))",
    "SELECT json_extract('1e2','$'), typeof(json_extract('1e2','$'))",
    "SELECT json_extract('-0','$'), typeof(json_extract('-0','$'))",
    "SELECT json_extract('9223372036854775807','$')",
    "SELECT json_extract('9223372036854775808','$'), typeof(json_extract('9223372036854775808','$'))",
    "SELECT json_extract('-9223372036854775808','$')",
    "SELECT json_extract('-9223372036854775809','$'), typeof(json_extract('-9223372036854775809','$'))",
    "SELECT '[1,2]' -> 0, typeof('[1,2]' -> 0)",
    "SELECT '[1,2]' ->> 0, typeof('[1,2]' ->> 0)",
    "SELECT '{\"a\":1}' -> 'a'",
    "SELECT '{\"a\":1}' ->> 'a'",
    "SELECT '{\"a\":1}' ->> 0",
    "SELECT NULL -> '$.a'",
    "SELECT '{\"a\":1}' -> NULL",
    "SELECT 'nope' -> NULL",
    "SELECT '[1,2]' -> 0 + 10",
    "SELECT '1' || '[1,2]' -> 1",
    "SELECT ' [1,2] ' -> 0",
    "SELECT '{\"a\":1}' -> '$.a'",
    "SELECT '[1,2]' -> '[0]'",
    "SELECT '[1,2]' -> '0'",
    "SELECT '{\"a b\":1}' -> 'a b'",
    "SELECT '{}' -> 'bad path'",
    "SELECT '{\"a\":1}' -> 'a' ->> 0",
    "SELECT json_array(1,NULL,'x')",
    "SELECT json_array(1.0, 1e2)",
    "SELECT json_array('{\"a\":1}')",
    "SELECT json_array(json('{\"a\":1}'))",
    "SELECT json_array((SELECT json('{\"a\":1}')))",
    "SELECT json_array(j) FROM (SELECT json('{\"a\":1}') AS j)",
    "SELECT json_array(json_quote('a'))",
    "SELECT json_array()",
    "SELECT json_array(jsonb('{\"a\":1}'))",
    "SELECT json_object('a',1,'b',NULL)",
    "SELECT json_object()",
    "SELECT json_object('a')",
    "SELECT json_object(1,2)",
    "SELECT json_object(NULL,1)",
    "SELECT json_object(x'61',2)",
    "SELECT json_object('a',1.0,'b',1e2)",
    "SELECT json_object('a', x'00')",
    "SELECT json_object('a', x'ff')",
    "SELECT json_array_length('[1,2,3]'), json_array_length('{\"a\":1}'), json_array_length(NULL), json_array_length('[1,2]','$[5]'), json_array_length('\"abc\"'), json_array_length('[1]','$[0]')",
    "SELECT json_array_length('{}','$.a')",
    "SELECT json_array_length('[1,2]','')",
    "SELECT json_insert('{}','$.a.b',1)",
    "SELECT json_insert('{\"a\":1}','$.a',9)",
    "SELECT json_insert('{\"a\":1}','$.b.c.d',4)",
    "SELECT json_insert('{}','$.a',1,'$.a.b',2)",
    "SELECT json_insert('[1]','$[1]',9)",
    "SELECT json_insert('[1]','$[0]',9)",
    "SELECT json_insert('5','$',9)",
    "SELECT json_insert('[]','$[0].a',1)",
    "SELECT json_replace('{\"a\":1}','$.a',9)",
    "SELECT json_replace('{\"a\":1}','$.b',9)",
    "SELECT json_replace('[1]','$[1]',9)",
    "SELECT json_replace('5','$',9)",
    "SELECT json_set('{\"a\":1}','$.a',9)",
    "SELECT json_set('{}','$.b.c',1)",
    "SELECT json_set('[1]','$[1]',9)",
    "SELECT json_set('[1]','$[5]',9)",
    "SELECT json_set('{}','$[0]',1)",
    "SELECT json_set('[]','$.a',1)",
    "SELECT json_set('5','$.a',1)",
    "SELECT json_set('{}','$[#]',1)",
    "SELECT json_set('{\"a\":1,\"a\":2}','$.a',9)",
    "SELECT json_set('{\"a\":1}', NULL, 2, '$.a', 9)",
    "SELECT json_set()",
    "SELECT json_set('{}','$.a')",
    "SELECT jsonb_set('{}','$.a')",
    "SELECT json_set('[1,2]','$[0]',9,'$[0]',8)",
    "SELECT json_set('{}','$.a[0]',1)",
    "SELECT json_set('[]','$[0].a',1)",
    "SELECT json_set('[]','$[0][0]',1)",
    "SELECT json_set('{\"a\":1}','$',5)",
    "SELECT json_set('{\"a\":1}','$.a', json('{\"b\":2}'))",
    "SELECT json_set('{}','$.a', x'01')",
    "SELECT json_set('{}','$.a', x'7b7d')",
    "SELECT json_remove('[1,2,3]','$[0]','$[0]')",
    "SELECT json_remove('[1,2,3]','$[1]')",
    "SELECT json_remove('{\"a\":1}','$')",
    "SELECT json_remove('{\"a\":1}', NULL)",
    "SELECT json_remove()",
    "SELECT json_remove('{\"a\":1}','$.b')",
    "SELECT json_remove('{\"a\":1,\"b\":2}','$.a','$.missing','$.b')",
    "SELECT json_insert()",
    "SELECT json_patch('{\"a\":1,\"a\":2}','{\"a\":null}')",
    "SELECT json_patch('{\"a\":{\"b\":1}}','{\"a\":{\"c\":2}}')",
    "SELECT json_patch('1','{\"a\":1}')",
    "SELECT json_patch('{\"a\":1}', NULL)",
    "SELECT json_patch('nope','{}')",
    "SELECT json_patch('{\"a\":1,\"a\":2}','{\"a\":{\"b\":1}}')",
    "SELECT json_quote('a\"b'), json_quote(1), json_quote(NULL), json_quote(1.5), json_quote(-0.0)",
    "SELECT json_quote(1.0), json_quote(1e2), json_quote(10.0)",
    "SELECT json_quote(x'00'), json_quote(x'01'), json_quote(x'1331'), json_quote(x'1761')",
    "SELECT json_quote(x'ff')",
    "SELECT json_quote(x'7b7d')",
    "SELECT json_group_array(n) FROM (SELECT 1 AS n UNION ALL SELECT NULL UNION ALL SELECT 2)",
    "SELECT json_group_array(n) FROM (SELECT 1 AS n WHERE 0)",
    "SELECT json_group_array(DISTINCT n) FROM (SELECT 1 AS n UNION ALL SELECT 1 UNION ALL SELECT NULL)",
    "SELECT json_group_array(n ORDER BY n DESC) FROM (SELECT 1 AS n UNION ALL SELECT 3 UNION ALL SELECT NULL)",
    "SELECT json_group_array(n) FILTER (WHERE n IS NOT NULL) FROM (SELECT 1 AS n UNION ALL SELECT NULL UNION ALL SELECT 2)",
    "SELECT json_group_object(k,v) FROM (SELECT 'a' AS k, 1 AS v UNION ALL SELECT 'b', NULL UNION ALL SELECT NULL, 3)",
    "SELECT json_group_object(k,v) FROM (SELECT 'a' AS k, 1 AS v WHERE 0)",
    "SELECT json_group_object(k,v) FROM (SELECT NULL AS k, 1 AS v)",
    "SELECT json_group_object(k,v) FROM (SELECT '' AS k, 1 AS v)",
    "SELECT json_group_object(k,v) FROM (SELECT NULL AS k, 1 AS v UNION ALL SELECT 'a', 2)",
    "SELECT json_group_object(k,v) FROM (SELECT x'61' AS k, 2 AS v)",
    "SELECT json_group_object(k,v) FROM (SELECT 1 AS k, 2 AS v UNION ALL SELECT 1.5, 2)",
    "SELECT json_group_object(DISTINCT k, v) FROM (SELECT 'a' AS k, 1 AS v)",
    "SELECT hex(jsonb('null')), hex(jsonb('true')), hex(jsonb('false')), hex(jsonb('0')), hex(jsonb('1')), hex(jsonb('-1')), hex(jsonb('12'))",
    "SELECT hex(jsonb('1.5')), hex(jsonb('1e2')), hex(jsonb('\"\"')), hex(jsonb('\"a\"')), hex(jsonb('\"ab\"')), hex(jsonb('\"a\\nb\"'))",
    "SELECT hex(jsonb('[]')), hex(jsonb('[1]')), hex(jsonb('[1,2]')), hex(jsonb('{}')), hex(jsonb('{\"a\":1}'))",
    "SELECT hex(jsonb('{\"ab\":true}')), hex(jsonb('{\"a\":1,\"b\":2}')), hex(jsonb('[null,false,true]'))",
    "SELECT hex(jsonb('\"\\u0041\"'))",
    "SELECT hex(jsonb('9223372036854775807'))",
    "SELECT typeof(jsonb('1')), json(jsonb('{\"a\":1}'))",
    "SELECT jsonb('null'), jsonb('true'), jsonb('1'), jsonb('\"a\"'), jsonb('[]'), jsonb('{}'), jsonb('{\"a\":1}')",
    "SELECT hex(jsonb_extract(jsonb('{\"a\":[1]}'),'$.a'))",
    "SELECT jsonb_extract(jsonb('{\"a\":1}'),'$.a'), typeof(jsonb_extract(jsonb('{\"a\":1}'),'$.a'))",
    "SELECT jsonb_extract()",
    "SELECT json(jsonb_array(1,NULL)), hex(jsonb_array(1,NULL))",
    "SELECT json(jsonb_object('a',1)), jsonb_object('a',1)",
    "SELECT json(x'00'), json(x'7b7d'), json(x'01')",
    "SELECT hex(jsonb('\"' || printf('%.*c',11,'a') || '\"'))",
    "SELECT hex(substr(jsonb('\"' || printf('%.*c',12,'a') || '\"'),1,2))",
    "SELECT hex(substr(jsonb('\"' || printf('%.*c',14,'a') || '\"'),1,2))",
    "SELECT key, value, type, atom, id, parent, fullkey, path FROM json_each('{\"a\":[1,true]}')",
    "SELECT key, value, type, atom, id, parent, fullkey, path FROM json_each('[10,true]')",
    "SELECT key, value, type, atom, id, parent, fullkey, path FROM json_each('5')",
    "SELECT key, value, type, atom, id, parent, fullkey, path FROM json_each('{\"a\":1}','$.a')",
    "SELECT key, value, type, atom, id, parent, fullkey, path FROM json_each('[10,{\"b\":2}]','$[0]')",
    "SELECT key, value, type, atom, id, parent, fullkey, path FROM json_tree('[1,{\"b\":2}]')",
    "SELECT key, value, type, atom, id, parent, fullkey, path FROM json_tree('{\"a\":1}','$.a')",
    "SELECT key, id, parent, fullkey, path, value FROM json_each('{\"a\":1}','$')",
    "SELECT key, id, fullkey, path FROM json_tree('{\"a\":1}','$')",
    "SELECT count(*) FROM json_each()",
    "SELECT count(*) FROM json_each(NULL)",
    "SELECT count(*) FROM json_each('{\"a\":1}','$.z')",
    "SELECT * FROM json_each('{\"a\":1}','nope')",
    "SELECT count(*) FROM json_tree()",
    "SELECT count(*) FROM json_tree('1','$.a')",
    "SELECT key, fullkey FROM json_each('{\"a_b\":1,\"_a\":1,\"\":1,\"01\":1,\"a b\":1}')",
    "SELECT key, fullkey FROM json_each('{\"é\":1}')",
    "SELECT d.id, e.value FROM (SELECT 1 AS id, 'a' AS k UNION ALL SELECT 2, 'b' UNION ALL SELECT 3, 'c') AS d JOIN json_each('{\"a\":10,\"b\":20}') AS e ON d.k = e.key ORDER BY d.id",
    "SELECT json_valid(printf('%.*c',1000,'[') || printf('%.*c',1000,']'))",
    "SELECT length(json(printf('%.*c',1000,'[') || printf('%.*c',1000,']')))",
    "SELECT json_valid(printf('%.*c',1001,'[') || printf('%.*c',1001,']'))",
    "SELECT json(printf('%.*c',1001,'[') || printf('%.*c',1001,']'))",
    "SELECT json(char(0))",
    "SELECT json('\"\\u0000\"')",
]


def _source_id():
    result = subprocess.run(
        [CLI, ":memory:", "SELECT sqlite_source_id();"],
        check=True, capture_output=True, text=True)
    return result.stdout.strip()


def _compile_options():
    result = subprocess.run(
        [CLI, ":memory:", "PRAGMA compile_options;"],
        check=True, capture_output=True, text=True)
    return sorted(line.strip() for line in result.stdout.splitlines() if line.strip())


def _parse_row(line):
    values = []
    index = 0
    length = len(line)
    while index < length:
        if line.startswith("NULL", index):
            values.append(None)
            index += 4
        elif line.startswith("x'", index) or line.startswith("X'", index):
            end = line.index("'", index + 2)
            values.append(bytes.fromhex(line[index + 2:end]))
            index = end + 1
        elif line[index] == "'":
            index += 1
            chars = []
            while index < length:
                if line[index] == "'":
                    if index + 1 < length and line[index + 1] == "'":
                        chars.append("'")
                        index += 2
                        continue
                    index += 1
                    break
                chars.append(line[index])
                index += 1
            values.append("".join(chars))
        else:
            end = index
            while end < length and line[end] != ",":
                end += 1
            token = line[index:end]
            if re.fullmatch(r"[+-]?\d+", token):
                values.append(int(token))
            else:
                values.append(float(token))
            index = end
        if index < length and line[index] == ",":
            index += 1
    return values


def _encode(value):
    if isinstance(value, float):
        return {"float": format(value, ".17g")}
    if isinstance(value, bytes):
        return {"blob": value.hex()}
    if isinstance(value, int):
        return {"integer": str(value)}
    return value


def _run(sql, label):
    script = "PRAGMA encoding='%s';\n.mode quote\n.headers off\n%s;\n" % (label, sql)
    result = subprocess.run(
        [CLI, ":memory:"], input=script, capture_output=True, text=True)
    error = result.stderr.strip()
    if result.returncode != 0 or error:
        return {"error": error or "sqlite exited %s" % result.returncode}
    rows = []
    for line in result.stdout.splitlines():
        if line == "":
            continue
        rows.append([_encode(value) for value in _parse_row(line)])
    return {"rows": rows}


def generate():
    if _source_id() != PIN:
        raise RuntimeError("Wrong SQLite source ID")
    manifest = json.loads((ROOT / "manifest.json").read_text())
    options = _compile_options()
    if options != manifest["compile_options"]:
        print("JSON oracle compile options differ from manifest.json")
        print("source id matches; compiler line is recorded, not rewritten")
    output = []
    for encoding, label in [(1, "UTF-8"), (2, "UTF-16le"), (3, "UTF-16be")]:
        for sql in QUERIES:
            case = {"encoding": encoding, "sql": sql}
            case.update(_run(sql, label))
            output.append(case)
    data = (json.dumps(output, ensure_ascii=False, indent=2) + "\n").encode()
    OUTPUT.write_bytes(data)
    CHECKSUM.write_text(hashlib.sha256(data).hexdigest() + "  " + OUTPUT.name + "\n")
    print("Generated", len(output), "pinned JSON cases")


if __name__ == "__main__":
    if "--verify" in sys.argv:
        expected = CHECKSUM.read_text().split()[0]
        if hashlib.sha256(OUTPUT.read_bytes()).hexdigest() != expected:
            raise RuntimeError("JSON oracle checksum mismatch")
        print("JSON oracle checksum verified")
    else:
        generate()
