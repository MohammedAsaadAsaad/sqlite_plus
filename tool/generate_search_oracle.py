"""Development-only FTS and R-tree oracle pinned to SQLite 3.53.1.

The generator loads the amalgamation CLI (SQLITE_PLUS_SQLITE3, default
/tmp/sqlite-build/sqlite3). It requires sqlite_source_id() to equal PIN.
This build's compiler is gcc-13.3.0, so compile_options do not match
manifest.json (COMPILER=clang-22.1.3). Search behavior is checked against
the source id, and the compiler difference is recorded rather than weakening
the other generators. --verify only checks the checksum and does not run SQLite.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from generate_fixtures import PIN, ROOT

OUTPUT = ROOT / "search_oracle.json"
CHECKSUM = ROOT / "search_oracle.sha256"
CLI = os.environ.get("SQLITE_PLUS_SQLITE3", "/tmp/sqlite-build/sqlite3")

REPLAY = [
    (
        ["CREATE VIRTUAL TABLE t USING fts5(title, body)",
         "INSERT INTO t(title, body) VALUES('hello world', 'sqlite'), ('hello', 'there')"],
        "SELECT title FROM t WHERE t MATCH 'hello' ORDER BY rank, title",
    ),
    (
        ["CREATE VIRTUAL TABLE t USING fts5(title, body)",
         "INSERT INTO t(title, body) VALUES('Hello World', 'sqlite database')"],
        "SELECT highlight(t, 0, '<', '>'), snippet(t, 0, '<', '>', '...', 4) FROM t WHERE t MATCH 'hello'",
    ),
    (
        ["CREATE VIRTUAL TABLE t USING fts5(title, body, prefix='2')",
         "INSERT INTO t(title, body) VALUES('hello', 'there'), ('world', 'hello')"],
        "SELECT title FROM t WHERE t MATCH 'title : hel*' ORDER BY title",
    ),
    (
        ["CREATE VIRTUAL TABLE t USING fts5(body, tokenize='unicode61')",
         "INSERT INTO t(body) VALUES('مرحبا بالعالم'), ('hello مرحبا')"],
        "SELECT count(*) FROM t WHERE t MATCH 'مرحبا'",
    ),
    (
        ["CREATE VIRTUAL TABLE t USING fts5(body, tokenize='ascii')",
         "INSERT INTO t(body) VALUES('مرحبا بالعالم'), ('hello مرحبا')"],
        "SELECT count(*) FROM t WHERE t MATCH 'مرحبا'",
    ),
    (
        ["CREATE VIRTUAL TABLE t USING fts5(title, body)",
         "INSERT INTO t(title, body) VALUES('hello world', 'sqlite')"],
        "SELECT count(*) FROM t WHERE t MATCH 'NEAR(hello world, 0)'",
    ),
    (
        ["CREATE VIRTUAL TABLE t USING fts5(title, body)",
         "INSERT INTO t(title, body) VALUES('hello world', 'sqlite')"],
        "SELECT count(*) FROM t WHERE t MATCH 'hello NOT world'",
    ),
    (
        ["CREATE VIRTUAL TABLE c USING fts5(body, content='', contentless_delete=1)",
         "INSERT INTO c(rowid, body) VALUES(5, 'hello')",
         "DELETE FROM c WHERE rowid = 5"],
        "SELECT count(*) FROM c",
    ),
    (
        ["CREATE TABLE src(id INTEGER PRIMARY KEY, body TEXT)",
         "CREATE VIRTUAL TABLE e USING fts5(body, content='src', content_rowid='id')",
         "INSERT INTO src(id, body) VALUES(1, 'hello')",
         "INSERT INTO e(e) VALUES('rebuild')"],
        "SELECT body FROM e WHERE e MATCH 'hello'",
    ),
    (
        ["CREATE VIRTUAL TABLE rt USING rtree(id, minX, maxX, minY, maxY, +value)",
         "INSERT INTO rt VALUES(1, 0, 1, 0, 1, 'aux'), (2, 5, 6, 5, 6, 'far')"],
        "SELECT id, value FROM rt WHERE minX <= 1 AND maxX >= 0 AND minY <= 1 AND maxY >= 0 ORDER BY id",
    ),
    (
        ["CREATE VIRTUAL TABLE rt USING rtree(id, minX, maxX, minY, maxY)",
         "INSERT INTO rt VALUES(1, 0, 1, 0, 1)"],
        "SELECT count(*) FROM rt WHERE minX <= -2 AND maxX >= -3",
    ),
    (
        ["CREATE VIRTUAL TABLE rt USING rtree(id, a, b, c)"],
        "SELECT 1",
    ),
    (
        ["CREATE VIRTUAL TABLE g USING geopoly(id)",
         "INSERT INTO g(_shape, id) VALUES('[[0,0],[1,0],[1,1],[0,1],[0,0]]', 7)"],
        "SELECT id, geopoly_area(_shape), geopoly_json(_shape) FROM g",
    ),
    (
        [],
        "SELECT geopoly_overlap('[[0,0],[2,0],[2,2],[0,2],[0,0]]','[[0.5,0.5],[1.5,0.5],[1.5,1.5],[0.5,1.5],[0.5,0.5]]'), geopoly_within('[[0.5,0.5],[1,0.5],[1,1],[0.5,1],[0.5,0.5]]','[[0,0],[2,0],[2,2],[0,2],[0,0]]'), geopoly_json('nope')",
    ),
]

IMAGES = [
    (
        "fts4",
        ["CREATE VIRTUAL TABLE t USING fts4(title, body)",
         "INSERT INTO t(title, body) VALUES('hello world', 'sqlite'), ('other', 'hello')"],
        [
            "SELECT title FROM t WHERE t MATCH '(hello AND world) OR missing' ORDER BY rowid",
            "SELECT count(*) FROM t WHERE t MATCH 'hello'",
        ],
    ),
    (
        "fts3",
        ["CREATE VIRTUAL TABLE t USING fts3(title, body)",
         "INSERT INTO t(title, body) VALUES('hello world', 'sqlite')"],
        ["SELECT title FROM t WHERE t MATCH 'hello AND world'"],
    ),
]


def _source_id():
    result = subprocess.run(
        [CLI, ":memory:", "SELECT sqlite_source_id();"],
        check=True, capture_output=True, text=True)
    return result.stdout.strip()


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


def _capture(path, sql):
    script = ".mode quote\n.headers off\n%s;\n" % sql
    result = subprocess.run(
        [CLI, path], input=script, capture_output=True, text=True)
    error = result.stderr.strip()
    if result.returncode != 0 or error:
        return {"error": True}
    rows = []
    for line in result.stdout.splitlines():
        if line == "":
            continue
        rows.append([_encode(value) for value in _parse_row(line)])
    return {"rows": rows}


def _build(encoding, statements):
    label = {1: "UTF-8", 2: "UTF-16le", 3: "UTF-16be"}[encoding]
    script = "PRAGMA encoding='%s';\n%s;\n" % (
        label, ";\n".join(statements))
    path = tempfile.mktemp(suffix=".db")
    result = subprocess.run(
        [CLI, path], input=script, capture_output=True, text=True)
    failed = result.returncode != 0 or result.stderr.strip()
    return path, failed


def generate():
    if _source_id() != PIN:
        raise RuntimeError("Wrong SQLite source ID")
    replay = []
    images = []
    for encoding in (1, 2, 3):
        for setup, sql in REPLAY:
            path, failed = _build(encoding, setup)
            try:
                case = {"encoding": encoding, "setup": setup, "sql": sql}
                if failed:
                    case["error"] = True
                else:
                    case.update(_capture(path, sql))
                replay.append(case)
            finally:
                if os.path.exists(path):
                    os.remove(path)
        for name, setup, queries in IMAGES:
            path, failed = _build(encoding, setup)
            try:
                if failed:
                    raise RuntimeError("image setup failed for %s" % name)
                blob = open(path, "rb").read()
                filename = "search-%s-%s.db" % (name, encoding)
                (ROOT / filename).write_bytes(blob)
                captured = []
                for sql in queries:
                    item = {"sql": sql}
                    item.update(_capture(path, sql))
                    captured.append(item)
                images.append({
                    "encoding": encoding,
                    "module": name,
                    "file": filename,
                    "sha256": hashlib.sha256(blob).hexdigest(),
                    "queries": captured,
                })
            finally:
                if os.path.exists(path):
                    os.remove(path)
    data = (json.dumps({"replay": replay, "images": images},
                       ensure_ascii=False, indent=2) + "\n").encode()
    OUTPUT.write_bytes(data)
    CHECKSUM.write_text(hashlib.sha256(data).hexdigest() + "  " + OUTPUT.name + "\n")
    print("Generated", len(replay), "replay cases and", len(images), "images")


if __name__ == "__main__":
    if "--verify" in sys.argv:
        expected = CHECKSUM.read_text().split()[0]
        if hashlib.sha256(OUTPUT.read_bytes()).hexdigest() != expected:
            raise RuntimeError("search oracle checksum mismatch")
        catalog = json.loads(OUTPUT.read_text())
        for image in catalog["images"]:
            blob = (ROOT / image["file"]).read_bytes()
            if hashlib.sha256(blob).hexdigest() != image["sha256"]:
                raise RuntimeError("search image checksum mismatch: %s" % image["file"])
        print("search oracle checksum verified")
    else:
        generate()
