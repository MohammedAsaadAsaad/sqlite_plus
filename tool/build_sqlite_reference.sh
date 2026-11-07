#!/usr/bin/env bash
# Development/CI oracle only; never used by the Dart production runtime.
set -euo pipefail
sqlite_reference_dir=$(mktemp -d /tmp/sqlite-reference.XXXXXX)
trap 'rm -rf "$sqlite_reference_dir"' EXIT
curl -fsSLo "$sqlite_reference_dir/source.zip" https://sqlite.org/2026/sqlite-amalgamation-3530100.zip
unzip -q "$sqlite_reference_dir/source.zip" -d "$sqlite_reference_dir"
mkdir -p /tmp/sqlite-build
cc -O2 -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5 \
  -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MATH_FUNCTIONS \
  "$sqlite_reference_dir/sqlite-amalgamation-3530100/shell.c" \
  "$sqlite_reference_dir/sqlite-amalgamation-3530100/sqlite3.c" \
  -ldl -lpthread -lm -o /tmp/sqlite-build/sqlite3
python3 - <<'PY'
import subprocess
actual = subprocess.check_output(['/tmp/sqlite-build/sqlite3', ':memory:', 'SELECT sqlite_source_id()'], text=True).strip()
assert actual == '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9', actual
PY
