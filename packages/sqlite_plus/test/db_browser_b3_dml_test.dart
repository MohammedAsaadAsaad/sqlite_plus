import 'dart:io';

import 'package:sqlite_plus/sqlite_plus.dart';
import 'package:test/test.dart';

const _pin =
    '2026-05-05 10:34:17 c88b22011a54b4f6fbd149e9f8e4de77658ce58143a1af0e3785e4e6475127e9';

void main() {
  String cli() =>
      Platform.environment['SQLITE_PLUS_SQLITE3'] ??
      '/tmp/sqlite-build/sqlite3';

  Future<String> pinned(String sql) async {
    final result = await Process.run(cli(), [':memory:', sql]);
    if (result.exitCode != 0) {
      return 'ERR ${result.stderr.toString().trim()}';
    }
    return result.stdout.toString().trim();
  }

  Future<String> engine(String sql) async {
    final db = await MutableSqliteDatabase.create();
    try {
      final statements = _statements(sql);
      final parts = <String>[];
      for (final statement in statements) {
        final parser = statement.trimLeft().toUpperCase();
        if (parser.startsWith('SELECT') || parser.startsWith('PRAGMA')) {
          final rows = await db.query(statement);
          parts.add(rows.rows
              .map((row) => row.map((value) => value ?? '').join('|'))
              .join('\n'));
        } else {
          final returning = (await db.execute(statement)).returning;
          if (returning != null) {
            parts.add(returning.rows
                .map((row) => row.map((value) => value ?? '').join('|'))
                .join('\n'));
          }
        }
      }
      return parts.join('\n');
    } on SqlException catch (error) {
      return 'ERR ${error.message}';
    } finally {
      await db.close();
    }
  }

  test('gap-ledger DML besides cross-insert, and nearby statements', () async {
    final id =
        await Process.run(cli(), [':memory:', 'SELECT sqlite_source_id();']);
    expect(id.stdout.toString().trim(), _pin);
    const scripts = <String>[
      "CREATE TABLE t(v); INSERT INTO t DEFAULT VALUES; SELECT v FROM t;",
      "CREATE TABLE t(id INTEGER PRIMARY KEY, v); INSERT INTO t(v) VALUES ('a'); "
          "REPLACE INTO t(id, v) VALUES (1, 'b'); SELECT v FROM t;",
      "CREATE TABLE t(id INTEGER PRIMARY KEY, v); INSERT INTO t(id, v) VALUES (1, 'a'); "
          "INSERT INTO t(id, v) VALUES (1, 'b') ON CONFLICT(id) DO NOTHING; SELECT v FROM t;",
      "CREATE TABLE t(v); INSERT INTO t VALUES ('a'); UPDATE t SET v='b' RETURNING v;",
      "CREATE TABLE t(v); INSERT INTO t VALUES ('a'),('b'); "
          "DELETE FROM t WHERE v='a' RETURNING v; SELECT count(*) FROM t;",
      "CREATE TABLE t(v); INSERT INTO t VALUES ('a'); UPDATE t SET v=v||'x'; SELECT v FROM t;",
      "CREATE TABLE t(v); INSERT INTO t(v) SELECT 'a'; SELECT v FROM t;",
    ];
    for (final sql in scripts) {
      final cliText = await pinned(sql);
      final engineText = await engine(sql);
      expect(engineText, cliText, reason: sql);
    }
  });
}

List<String> _statements(String sql) {
  final statements = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  for (var i = 0; i < sql.length; i++) {
    final char = sql[i];
    if (quote.isNotEmpty) {
      buffer.write(char);
      if (char == quote) {
        if (i + 1 < sql.length && sql[i + 1] == quote) {
          buffer.write(sql[++i]);
        } else {
          quote = '';
        }
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      buffer.write(char);
      continue;
    }
    if (char == ';') {
      final text = buffer.toString().trim();
      if (text.isNotEmpty) statements.add(text);
      buffer.clear();
      continue;
    }
    buffer.write(char);
  }
  final text = buffer.toString().trim();
  if (text.isNotEmpty) statements.add(text);
  return statements;
}
