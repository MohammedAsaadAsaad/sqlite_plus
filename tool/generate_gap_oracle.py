"""Development-only gap ledger pinned to SQLite 3.53.1.

The generator loads the amalgamation CLI (SQLITE_PLUS_SQLITE3, default
/tmp/sqlite-build/sqlite3). It requires sqlite_source_id() to equal PIN.
This build's compiler is gcc-13.3.0, so compile_options do not match
manifest.json (COMPILER=clang-22.1.3). The source id is checked, and the
compiler difference is recorded rather than rewriting the manifest.
--verify only checks the checksum and does not run SQLite.

Each case is either a match against the CLI or a recorded rejection/difference.
UTF-8 memory databases only. This is not a claim that every SQLite statement
was compared.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from generate_fixtures import PIN, ROOT

OUTPUT = ROOT / "gap_oracle.json"
CHECKSUM = ROOT / "gap_oracle.sha256"
CLI = os.environ.get("SQLITE_PLUS_SQLITE3", "/tmp/sqlite-build/sqlite3")

CASES = [
    {"id": "arithmetic", "sql": "SELECT (1+2)*3, 7-1"},
    {
        "id": "storage-types",
        "sql": "SELECT typeof(1), typeof(1.5), typeof('a'), typeof(NULL), typeof(x'61')",
    },
    {"id": "string-literal", "sql": "SELECT 'title'"},
    {
        "id": "quoted-column",
        "setup": "CREATE TABLE t(title TEXT); INSERT INTO t VALUES ('value')",
        "sql": 'SELECT "title" FROM t',
    },
    {
        "id": "primary-key-order",
        "setup": "CREATE TABLE n(id INTEGER PRIMARY KEY, v TEXT); INSERT INTO n(v) VALUES ('a'),('b')",
        "sql": "SELECT id, v FROM n ORDER BY id",
    },
    {"id": "json-object", "sql": """SELECT json('{"a":1}')"""},
    {
        "id": "cte-sum",
        "sql": "WITH c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<3) SELECT sum(n) FROM c",
    },
    {
        "id": "case-when",
        "sql": "SELECT CASE WHEN NULL THEN 'a' WHEN 1 THEN 'b' ELSE 'c' END",
    },
    {
        "id": "functions",
        "sql": "SELECT abs(-3), length('ab'), upper('Ab'), 'Ab' LIKE 'a%'",
    },
    {"id": "null-row", "sql": "SELECT NULL, 0, ''"},
    {
        "id": "user-version",
        "setup": "PRAGMA user_version=7",
        "sql": "PRAGMA user_version",
    },
    {"id": "cache-size", "sql": "PRAGMA cache_size"},
    {"id": "busy-timeout", "sql": "PRAGMA busy_timeout"},
    {"id": "synchronous", "sql": "PRAGMA synchronous"},
    {"id": "encoding", "sql": "PRAGMA encoding"},
    {
        "id": "cross-select",
        "setup": "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); ATTACH ':memory:' AS aux; CREATE TABLE aux.u(v); INSERT INTO aux.u VALUES ('a')",
        "sql": "SELECT main.t.v, aux.u.v FROM main.t, aux.u",
    },
    {
        "id": "dqs-fallback",
        "disposition": "rejected",
        "sql": 'SELECT "missing"',
        "reason": "DQS stays off. A double-quoted token that is not a column is an identifier. Pinned SQLite 3.53.1 returns the string missing.",
        "engine_message": "No such column: missing",
    },
    {
        "id": "json-pretty",
        "disposition": "rejected",
        "sql": """SELECT json_pretty('{"a":1}')""",
        "reason": "json_pretty is not implemented. The pinned CLI formats the object.",
        "engine_message": "No such function: json_pretty",
    },
    {
        "id": "explain-bytecode",
        "disposition": "rejected",
        "sql": "EXPLAIN SELECT 1",
        "reason": "EXPLAIN bytecode is not implemented. The statement is rejected. EXPLAIN QUERY PLAN prints this engine's plan text, which is not SQLite bytecode.",
        "engine_message": "EXPLAIN bytecode is not implemented",
    },
    {
        "id": "journal-mode-memory",
        "disposition": "rejected",
        "kind": "execute",
        "sql": "PRAGMA journal_mode=memory",
        "reason": "journal_mode memory is not implemented. Writing a mode other than the current header mode is rejected before the image changes.",
        "engine_message": "journal_mode memory is not implemented",
    },
    {
        "id": "journal-mode-off",
        "disposition": "rejected",
        "kind": "execute",
        "sql": "PRAGMA journal_mode=off",
        "reason": "Pinned SQLite :memory: stays on memory when asked for off. This engine rejects journal_mode off before the rollback image changes.",
        "engine_message": "journal_mode off is not implemented",
    },
    {
        "id": "auto-vacuum-full",
        "disposition": "rejected",
        "kind": "execute",
        "sql": "PRAGMA auto_vacuum=FULL",
        "reason": "auto_vacuum is not implemented. A write is rejected. An image with a non-zero largest root page is not opened as success.",
        "engine_message": "auto_vacuum is not implemented",
    },
    {
        "id": "cross-insert",
        "disposition": "rejected",
        "kind": "execute",
        "setup": "CREATE TABLE t(v); INSERT INTO t VALUES ('m'); ATTACH ':memory:' AS aux; CREATE TABLE aux.u(v)",
        "sql": "INSERT INTO aux.u SELECT v FROM t",
        "reason": "One statement cannot mutate two schemas. The insert is rejected, so aux.u stays empty.",
        "engine_message": "cross-database statement is not supported",
        "unchanged_sql": "SELECT count(*) FROM aux.u",
        "unchanged_rows": [[{"integer": "0"}]],
    },
    {
        "id": "journal-mode-read",
        "disposition": "differs",
        "sql": "PRAGMA journal_mode",
        "reason": "A fresh image reports rollback from header byte 18. Pinned SQLite :memory: reports memory. memory mode is not implemented.",
        "engine_rows": [["rollback"]],
    },
    {
        "id": "explain-query-plan",
        "disposition": "differs",
        "setup": "CREATE TABLE t(a INTEGER PRIMARY KEY)",
        "sql": "EXPLAIN QUERY PLAN SELECT a FROM t WHERE a=1",
        "reason": "EXPLAIN QUERY PLAN prints this engine's plan. It is not SQLite's plan text or bytecode.",
        "engine_detail": {
            "contains": ["t"],
            "excludes": ["Opcode", "INTEGER PRIMARY KEY", "QUERY PLAN"],
        },
        "sqlite_text_contains": ["INTEGER PRIMARY KEY"],
    },
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


def _run(setup, sql):
    script = ".mode quote\n.headers off\n"
    if setup:
        script += setup + ";\n"
    script += ".print @@RESULT@@\n" + sql + ";\n"
    result = subprocess.run(
        [CLI, ":memory:"], input=script, capture_output=True, text=True)
    error = result.stderr.strip()
    if result.returncode != 0 or error:
        return {"error": error or "sqlite exited %s" % result.returncode,
                "sqlite_text": result.stdout}
    parts = result.stdout.split("@@RESULT@@", 1)
    if len(parts) != 2:
        raise RuntimeError("Missing result marker for: %s" % sql)
    body = parts[1].strip("\n")
    parsed = {"sqlite_text": body}
    rows = []
    try:
        for line in body.splitlines():
            if line == "":
                continue
            rows.append([_encode(value) for value in _parse_row(line)])
    except ValueError:
        parsed["parse_error"] = "quote-mode row was not parsed"
        return parsed
    parsed["rows"] = rows
    return parsed


def generate():
    if _source_id() != PIN:
        raise RuntimeError("Wrong SQLite source ID")
    manifest = json.loads((ROOT / "manifest.json").read_text())
    options = _compile_options()
    if options != manifest["compile_options"]:
        print("Gap oracle compile options differ from manifest.json")
        print("source id matches; compiler line is recorded, not rewritten")
    output_cases = []
    for case in CASES:
        recorded = {
            "id": case["id"],
            "disposition": case.get("disposition", "match"),
            "kind": case.get("kind", "query"),
            "sql": case["sql"],
        }
        if "setup" in case:
            recorded["setup"] = case["setup"]
        if "reason" in case:
            recorded["reason"] = case["reason"]
        for key in ("engine_message", "engine_rows", "engine_detail",
                    "sqlite_text_contains", "unchanged_sql", "unchanged_rows"):
            if key in case:
                recorded[key] = case[key]
        ran = _run(case.get("setup", ""), case["sql"])
        if recorded["disposition"] == "match" and "error" in ran:
            raise RuntimeError("%s failed on pinned SQLite: %s" % (
                case["id"], ran["error"]))
        if recorded["disposition"] == "match" and "rows" not in ran:
            raise RuntimeError("%s did not parse on pinned SQLite" % case["id"])
        recorded.update(ran)
        if recorded["disposition"] != "match" and not recorded.get("reason"):
            raise RuntimeError("%s needs a recorded reason" % case["id"])
        output_cases.append(recorded)
    document = {
        "source_id": PIN,
        "encoding": "UTF-8",
        "compiler_note": "CLI reports COMPILER=gcc-13.3.0. manifest.json records COMPILER=clang-22.1.3. The manifest was not rewritten.",
        "cases": output_cases,
    }
    data = (json.dumps(document, ensure_ascii=False, indent=2) + "\n").encode()
    OUTPUT.write_bytes(data)
    CHECKSUM.write_text(hashlib.sha256(data).hexdigest() + "  " + OUTPUT.name + "\n")
    print("Generated", len(output_cases), "pinned gap cases")


if __name__ == "__main__":
    if "--verify" in sys.argv:
        expected = CHECKSUM.read_text().split()[0]
        if hashlib.sha256(OUTPUT.read_bytes()).hexdigest() != expected:
            raise RuntimeError("Gap oracle checksum mismatch")
        print("Gap oracle checksum verified")
    else:
        generate()
