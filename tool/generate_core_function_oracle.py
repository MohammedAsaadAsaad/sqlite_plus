"""Development-only core scalar oracle pinned to the fixture SQLite build."""
import hashlib
import json
import sqlite3
import sys
from generate_fixtures import PIN, ROOT
from generate_sql_oracle import encode

OUTPUT = ROOT / "core_function_oracle.json"
CHECKSUM = ROOT / "core_function_oracle.sha256"


def generate():
    manifest = json.loads((ROOT / "manifest.json").read_text())
    queries = [("SELECT " + expr, []) for expr in [
        "likely(NULL)", "likely(0)", "unlikely(1)", "unlikely('text')",
        "likelihood(X'00ff',0.5)", "likelihood(1,0.0)", "likelihood(1,1.0)",
        "likelihood(1,(0.3))", "likelihood(1,.0)", "likelihood(1,1e-9999)",
        "likelihood(1,0)", "likelihood(1,1)", "likelihood(1,+0.3)",
        "likelihood(1,-0.0)", "likelihood(1,1.01)", "likelihood(1,1e999)",
        "likelihood(1,'0.5')", "likelihood(1,NULL)", "likelihood(1,0.3+0)",
        "likelihood(1,CAST(0.3 AS REAL))", "likelihood(1,0.3 COLLATE binary)",
        "likelihood(1,0.5)='1'", "likely(1)='1'", "likely()", "unlikely(1,2)",
        "unistr(NULL)", "unistr(123)", "unistr('')", "unistr('abcλ😀')",
        "unistr('a\\0000b')", "unistr('\\0041\\u03bb\\U0001f600')",
        "unistr('\\+01F600')", "unistr('\\\\x')", "unistr('\\u000041')",
        "unistr('\\n')", "unistr('\\u123')", "unistr('\\u+041')",
        "unistr('\\+12345')", "unistr('\\U0000000g')", "unistr('\\')",
        "unistr()", "unistr_quote(NULL)", "unistr_quote('')",
        "unistr_quote('a''b')", "unistr_quote(1.2345678901234567)",
        "unistr_quote(1e999)", "unistr_quote(-1e999)", "unistr_quote(X'001fff')",
        "unistr_quote(char(0))", "unistr_quote(char(1,9,10,13,31,127))",
        "unistr_quote('a\\b'||char(10)||char(39)||'λ😀')",
        "like('A%','abc')", "like('_','😀')", "like('a!_b','a_b','!')",
        "like('%',NULL)", "like('%','x',NULL)", "like('%','x','xx')",
        "like(X'25',X'616263')", "glob('[A-Z]*','ABC')", "glob('a?','ab')",
        "glob('*',NULL)", "glob('x')", "like('%')", "soundex('test')",
        "typeof(random())", "typeof(randomblob(4))", "length(randomblob(0))",
        "length(randomblob(-1))", "length(randomblob(NULL))",
        "length(randomblob('2e2'))", "length(randomblob('2.8'))",
        "length(randomblob(2.8))", "length(randomblob('x'))", "random(1)",
        "length(zeroblob('2e2'))", "length(zeroblob('2.8'))",
        "length(zeroblob('.8'))", "substr('abcdef','2e2','3e2')",
        "substr('abcdef','2.8','3.8')", "substr('abcdef',2.8,3.8)",
        "char('65e1')", "char('65.9')", "char(65.9)",
        "round(1.23456,'2e2')", "round(1.23456,'2.8')",
        "printf(*)", "char(*)", "pi(*)", "typeof(random(*))",
        "format(DISTINCT 1)", "abs(DISTINCT -2)", "min(DISTINCT 3,2)",
        "coalesce(DISTINCT NULL,2)", "char(DISTINCT)", "printf(DISTINCT *)",
        "substr('abc','9223372036854775808',1)",
        "substr('abc','-9223372036854775809',1)",
        "substr('abc','+00000000000000000002',1)",
        "char('9223372036854775808')", "char('-9223372036854775809')",
        "round(1.234,'00000000000000000002')",
    ]]
    queries += [(sql, params) for sql, params in [
        ("SELECT likelihood(1,?)", [0.5]),
        ("SELECT unistr(?)", ['a\0b']),
        ("SELECT unistr_quote(?)", ['a\0b\n']),
        ("SELECT unistr_quote(?)", ["a\nb\\c'd"]),
        ("SELECT unistr(?)", [b'a\x00b\x00']),
        ("SELECT length(randomblob(?)),length(zeroblob(?))", [b'2e2', b'2e2']),
        ("SELECT likely(a)='1',unlikely(b)='A',likely(b COLLATE NOCASE)='A' FROM t", []),
        ("SELECT likelihood(a,0.5)='1',likelihood(b,0.5)='A' FROM t", []),
    ]]
    for function in ["coalesce", "min", "max", "char"]:
        queries.append(("SELECT length(" + function + "(" + ",".join(["65"] * 1000) + "))", []))
        queries.append(("SELECT " + function + "(" + ",".join(["65"] * 1001) + ")", []))
    output = []
    for encoding, label in [(1, "UTF-8"), (2, "UTF-16le"), (3, "UTF-16be")]:
        with sqlite3.connect(":memory:") as db:
            if db.execute("SELECT sqlite_source_id()").fetchone()[0] != PIN:
                raise RuntimeError("Wrong SQLite source ID")
            if sorted(row[0] for row in db.execute("PRAGMA compile_options")) != manifest["compile_options"]:
                raise RuntimeError("Wrong SQLite compile options")
            db.execute("PRAGMA encoding='" + label + "'")
            db.execute("CREATE TABLE t(a INTEGER,b TEXT COLLATE NOCASE)")
            db.execute("INSERT INTO t VALUES(1,'a')")
            for sql, params in queries:
                if encoding != 1 and ("like(X'25'" in sql or b'2e2' in params):
                    # Odd-length UTF-16 blob-to-text coercion is outside the
                    # engine's documented well-formed-text subset.
                    continue
                case = {"encoding": encoding, "sql": sql, "parameters": [encode(v) for v in params]}
                try:
                    cursor = db.execute(sql, params)
                    case["rows"] = [[encode(v) for v in row] for row in cursor]
                except sqlite3.Error as error:
                    case["error"] = str(error)
                except UnicodeDecodeError:
                    # The engine explicitly rejects malformed UTF text. These
                    # cases are verified separately as documented deviations.
                    continue
                output.append(case)
    data = (json.dumps(output, ensure_ascii=False, indent=2) + "\n").encode()
    OUTPUT.write_bytes(data)
    CHECKSUM.write_text(hashlib.sha256(data).hexdigest() + "  " + OUTPUT.name + "\n")
    print("Generated", len(output), "pinned core-function cases")


if __name__ == "__main__":
    if "--verify" in sys.argv:
        expected = CHECKSUM.read_text().split()[0]
        if hashlib.sha256(OUTPUT.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Core-function oracle checksum mismatch")
        print("Core-function oracle checksum verified")
    else:
        generate()
